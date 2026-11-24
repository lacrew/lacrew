// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {OrgRegistry} from "../src/OrgRegistry.sol";
import {SessionRegistry} from "../src/SessionRegistry.sol";
import {SessionScopes} from "../src/SessionScopes.sol";
import {GovernanceModule} from "../src/GovernanceModule.sol";
import {EscalationRouter} from "../src/EscalationRouter.sol";
import {Treasury} from "../src/Treasury.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {SpendCapPolicy} from "../src/policies/SpendCapPolicy.sol";
import {IOrgRegistry} from "../src/interfaces/IOrgRegistry.sol";

/// Root key rotation: a lost or compromised root is replaced by a High-tier proposal
/// that moves the tree's top, session issuance, the governance seat and the router's
/// fallback resolve authority together — and governance can act on a compromised
/// session issuer without the root's signature.
contract RootRotationTest is Test {
    uint256 internal constant ONE = 1e6;

    address internal root = makeAddr("root");
    address internal partner = makeAddr("partner");
    address internal fresh = makeAddr("fresh");
    address internal manager = makeAddr("manager");
    address internal worker = makeAddr("worker");
    address internal payee = makeAddr("payee");
    address internal orchestrator = makeAddr("orchestrator");
    address internal stranger = makeAddr("stranger");

    OrgRegistry internal registry;
    SessionRegistry internal sessions;
    GovernanceModule internal gov;
    EscalationRouter internal router;
    Treasury internal treasury;
    MockUSDC internal usdc;

    function setUp() public {
        registry = new OrgRegistry(root);
        sessions = new SessionRegistry(root);
        gov = new GovernanceModule(root, 2);

        vm.startPrank(root);
        registry.addNode(partner, IOrgRegistry.NodeKind.HumanRoot, root);
        registry.addNode(manager, IOrgRegistry.NodeKind.ManagerAgent, root);
        registry.addNode(worker, IOrgRegistry.NodeKind.WorkerAgent, manager);
        sessions.setIssuer(orchestrator);
        gov.setVotingPower(manager, 1, GovernanceModule.SeatRole.Agent);
        vm.stopPrank();

        SpendCapPolicy spendCap = new SpendCapPolicy(100 * ONE);
        spendCap.setAgentCap(manager, 300 * ONE);
        router = new EscalationRouter(address(registry), address(spendCap));
        usdc = new MockUSDC();
        treasury = new Treasury(address(registry), address(usdc), address(router));
        router.setTreasury(address(treasury));
        usdc.mint(address(this), 10_000 * ONE);
        usdc.approve(address(treasury), type(uint256).max);
        treasury.deposit(10_000 * ONE);
        treasury.streamAllowance(worker, 5_000 * ONE, 1);

        vm.startPrank(root);
        registry.setGovernor(address(gov));
        sessions.setGovernor(address(gov));
        vm.stopPrank();
    }

    // ——— helpers ———

    function _rooted() internal view returns (address[] memory r) {
        r = new address[](2);
        r[0] = address(registry);
        r[1] = address(sessions);
    }

    /// Seat the partner as a second human through governance (root clears it alone).
    function _seatPartner() internal {
        _pass(address(gov), abi.encodeCall(GovernanceModule.admitHuman, (partner, 2)), _voters(root));
    }

    function _voters(address a) internal pure returns (address[] memory v) {
        v = new address[](1);
        v[0] = a;
    }

    function _voters(address a, address b) internal pure returns (address[] memory v) {
        v = new address[](2);
        v[0] = a;
        v[1] = b;
    }

    /// Propose High tier, vote yes with `voters`, wait out the timelock, execute.
    function _pass(address target, bytes memory data, address[] memory voters) internal returns (uint256 id) {
        vm.prank(voters[0]);
        id = gov.propose(GovernanceModule.Tier.High, target, data);
        for (uint256 i = 0; i < voters.length; i++) {
            vm.prank(voters[i]);
            gov.vote(id, true);
        }
        vm.warp(block.timestamp + gov.votingPeriod() + gov.highTierTimelock() + 1);
        gov.execute(id);
    }

    function _rotate(address newRoot, address[] memory voters) internal {
        _pass(address(gov), abi.encodeCall(GovernanceModule.rotateRoot, (newRoot, _rooted())), voters);
    }

    // ——— full rotation to a fresh key ———

    function test_rotationToFreshKeyMovesEveryRoot() public {
        _rotate(fresh, _voters(root));

        assertEq(registry.root(), fresh);
        assertEq(sessions.humanRoot(), fresh);
        assertEq(gov.humanRoot(), fresh);

        // The tree hangs from the new root; the old root's node is gone.
        IOrgRegistry.Node memory n = registry.getNode(fresh);
        assertEq(uint8(n.kind), uint8(IOrgRegistry.NodeKind.HumanRoot));
        assertEq(n.parent, address(0));
        assertEq(registry.getNode(manager).parent, fresh);
        assertEq(registry.getNode(partner).parent, fresh);
        assertEq(registry.getChildren(fresh).length, 2);
        assertEq(registry.getChildren(root).length, 0);
        vm.expectRevert(abi.encodeWithSelector(OrgRegistry.NodeNotFound.selector, root));
        registry.getNode(root);

        // The seat moved with its weight; the old key holds none.
        assertEq(uint8(gov.seatRole(fresh)), uint8(GovernanceModule.SeatRole.Human));
        assertEq(gov.votingPower(fresh), 2);
        assertEq(gov.votingPower(root), 0);
        assertEq(gov.humanSeatCount(), 1);
        assertEq(gov.totalHumanVotingPower(), 2);

        // A separate issuer (the orchestrator) is untouched.
        assertEq(sessions.issuer(), orchestrator);
    }

    function test_retiredRootLosesDirectAuthority() public {
        _rotate(fresh, _voters(root));

        vm.startPrank(root);
        vm.expectRevert(abi.encodeWithSelector(GovernanceModule.NotHumanRoot.selector, root));
        gov.setQuorumYes(3);
        vm.expectRevert(abi.encodeWithSelector(SessionRegistry.NotAuthorized.selector, root));
        sessions.setMaxIssuerTtl(1 days);
        vm.expectRevert(abi.encodeWithSelector(SessionRegistry.NotAuthorized.selector, root));
        sessions.issue(worker, root, uint64(block.timestamp + 1 hours), SessionScopes.ALL, 1, address(0));
        vm.expectRevert(abi.encodeWithSelector(GovernanceModule.NotHumanSeat.selector, root));
        gov.veto(1);
        vm.stopPrank();

        // The new root has them.
        vm.startPrank(fresh);
        gov.setQuorumYes(3);
        sessions.setMaxIssuerTtl(1 days);
        sessions.issue(worker, fresh, uint64(block.timestamp + 1 hours), SessionScopes.ALL, 1, address(0));
        vm.stopPrank();
    }

    function test_issuerThatWasTheRootFollowsTheRotation() public {
        vm.prank(root);
        sessions.setIssuer(root);
        _rotate(fresh, _voters(root));
        assertEq(sessions.issuer(), fresh);
    }

    function test_routerFallbackResolveFollowsTheRoot() public {
        (uint256 id,) = router.propose(worker, payee, 150 * ONE, "");
        _rotate(fresh, _voters(root));
        _pass(address(registry), abi.encodeCall(OrgRegistry.setActive, (manager, false)), _voters(fresh));

        vm.prank(root);
        vm.expectRevert(abi.encodeWithSelector(EscalationRouter.NotAwaitingApprover.selector, root));
        router.resolve(id, false);

        vm.prank(fresh);
        router.resolve(id, false);
        (,,,,, bool resolved,) = router.intents(id);
        assertTrue(resolved);
    }

    // ——— promoting a seated partner ———

    function test_promotingAPartnerRevokesTheOldSeat() public {
        _seatPartner();
        _rotate(partner, _voters(root, partner));

        assertEq(registry.root(), partner);
        assertEq(registry.getNode(partner).parent, address(0));
        assertEq(registry.getNode(manager).parent, partner);
        assertEq(registry.getChildren(partner).length, 1);
        assertEq(gov.humanRoot(), partner);
        assertEq(sessions.humanRoot(), partner);
        // The partner keeps its own weight; the retired seat is simply gone.
        assertEq(gov.votingPower(partner), 2);
        assertEq(gov.votingPower(root), 0);
        assertEq(gov.humanSeatCount(), 1);
    }

    function test_anyHumanVetoBlocksARotation() public {
        _seatPartner();
        vm.prank(root);
        uint256 id = gov.propose(
            GovernanceModule.Tier.High, address(gov), abi.encodeCall(GovernanceModule.rotateRoot, (stranger, _rooted()))
        );
        vm.prank(root);
        gov.vote(id, true);
        vm.prank(partner);
        gov.veto(id);
        vm.warp(block.timestamp + 10 days);
        vm.expectRevert(abi.encodeWithSelector(GovernanceModule.ProposalNotActive.selector, id));
        gov.execute(id);
        assertEq(registry.root(), root);
    }

    // ——— what a rotation refuses ———

    function test_rootAuthorityCannotRideTheLowTier() public {
        vm.startPrank(root);
        vm.expectRevert(GovernanceModule.RootAuthorityNotHighTier.selector);
        gov.propose(GovernanceModule.Tier.Low, address(registry), abi.encodeCall(OrgRegistry.rotateRoot, (stranger)));
        vm.expectRevert(GovernanceModule.RootAuthorityNotHighTier.selector);
        gov.propose(GovernanceModule.Tier.Low, address(sessions), abi.encodeCall(SessionRegistry.rotateRoot, (stranger)));
        vm.expectRevert(GovernanceModule.RootAuthorityNotHighTier.selector);
        gov.propose(GovernanceModule.Tier.Low, address(sessions), abi.encodeCall(SessionRegistry.setIssuer, (stranger)));
        vm.expectRevert(GovernanceModule.SelfTargetNotHighTier.selector);
        gov.propose(
            GovernanceModule.Tier.Low, address(gov), abi.encodeCall(GovernanceModule.rotateRoot, (stranger, _rooted()))
        );
        vm.stopPrank();
    }

    function test_noKeyRotatesAGovernedRoot() public {
        vm.startPrank(root);
        vm.expectRevert(abi.encodeWithSelector(GovernanceModule.NotGovernance.selector, root));
        gov.rotateRoot(stranger, _rooted());
        vm.expectRevert(abi.encodeWithSelector(OrgRegistry.NotAuthorized.selector, root));
        registry.rotateRoot(stranger);
        vm.expectRevert(abi.encodeWithSelector(SessionRegistry.NotAuthorized.selector, root));
        sessions.rotateRoot(stranger);
        vm.stopPrank();
    }

    function test_rotationToAnAgentSeatReverts() public {
        vm.prank(root);
        uint256 id = gov.propose(
            GovernanceModule.Tier.High, address(gov), abi.encodeCall(GovernanceModule.rotateRoot, (manager, _rooted()))
        );
        vm.prank(root);
        gov.vote(id, true);
        vm.expectRevert(abi.encodeWithSelector(GovernanceModule.ActionFailed.selector, address(gov)));
        gov.execute(id);
        assertEq(gov.humanRoot(), root);
    }

    function test_rotationFailingOnAnyContractRevertsAsAWhole() public {
        // A rooted contract the module does not govern refuses, so nothing moves.
        SessionRegistry ungoverned = new SessionRegistry(root);
        address[] memory r = new address[](2);
        r[0] = address(registry);
        r[1] = address(ungoverned);
        vm.prank(root);
        uint256 id =
            gov.propose(GovernanceModule.Tier.High, address(gov), abi.encodeCall(GovernanceModule.rotateRoot, (fresh, r)));
        vm.prank(root);
        gov.vote(id, true);
        vm.expectRevert(abi.encodeWithSelector(GovernanceModule.ActionFailed.selector, address(gov)));
        gov.execute(id);
        assertEq(registry.root(), root);
        assertEq(gov.humanRoot(), root);
    }

    // ——— OrgRegistry.rotateRoot directly ———

    function test_registryRefusesAnAgentOrADeepHumanAsRoot() public {
        OrgRegistry tree = new OrgRegistry(root);
        address deepHuman = makeAddr("deepHuman");
        vm.startPrank(root);
        tree.addNode(manager, IOrgRegistry.NodeKind.ManagerAgent, root);
        tree.addNode(deepHuman, IOrgRegistry.NodeKind.HumanRoot, manager);
        vm.expectRevert(abi.encodeWithSelector(OrgRegistry.InvalidRoot.selector, manager));
        tree.rotateRoot(manager);
        vm.expectRevert(abi.encodeWithSelector(OrgRegistry.InvalidRoot.selector, deepHuman));
        tree.rotateRoot(deepHuman);
        vm.expectRevert(OrgRegistry.ZeroAddress.selector);
        tree.rotateRoot(address(0));
        // Before a governor is bound the root may hand itself on.
        tree.rotateRoot(fresh);
        vm.stopPrank();
        assertEq(tree.root(), fresh);
        assertEq(tree.getNode(manager).parent, fresh);
    }

    // ——— SessionRegistry governor ———

    function test_governorReplacesACompromisedIssuer() public {
        vm.prank(orchestrator);
        uint256 sid = sessions.issue(worker, stranger, uint64(block.timestamp + 1 hours), SessionScopes.ALL, 1, address(0));

        // Governance acts on the issuer and its sessions without the root's key.
        vm.startPrank(address(gov));
        sessions.revoke(sid);
        sessions.setIssuer(fresh);
        vm.stopPrank();
        assertFalse(sessions.isValid(sid));
        assertEq(sessions.issuer(), fresh);

        vm.prank(orchestrator);
        vm.expectRevert(abi.encodeWithSelector(SessionRegistry.NotAuthorized.selector, orchestrator));
        sessions.issue(worker, stranger, uint64(block.timestamp + 1 hours), SessionScopes.ALL, 1, address(0));
    }

    function test_governorIssuerChangeThroughAProposal() public {
        _pass(address(sessions), abi.encodeCall(SessionRegistry.setIssuer, (fresh)), _voters(root));
        assertEq(sessions.issuer(), fresh);
    }

    function test_sessionGovernorBinding() public {
        SessionRegistry s = new SessionRegistry(root);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SessionRegistry.NotAuthorized.selector, stranger));
        s.setGovernor(stranger);
        vm.prank(root);
        s.setGovernor(address(gov));
        assertEq(s.governor(), address(gov));
        // Once bound only the governor rebinds.
        vm.prank(root);
        vm.expectRevert(abi.encodeWithSelector(SessionRegistry.NotAuthorized.selector, root));
        s.setGovernor(root);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SessionRegistry.NotAuthorized.selector, stranger));
        s.setIssuer(stranger);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SessionRegistry.NotAuthorized.selector, stranger));
        s.revoke(1);
    }

    // ——— bootstrap ———

    function test_unseatedOrgRootRotatesDirectly() public {
        GovernanceModule bare = new GovernanceModule(root, 0);
        OrgRegistry tree = new OrgRegistry(root);
        vm.prank(root);
        tree.setGovernor(address(bare));
        address[] memory r = new address[](1);
        r[0] = address(tree);
        vm.prank(root);
        bare.rotateRoot(fresh, r);
        assertEq(bare.humanRoot(), fresh);
        assertEq(tree.root(), fresh);
        assertEq(bare.humanSeatCount(), 0);
    }
}
