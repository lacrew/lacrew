// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {OrgRegistry} from "../src/OrgRegistry.sol";
import {EscalationRouter} from "../src/EscalationRouter.sol";
import {Treasury} from "../src/Treasury.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {SpendCapPolicy} from "../src/policies/SpendCapPolicy.sol";
import {IOrgRegistry} from "../src/interfaces/IOrgRegistry.sol";

/// Emergency pause: any human seat stops settlement and streaming, only the
/// governance authority lifts it, and reject paths stay open throughout.
contract EmergencyPauseTest is Test {
    address internal root = makeAddr("root");
    address internal coHuman = makeAddr("coHuman");
    address internal manager = makeAddr("manager");
    address internal worker = makeAddr("worker");
    address internal payee = makeAddr("payee");
    address internal stranger = makeAddr("stranger");
    address internal gov = makeAddr("gov");

    uint256 internal constant ONE = 1e6;

    OrgRegistry internal registry;
    EscalationRouter internal router;
    Treasury internal treasury;
    MockUSDC internal usdc;

    function setUp() public {
        registry = new OrgRegistry(root);
        vm.startPrank(root);
        registry.addNode(coHuman, IOrgRegistry.NodeKind.HumanRoot, root);
        registry.addNode(manager, IOrgRegistry.NodeKind.ManagerAgent, root);
        registry.addNode(worker, IOrgRegistry.NodeKind.WorkerAgent, manager);
        vm.stopPrank();

        SpendCapPolicy cap = new SpendCapPolicy(100 * ONE);
        cap.setAgentCap(manager, 300 * ONE);
        router = new EscalationRouter(address(registry), address(cap));
        usdc = new MockUSDC();
        treasury = new Treasury(address(registry), address(usdc), address(router));
        router.setTreasury(address(treasury));
        usdc.mint(address(this), 10_000 * ONE);
        usdc.approve(address(treasury), type(uint256).max);
        treasury.deposit(10_000 * ONE);
        treasury.streamAllowance(worker, 5_000 * ONE, 1);
    }

    function test_humanSeatPausesBoth() public {
        vm.prank(coHuman);
        router.pause();
        vm.prank(root);
        treasury.pause();
        assertTrue(router.paused());
        assertTrue(treasury.paused());
    }

    function test_nonHumanCannotPause() public {
        vm.startPrank(manager);
        vm.expectRevert(abi.encodeWithSelector(EscalationRouter.NotAuthorized.selector, manager));
        router.pause();
        vm.expectRevert(abi.encodeWithSelector(Treasury.NotAuthorized.selector, manager));
        treasury.pause();
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(EscalationRouter.NotAuthorized.selector, stranger));
        router.pause();
    }

    function test_deactivatedHumanCannotPause() public {
        vm.prank(root);
        registry.setActive(coHuman, false);
        vm.prank(coHuman);
        vm.expectRevert(abi.encodeWithSelector(EscalationRouter.NotAuthorized.selector, coHuman));
        router.pause();
    }

    function test_pausedRouterBlocksAllowSettlement() public {
        vm.prank(root);
        router.pause();
        vm.expectRevert(EscalationRouter.EnforcedPause.selector);
        router.propose(worker, payee, 50 * ONE, "");
        assertEq(usdc.balanceOf(payee), 0);
    }

    function test_pausedRouterBlocksApprovalButNotRejection() public {
        (uint256 a,) = router.propose(worker, payee, 150 * ONE, "");
        (uint256 b,) = router.propose(worker, payee, 160 * ONE, "");
        vm.prank(root);
        router.pause();

        vm.prank(manager);
        vm.expectRevert(EscalationRouter.EnforcedPause.selector);
        router.resolve(a, true);

        vm.prank(manager);
        router.resolve(b, false);
        (,,,,, bool resolved, bool approved) = router.intents(b);
        assertTrue(resolved);
        assertFalse(approved);
        assertEq(usdc.balanceOf(payee), 0);
    }

    function test_pausedRouterStillEscalates() public {
        vm.prank(root);
        router.pause();
        (uint256 id,) = router.propose(worker, payee, 150 * ONE, "");
        assertEq(id, 1);
    }

    function test_pausedTreasuryBlocksStreamSpendKeepsDeposit() public {
        vm.prank(root);
        treasury.pause();
        vm.expectRevert(Treasury.EnforcedPause.selector);
        treasury.streamAllowance(worker, ONE, 2);
        vm.expectRevert(Treasury.EnforcedPause.selector);
        router.propose(worker, payee, 50 * ONE, "");
        usdc.mint(address(this), ONE);
        treasury.deposit(ONE);
    }

    function test_onlyAuthorityUnpauses() public {
        vm.prank(root);
        router.pause();
        vm.prank(root);
        vm.expectRevert(abi.encodeWithSelector(EscalationRouter.NotAuthorized.selector, root));
        router.unpause();

        router.unpause(); // deployer = this test, the bootstrap authority
        assertFalse(router.paused());
        router.propose(worker, payee, 50 * ONE, "");
        assertEq(usdc.balanceOf(payee), 50 * ONE);
    }

    function test_unpauseAfterGovernorBound() public {
        router.setGovernor(gov);
        treasury.setGovernor(gov);
        vm.prank(root);
        router.pause();
        vm.prank(root);
        treasury.pause();

        vm.expectRevert(abi.encodeWithSelector(EscalationRouter.NotAuthorized.selector, address(this)));
        router.unpause();
        vm.startPrank(gov);
        router.unpause();
        treasury.unpause();
        vm.stopPrank();
        assertFalse(router.paused());
        assertFalse(treasury.paused());
    }

    function test_doublePauseAndUnpauseUnpausedRevert() public {
        vm.expectRevert(EscalationRouter.NotPaused.selector);
        router.unpause();
        vm.prank(root);
        router.pause();
        vm.prank(root);
        vm.expectRevert(EscalationRouter.AlreadyPaused.selector);
        router.pause();
    }
}
