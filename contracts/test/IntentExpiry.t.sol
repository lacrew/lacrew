// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SessionWiring} from "./utils/SessionWiring.sol";
import {OrgRegistry} from "../src/OrgRegistry.sol";
import {EscalationRouter} from "../src/EscalationRouter.sol";
import {SessionRegistry} from "../src/SessionRegistry.sol";
import {SessionScopes} from "../src/SessionScopes.sol";
import {Treasury} from "../src/Treasury.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {SpendCapPolicy} from "../src/policies/SpendCapPolicy.sol";
import {IOrgRegistry} from "../src/interfaces/IOrgRegistry.sol";

/// Intents expire, and state recorded against a node's earlier incarnation (intents,
/// session keys, allowance) stops working once the address is removed and re-added.
contract IntentExpiryTest is SessionWiring {
    address internal root = makeAddr("root");
    address internal manager = makeAddr("manager");
    address internal worker = makeAddr("worker");
    address internal payee = makeAddr("payee");
    address internal stranger = makeAddr("stranger");
    address internal key = makeAddr("key");

    uint256 internal constant ONE = 1e6;

    OrgRegistry internal registry;
    EscalationRouter internal router;
    Treasury internal treasury;
    SessionRegistry internal sessions;
    MockUSDC internal usdc;

    function setUp() public {
        registry = new OrgRegistry(root);
        vm.startPrank(root);
        registry.addNode(manager, IOrgRegistry.NodeKind.ManagerAgent, root);
        registry.addNode(worker, IOrgRegistry.NodeKind.WorkerAgent, manager);
        vm.stopPrank();

        SpendCapPolicy spendCap = new SpendCapPolicy(100 * ONE);
        spendCap.setAgentCap(manager, 300 * ONE);
        router = new EscalationRouter(address(registry), address(spendCap));
        {
            address[] memory agents_ = new address[](2);
            agents_[0] = manager;
            agents_[1] = worker;
            _wireSessions(router, registry, root, agents_);
        }
        usdc = new MockUSDC();
        treasury = new Treasury(address(registry), address(usdc), address(router));
        router.setTreasury(address(treasury));
        sessions = new SessionRegistry(root, address(registry));

        usdc.mint(address(this), 10_000 * ONE);
        usdc.approve(address(treasury), type(uint256).max);
        treasury.deposit(10_000 * ONE);
        treasury.streamAllowance(worker, 5_000 * ONE, 1);
    }

    function _escalate() internal returns (uint256 id) {
        (id,) = router.propose(worker, payee, 150 * ONE, "");
    }

    function _resolved(uint256 id) internal view returns (bool resolved, bool approved) {
        (, , , , , resolved, approved) = router.intents(id);
    }

    function _readd(address node, IOrgRegistry.NodeKind kind, address parent) internal {
        vm.startPrank(root);
        registry.removeNode(node);
        registry.addNode(node, kind, parent);
        vm.stopPrank();
    }

    // ——— generation ———

    function test_generationCountsIncarnations() public {
        assertEq(registry.generationOf(root), 1);
        assertEq(registry.generationOf(worker), 1);
        assertEq(registry.generationOf(stranger), 0);
        _readd(worker, IOrgRegistry.NodeKind.WorkerAgent, manager);
        assertEq(registry.generationOf(worker), 2);
    }

    // ——— expiry ———

    function test_intentRecordsExpiryAtTtl() public {
        uint256 id = _escalate();
        (uint64 expiresAt, uint64 agentGen, uint64 approverGen) = router.intentLife(id);
        assertEq(expiresAt, block.timestamp + 7 days);
        assertEq(agentGen, 1);
        assertEq(approverGen, 1);
    }

    function test_resolveRevertsAfterExpiry() public {
        uint256 id = _escalate();
        (uint64 expiresAt,,) = router.intentLife(id);
        vm.warp(expiresAt);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(EscalationRouter.IntentHasExpired.selector, id, expiresAt));
        router.resolve(id, true);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(EscalationRouter.IntentHasExpired.selector, id, expiresAt));
        router.resolve(id, false);
    }

    function test_resolveWorksUntilExpiry() public {
        uint256 id = _escalate();
        (uint64 expiresAt,,) = router.intentLife(id);
        vm.warp(expiresAt - 1);
        vm.prank(manager);
        router.resolve(id, true);
        (bool resolved, bool approved) = _resolved(id);
        assertTrue(resolved);
        assertTrue(approved);
    }

    function test_anyoneClosesExpiredIntent() public {
        uint256 id = _escalate();
        (uint64 expiresAt,,) = router.intentLife(id);
        vm.warp(expiresAt);
        vm.prank(stranger);
        router.closeExpired(id);
        (bool resolved, bool approved) = _resolved(id);
        assertTrue(resolved);
        assertFalse(approved);
        assertEq(usdc.balanceOf(payee), 0);
    }

    function test_cannotCloseLiveIntent() public {
        uint256 id = _escalate();
        (uint64 expiresAt,,) = router.intentLife(id);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(EscalationRouter.IntentNotExpired.selector, id, expiresAt));
        router.closeExpired(id);
    }

    function test_cannotCloseTwiceOrUnknown() public {
        uint256 id = _escalate();
        vm.warp(block.timestamp + 7 days);
        router.closeExpired(id);
        vm.expectRevert(abi.encodeWithSelector(EscalationRouter.IntentAlreadyResolved.selector, id));
        router.closeExpired(id);
        vm.expectRevert(abi.encodeWithSelector(EscalationRouter.IntentNotFound.selector, 99));
        router.closeExpired(99);
    }

    function test_ttlIsGoverned() public {
        router.setIntentTtl(1 days);
        uint256 id = _escalate();
        (uint64 expiresAt,,) = router.intentLife(id);
        assertEq(expiresAt, block.timestamp + 1 days);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(EscalationRouter.NotAuthorized.selector, stranger));
        router.setIntentTtl(2 days);

        vm.expectRevert(abi.encodeWithSelector(EscalationRouter.InvalidIntentTtl.selector, uint64(1 minutes)));
        router.setIntentTtl(1 minutes);
        vm.expectRevert(abi.encodeWithSelector(EscalationRouter.InvalidIntentTtl.selector, uint64(366 days)));
        router.setIntentTtl(366 days);
    }

    // ——— stale incarnations ———

    function test_readdedAgentCannotHaveOldIntentApproved() public {
        uint256 id = _escalate();
        _readd(worker, IOrgRegistry.NodeKind.WorkerAgent, manager);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(EscalationRouter.InactiveAgent.selector, worker));
        router.resolve(id, true);
        // Rejection stays open, which is how the old intent is closed.
        vm.prank(manager);
        router.resolve(id, false);
        (bool resolved,) = _resolved(id);
        assertTrue(resolved);
    }

    function test_readdedApproverCannotResolveOldIntent() public {
        uint256 id = _escalate();
        _readd(manager, IOrgRegistry.NodeKind.ManagerAgent, root);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(EscalationRouter.InactiveApprover.selector, manager));
        router.resolve(id, true);

        // The root covers for the previous incarnation's approver.
        vm.prank(root);
        router.resolve(id, false);
        (bool resolved,) = _resolved(id);
        assertTrue(resolved);
    }

    function test_intentClimbRefreshesApproverGeneration() public {
        // 400 exceeds the manager's cap of 300, so the intent climbs to the root.
        (uint256 id,) = router.propose(worker, payee, 400 * ONE, "");
        vm.prank(manager);
        router.resolve(id, true);
        (,, uint64 approverGen) = router.intentLife(id);
        assertEq(approverGen, registry.generationOf(root));
        (, , , , address awaiting, bool resolved,) = router.intents(id);
        assertEq(awaiting, root);
        assertFalse(resolved);
    }

    // ——— sessions ———

    function test_sessionFromPreviousIncarnationIsInvalid() public {
        vm.prank(root);
        uint256 sid = sessions.issue(
            worker, key, uint64(block.timestamp + 1 days), SessionScopes.ALL, type(uint256).max, address(0)
        );
        assertEq(sessions.agentGenerationOf(sid), 1);
        assertTrue(sessions.isKeyValid(worker, key));

        _readd(worker, IOrgRegistry.NodeKind.WorkerAgent, manager);

        assertFalse(sessions.isValid(sid));
        assertFalse(sessions.isKeyValid(worker, key));
        (bool valid,,,) = sessions.keyLimits(worker, key);
        assertFalse(valid);
        assertFalse(sessions.isTargetAllowed(worker, key, payee));

        vm.prank(root);
        uint256 fresh = sessions.issue(
            worker, key, uint64(block.timestamp + 1 days), SessionScopes.ALL, type(uint256).max, address(0)
        );
        assertEq(sessions.agentGenerationOf(fresh), 2);
        assertTrue(sessions.isKeyValid(worker, key));
    }

    // ——— allowance ———

    function test_allowanceFromPreviousIncarnationIsNotSpendable() public {
        _readd(worker, IOrgRegistry.NodeKind.WorkerAgent, manager);
        vm.prank(address(router));
        vm.expectRevert(abi.encodeWithSelector(Treasury.StaleAllowance.selector, worker));
        treasury.spendAllowance(worker, 1 * ONE, payee);

        vm.expectRevert(abi.encodeWithSelector(Treasury.StaleAllowance.selector, worker));
        treasury.streamAllowance(worker, 1 * ONE, 2);
    }

    function test_revokingStaleAllowanceLetsTheNodeStartFresh() public {
        _readd(worker, IOrgRegistry.NodeKind.WorkerAgent, manager);
        treasury.revokeAllowance(worker, 5_000 * ONE);
        assertEq(treasury.allowanceBalance(worker), 0);

        treasury.streamAllowance(worker, 100 * ONE, 2);
        assertEq(treasury.allowanceGeneration(worker), 2);
        vm.prank(address(router));
        treasury.spendAllowance(worker, 100 * ONE, payee);
        assertEq(usdc.balanceOf(payee), 100 * ONE);
    }

    function test_allowanceOfLiveNodeStillSpends() public {
        vm.prank(address(router));
        treasury.spendAllowance(worker, 10 * ONE, payee);
        assertEq(usdc.balanceOf(payee), 10 * ONE);
    }
}
