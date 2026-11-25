// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {GovernanceModule} from "../src/GovernanceModule.sol";
import {OrgRegistry} from "../src/OrgRegistry.sol";
import {IOrgRegistry} from "../src/interfaces/IOrgRegistry.sol";
import {Treasury} from "../src/Treasury.sol";
import {EpochStreamer} from "../src/EpochStreamer.sol";
import {EscalationRouter} from "../src/EscalationRouter.sol";
import {MarketplacePayments} from "../src/MarketplacePayments.sol";
import {WhitelistPolicy} from "../src/policies/WhitelistPolicy.sol";
import {RateLimitPolicy} from "../src/policies/RateLimitPolicy.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

/// @dev Audit proofs of concept, kept as regression tests. Each one replays the attack
///      from the audit and asserts the FIXED behaviour as main implements it: the exploit
///      step reverts with the specific error (or the safe outcome holds). The finding each
///      test covers is named in its comment.
contract AuditPoC is Test {
    address root = makeAddr("root");
    address human2 = makeAddr("human2");
    address agentA = makeAddr("agentA");
    address agentB = makeAddr("agentB");

    /// @dev Covers: low-tier governance gate (#628). Agent seats could fire a human via a
    ///      Low-tier `removeNode` proposal carried by agent votes alone. `removeNode` is
    ///      not on the low-tier allow-list, so the proposal cannot even be created.
    function test_lowTierAgentsFireHumanInstantly() public {
        OrgRegistry reg = new OrgRegistry(root);
        GovernanceModule gov = new GovernanceModule(root, 2);
        vm.startPrank(root);
        reg.addNode(human2, IOrgRegistry.NodeKind.HumanRoot, root);
        reg.setGovernor(address(gov));
        gov.setVotingPower(agentA, 1, GovernanceModule.SeatRole.Agent);
        gov.setVotingPower(agentB, 1, GovernanceModule.SeatRole.Agent);
        vm.stopPrank();

        vm.prank(agentA);
        vm.expectRevert(
            abi.encodeWithSelector(GovernanceModule.ActionNotLowTier.selector, OrgRegistry.removeNode.selector)
        );
        gov.propose(GovernanceModule.Tier.Low, address(reg), abi.encodeCall(OrgRegistry.removeNode, (human2)));

        // The human stays seated.
        assertTrue(reg.getNode(human2).active);
    }

    /// @dev Covers: low-tier governance gate (#628), human-seat hire. The one seeded
    ///      low-tier action (`addNode`) may not seat a HumanRoot, which the router
    ///      accepts as a final approver.
    function test_lowTierCannotHireHumanRoot() public {
        OrgRegistry reg = new OrgRegistry(root);
        GovernanceModule gov = new GovernanceModule(root, 2);
        vm.startPrank(root);
        reg.setGovernor(address(gov));
        gov.setVotingPower(agentA, 1, GovernanceModule.SeatRole.Agent);
        vm.stopPrank();

        vm.prank(agentA);
        vm.expectRevert(
            abi.encodeWithSelector(GovernanceModule.ActionNotLowTier.selector, OrgRegistry.addNode.selector)
        );
        gov.propose(
            GovernanceModule.Tier.Low,
            address(reg),
            abi.encodeCall(OrgRegistry.addNode, (agentB, IOrgRegistry.NodeKind.HumanRoot, root))
        );
    }

    /// @dev Covers: low-tier governance gate (#628), delay and Outvoted. An allow-listed
    ///      low-tier action carried by agent yes-votes while the human root voted no used
    ///      to execute at once. Now it waits out `lowTierDelay`, reverts `Outvoted` while
    ///      voting is open, and is closed as Defeated after the deadline.
    function test_lowTierExecutesWhileOutvoted() public {
        MockUSDC usdc = new MockUSDC();
        OrgRegistry reg = new OrgRegistry(root);
        GovernanceModule gov = new GovernanceModule(root, 5);
        Treasury t = new Treasury(address(reg), address(usdc), address(1));
        t.setGovernor(address(gov));
        vm.startPrank(root);
        gov.setVotingPower(agentA, 1, GovernanceModule.SeatRole.Agent);
        gov.setVotingPower(agentB, 1, GovernanceModule.SeatRole.Agent);
        // The root opts this selector into the low tier so the vote itself is what is tested.
        gov.setLowTierSelector(Treasury.setSpender.selector, true);
        vm.stopPrank();

        vm.prank(agentA);
        uint256 id = gov.propose(GovernanceModule.Tier.Low, address(t), abi.encodeCall(Treasury.setSpender, (agentA)));
        uint256 eta = block.timestamp + gov.lowTierDelay();
        vm.prank(root);
        gov.vote(id, false);
        vm.prank(agentA);
        gov.vote(id, true);
        vm.prank(agentB);
        gov.vote(id, true);

        // Before the delay has elapsed: refused.
        vm.expectRevert(abi.encodeWithSelector(GovernanceModule.TimelockNotElapsed.selector, id, eta));
        gov.execute(id);

        // Delay elapsed, but 2 yes against 5 no: Outvoted while voting is open.
        vm.warp(eta);
        assertLe(block.timestamp, _deadline(gov, id));
        vm.expectRevert(abi.encodeWithSelector(GovernanceModule.Outvoted.selector, id));
        gov.execute(id);

        // After the deadline it is closed as Defeated and never runs.
        vm.warp(_deadline(gov, id) + 1);
        gov.execute(id);
        assertNotEq(t.spender(), agentA);
        assertEq(uint8(_state(gov, id)), uint8(GovernanceModule.ProposalState.Defeated));
        vm.expectRevert(abi.encodeWithSelector(GovernanceModule.ProposalNotActive.selector, id));
        gov.execute(id);
    }

    /// @dev Covers: epoch cadence (#625). A compromised operator drained the whole
    ///      treasury by running ten epochs in one transaction. Epochs are now one per
    ///      period; a second run in the same period reverts `EpochNotReady`.
    function test_streamerOperatorDrainsLiquidityInOneTx() public {
        MockUSDC usdc = new MockUSDC();
        OrgRegistry reg = new OrgRegistry(root);
        Treasury t = new Treasury(address(reg), address(usdc), address(1));
        uint64 start = uint64(block.timestamp);
        EpochStreamer s = new EpochStreamer(address(t), root, start, 1 days);
        t.setStreamer(address(s));
        usdc.mint(address(t), 1_000e6);
        vm.startPrank(root);
        s.setGrant(agentA, 100e6);

        assertEq(s.runNextEpoch(), 1);
        // Same block, next epoch: not unlocked.
        vm.expectRevert(
            abi.encodeWithSelector(EpochStreamer.EpochNotReady.selector, uint64(2), uint256(start) + 1 days)
        );
        s.runNextEpoch();
        assertEq(t.allowanceBalance(agentA), 100e6);
        assertEq(t.liquidBalance(), 900e6);

        // A long-idle operator back-fills one epoch per call, never ahead of the clock.
        vm.warp(start + 3 days);
        s.runNextEpoch(); // epoch 2
        s.runNextEpoch(); // epoch 3
        s.runNextEpoch(); // epoch 4
        vm.expectRevert(
            abi.encodeWithSelector(EpochStreamer.EpochNotReady.selector, uint64(5), uint256(start) + 4 days)
        );
        s.runNextEpoch();
        vm.stopPrank();
        assertEq(t.allowanceBalance(agentA), 400e6);
        assertEq(t.liquidBalance(), 600e6);
    }

    /// @dev Covers: atomic settlement (#640) and exact-payment purchaseFor (#626). A
    ///      purchase with a too-low maxPrice used to complete with callOk=false, leaving
    ///      the agent's 100 USDC at the marketplace, where another agent claimed the
    ///      listing with a zero-value propose. Now the failed call reverts the whole
    ///      router action (allowance intact, nothing stranded), and a zero-value
    ///      `purchaseFor` reverts `DeliveryMismatch`.
    function test_failedPurchaseStrandsFundsThenStolen() public {
        MockUSDC usdc = new MockUSDC();
        OrgRegistry reg = new OrgRegistry(root);
        vm.startPrank(root);
        reg.addNode(agentA, IOrgRegistry.NodeKind.WorkerAgent, root);
        reg.addNode(agentB, IOrgRegistry.NodeKind.WorkerAgent, root);
        vm.stopPrank();
        WhitelistPolicy wl = new WhitelistPolicy();
        EscalationRouter r = new EscalationRouter(address(reg), address(wl));
        Treasury t = new Treasury(address(reg), address(usdc), address(r));
        r.setTreasury(address(t));
        MarketplacePayments m = new MarketplacePayments(address(usdc), root, root, 0);
        vm.prank(root);
        m.setSettlementRouter(address(r));
        wl.setAllowed(address(m), true);
        usdc.mint(address(t), 100e6);
        t.streamAllowance(agentA, 100e6, 1);

        address seller = makeAddr("seller");
        vm.prank(seller);
        m.registerListing(bytes32("L"), 100e6);

        // The failing purchase reverts as a whole: the spend is undone.
        vm.prank(agentA);
        vm.expectRevert(abi.encodeWithSelector(MarketplacePayments.PriceExceedsMax.selector, 100e6, 99e6));
        r.propose(
            agentA, address(m), 100e6, abi.encodeCall(MarketplacePayments.purchaseFor, (bytes32("L"), agentA, 99e6))
        );
        assertEq(t.allowanceBalance(agentA), 100e6);
        assertEq(usdc.balanceOf(address(m)), 0);
        assertEq(usdc.balanceOf(address(r)), 0);
        assertFalse(m.hasPurchased(bytes32("L"), agentA));

        // Nothing is stranded, so a zero-value claim on the listing cannot succeed.
        vm.prank(agentB);
        vm.expectRevert(abi.encodeWithSelector(MarketplacePayments.DeliveryMismatch.selector, 100e6, 0));
        r.propose(agentB, address(m), 0, abi.encodeCall(MarketplacePayments.purchaseFor, (bytes32("L"), agentB, 100e6)));
        assertFalse(m.hasPurchased(bytes32("L"), agentB));

        // The honest purchase with a sufficient maxPrice still goes through, paid exactly.
        vm.prank(agentA);
        r.propose(
            agentA, address(m), 100e6, abi.encodeCall(MarketplacePayments.purchaseFor, (bytes32("L"), agentA, 100e6))
        );
        assertTrue(m.hasPurchased(bytes32("L"), agentA));
        assertEq(t.allowanceBalance(agentA), 0);
        assertEq(usdc.balanceOf(address(m)), 100e6);
        assertEq(m.totalOwed(), 100e6);
    }

    /// @dev Covers: rate-count integrity (#623, protected recorders). Agent A used the
    ///      router to call agent B's rate recorder and burn B's rate window. The router
    ///      must not let one agent's action reach another agent's recorder.
    function test_crossAgentRateRecorderGrief() public {
        OrgRegistry reg = new OrgRegistry(root);
        vm.startPrank(root);
        reg.addNode(agentA, IOrgRegistry.NodeKind.WorkerAgent, root);
        reg.addNode(agentB, IOrgRegistry.NodeKind.WorkerAgent, root);
        vm.stopPrank();
        WhitelistPolicy wl = new WhitelistPolicy();
        EscalationRouter r = new EscalationRouter(address(reg), address(wl));
        RateLimitPolicy rlB = new RateLimitPolicy(1, 1 hours);
        rlB.setRecorder(address(r));
        r.setNodeRateRecorder(agentB, address(rlB));
        wl.setAllowed(address(rlB), true);
        vm.prank(agentA);
        r.propose(agentA, address(rlB), 0, abi.encodeCall(RateLimitPolicy.record, (agentB)));
        (, uint32 count) = rlB.windows(agentB);
        assertEq(count, 0, "agent A burned agent B's rate window");
    }

    function _deadline(GovernanceModule gov, uint256 id) private view returns (uint256 deadline) {
        (,,,,,,,, deadline,,) = gov.proposals(id);
    }

    function _state(GovernanceModule gov, uint256 id) private view returns (GovernanceModule.ProposalState state) {
        (,,,,,,,,,, state) = gov.proposals(id);
    }
}
