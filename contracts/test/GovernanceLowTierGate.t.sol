// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {OrgRegistry} from "../src/OrgRegistry.sol";
import {Treasury} from "../src/Treasury.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {EscalationRouter} from "../src/EscalationRouter.sol";
import {GovernanceModule} from "../src/GovernanceModule.sol";
import {WhitelistPolicy} from "../src/policies/WhitelistPolicy.sol";
import {IOrgRegistry} from "../src/interfaces/IOrgRegistry.sol";

/// @notice Regression for the low-tier audit finding: with the root at power 2 and two
///         agent seats at power 1 (quorum 2), the agents used to pass and execute a
///         low-tier proposal in the block it was created — firing a human, handing the
///         treasury a spender, or stripping their own policy — even with the root
///         voting against. The low tier now carries only allow-listed actions, waits a
///         delay every human can act in, and needs more yes-weight than no-weight.
contract GovernanceLowTierGateTest is Test {
    address internal root = makeAddr("root");
    address internal peerHuman = makeAddr("peer-human");
    address internal agentA = makeAddr("agent-a");
    address internal agentB = makeAddr("agent-b");
    address internal stranger = makeAddr("stranger");

    MockUSDC internal usdc;
    OrgRegistry internal registry;
    Treasury internal treasury;
    EscalationRouter internal router;
    GovernanceModule internal gov;

    function setUp() public {
        usdc = new MockUSDC();
        registry = new OrgRegistry(root);
        vm.startPrank(root);
        registry.addNode(peerHuman, IOrgRegistry.NodeKind.HumanRoot, root);
        registry.addNode(agentA, IOrgRegistry.NodeKind.ManagerAgent, root);
        registry.addNode(agentB, IOrgRegistry.NodeKind.WorkerAgent, agentA);
        vm.stopPrank();

        WhitelistPolicy whitelist = new WhitelistPolicy();
        router = new EscalationRouter(address(registry), address(whitelist));
        treasury = new Treasury(address(registry), address(usdc), address(router));
        router.setTreasury(address(treasury));

        gov = new GovernanceModule(root, 2);
        vm.startPrank(root);
        gov.setVotingPower(agentA, 1, GovernanceModule.SeatRole.Agent);
        gov.setVotingPower(agentB, 1, GovernanceModule.SeatRole.Agent);
        gov.setQuorumYes(2);
        registry.setGovernor(address(gov));
        vm.stopPrank();
        treasury.setGovernor(address(gov));
        router.setGovernor(address(gov));
    }

    function _proposeAs(address who, GovernanceModule.Tier tier, address target, bytes memory data)
        internal
        returns (uint256 id)
    {
        vm.prank(who);
        id = gov.propose(tier, target, data);
    }

    function _vote(address who, uint256 id, bool support) internal {
        vm.prank(who);
        gov.vote(id, support);
    }

    function _eta(uint256 id) internal view returns (uint256 eta) {
        (,,,,,,,,, eta,) = gov.proposals(id);
    }

    function _deadline(uint256 id) internal view returns (uint256 deadline) {
        (,,,,,,,, deadline,,) = gov.proposals(id);
    }

    function _state(uint256 id) internal view returns (GovernanceModule.ProposalState state) {
        (,,,,,,,,,, state) = gov.proposals(id);
    }

    function _hire(address account, IOrgRegistry.NodeKind kind) internal view returns (bytes memory) {
        return abi.encodeCall(OrgRegistry.addNode, (account, kind, root));
    }

    function _expectNotLowTier(bytes4 selector) internal {
        vm.expectRevert(abi.encodeWithSelector(GovernanceModule.ActionNotLowTier.selector, selector));
    }

    // ——— The three PoC payloads can no longer ride the low tier ———

    function test_agentsCannotFireAHumanOnLowTier() public {
        _expectNotLowTier(OrgRegistry.removeNode.selector);
        _proposeAs(
            agentA, GovernanceModule.Tier.Low, address(registry), abi.encodeCall(OrgRegistry.removeNode, (peerHuman))
        );
    }

    function test_agentsCannotSetATreasurySpenderOnLowTier() public {
        _expectNotLowTier(Treasury.setSpender.selector);
        _proposeAs(agentA, GovernanceModule.Tier.Low, address(treasury), abi.encodeCall(Treasury.setSpender, (agentA)));
    }

    function test_agentsCannotStripTheirOwnPolicyOnLowTier() public {
        _expectNotLowTier(EscalationRouter.setNodePolicy.selector);
        _proposeAs(
            agentA,
            GovernanceModule.Tier.Low,
            address(router),
            abi.encodeCall(EscalationRouter.setNodePolicy, (agentA, address(0)))
        );
    }

    /// On the high tier the same payloads need human yes-weight: the two agents
    /// together satisfy nothing.
    function test_agentsAloneCannotCarryTheHighTierPayloads() public {
        address spenderBefore = treasury.spender();
        uint256 id = _proposeAs(
            agentA, GovernanceModule.Tier.High, address(treasury), abi.encodeCall(Treasury.setSpender, (agentA))
        );
        _vote(agentA, id, true);
        _vote(agentB, id, true);
        vm.warp(_eta(id) + 1);
        vm.expectRevert(abi.encodeWithSelector(GovernanceModule.QuorumNotMet.selector, id));
        gov.execute(id);
        assertEq(treasury.spender(), spenderBefore);
    }

    // ——— What the low tier still carries is time-gated and must out-vote the no side ———

    function test_lowTierHireCannotExecuteInTheBlockItWasProposed() public {
        address hire = makeAddr("hire");
        uint256 id = _proposeAs(
            agentA, GovernanceModule.Tier.Low, address(registry), _hire(hire, IOrgRegistry.NodeKind.WorkerAgent)
        );
        _vote(agentA, id, true);
        _vote(agentB, id, true);
        assertEq(_eta(id), block.timestamp + gov.lowTierDelay());

        vm.expectRevert(abi.encodeWithSelector(GovernanceModule.TimelockNotElapsed.selector, id, _eta(id)));
        gov.execute(id);

        // The root had the whole delay to weigh in; it did not, so the hire stands.
        vm.warp(_eta(id));
        gov.execute(id);
        assertEq(registry.getNode(hire).account, hire);
    }

    function test_rootVoteAgainstBlocksTheAgentsAtEveryExecute() public {
        address hire = makeAddr("contested-hire");
        uint256 id = _proposeAs(
            agentA, GovernanceModule.Tier.Low, address(registry), _hire(hire, IOrgRegistry.NodeKind.WorkerAgent)
        );
        _vote(agentA, id, true);
        _vote(agentB, id, true);
        _vote(root, id, false);

        // Yes 2 vs no 2: quorum is met but the proposal is not carried.
        vm.warp(_eta(id));
        vm.expectRevert(abi.encodeWithSelector(GovernanceModule.Outvoted.selector, id));
        gov.execute(id);
        assertEq(uint8(_state(id)), uint8(GovernanceModule.ProposalState.Active));

        // Once voting closes, the same tally is a defeat.
        vm.warp(_deadline(id) + 1);
        gov.execute(id);
        assertEq(uint8(_state(id)), uint8(GovernanceModule.ProposalState.Defeated));
        vm.expectRevert(abi.encodeWithSelector(OrgRegistry.NodeNotFound.selector, hire));
        registry.getNode(hire);
    }

    function test_rootCanVetoDuringTheLowTierDelay() public {
        uint256 id = _proposeAs(
            agentA,
            GovernanceModule.Tier.Low,
            address(registry),
            _hire(makeAddr("vetoed-hire"), IOrgRegistry.NodeKind.WorkerAgent)
        );
        _vote(agentA, id, true);
        _vote(agentB, id, true);
        vm.prank(root);
        gov.veto(id);
        vm.warp(_eta(id));
        vm.expectRevert(abi.encodeWithSelector(GovernanceModule.ProposalNotActive.selector, id));
        gov.execute(id);
    }

    function test_lowTierHireMayNotSeatAHumanRoot() public {
        _expectNotLowTier(OrgRegistry.addNode.selector);
        _proposeAs(agentA, GovernanceModule.Tier.Low, address(registry), _hire(agentB, IOrgRegistry.NodeKind.HumanRoot));
        // Truncated calldata cannot slip past the kind check either.
        _expectNotLowTier(OrgRegistry.addNode.selector);
        _proposeAs(agentA, GovernanceModule.Tier.Low, address(registry), abi.encodePacked(OrgRegistry.addNode.selector));
        _expectNotLowTier(bytes4(0));
        _proposeAs(agentA, GovernanceModule.Tier.Low, address(registry), "");
    }

    /// When every human has voted yes there is nobody left for the delay to protect.
    function test_unanimousHumanYesSkipsTheLowTierDelay() public {
        address hire = makeAddr("root-backed-hire");
        uint256 id = _proposeAs(
            root, GovernanceModule.Tier.Low, address(registry), _hire(hire, IOrgRegistry.NodeKind.WorkerAgent)
        );
        _vote(root, id, true);
        gov.execute(id);
        assertEq(registry.getNode(hire).account, hire);
    }

    // ——— Proposers and the curated list ———

    function test_strangerCannotPropose() public {
        vm.expectRevert(abi.encodeWithSelector(GovernanceModule.NoVotingPower.selector, stranger));
        _proposeAs(
            stranger, GovernanceModule.Tier.High, address(registry), _hire(stranger, IOrgRegistry.NodeKind.WorkerAgent)
        );
    }

    function test_onlyRootOrGovernanceCuratesTheLowTier() public {
        vm.expectRevert(abi.encodeWithSelector(GovernanceModule.NotHumanRoot.selector, agentA));
        vm.prank(agentA);
        gov.setLowTierSelector(Treasury.setSpender.selector, true);

        vm.expectRevert(abi.encodeWithSelector(GovernanceModule.NotHumanRoot.selector, agentA));
        vm.prank(agentA);
        gov.setLowTierDelay(0);

        vm.prank(root);
        gov.setLowTierSelector(OrgRegistry.setActive.selector, true);
        assertTrue(gov.lowTierSelector(OrgRegistry.setActive.selector));

        vm.prank(root);
        gov.setLowTierSelector(OrgRegistry.addNode.selector, false);
        _expectNotLowTier(OrgRegistry.addNode.selector);
        _proposeAs(
            agentA,
            GovernanceModule.Tier.Low,
            address(registry),
            _hire(makeAddr("x"), IOrgRegistry.NodeKind.WorkerAgent)
        );

        uint256 tooLong = gov.MAX_TIMELOCK() + 1;
        vm.expectRevert(abi.encodeWithSelector(GovernanceModule.InvalidLowTierDelay.selector, tooLong));
        vm.prank(root);
        gov.setLowTierDelay(tooLong);
    }

    /// Any selector the module has not allow-listed is refused on the low tier.
    function testFuzz_unlistedSelectorsAreNeverLowTier(bytes4 selector, bytes calldata rest) public {
        vm.assume(!gov.lowTierSelector(selector));
        bytes memory data = abi.encodePacked(selector, rest);
        bytes4 setGovernor = gov.SET_GOVERNOR_SELECTOR();
        if (selector == setGovernor) {
            vm.expectRevert(GovernanceModule.GovernorTransferNotHighTier.selector);
        } else {
            _expectNotLowTier(selector);
        }
        _proposeAs(agentA, GovernanceModule.Tier.Low, address(treasury), data);
    }
}
