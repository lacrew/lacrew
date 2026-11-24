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

/// @notice Audit findings as executable tests (lacrew@1e353e1).
/// @dev Each finding has one of two shapes:
///      - open: `test_<finding>` is the PoC and passes while the bug exists; its
///        `test_fixed_<finding>` twin states the post-fix behaviour (a revert) and is
///        skipped until the fix lands. When it does, delete the PoC and drop the skip.
///      - fixed: `test_<finding>` asserts the post-fix behaviour and runs.
contract AuditPoC is Test {
    address root = makeAddr("root");
    address human2 = makeAddr("human2");
    address agentA = makeAddr("agentA");
    address agentB = makeAddr("agentB");

    // H-1: two agent seats pass a Low-tier proposal instantly, removing a human node,
    // even while the humans voted against it and before anyone can veto.
    function test_lowTierAgentsFireHumanInstantly() public {
        OrgRegistry reg = new OrgRegistry(root);
        GovernanceModule gov = new GovernanceModule(root, 2);
        vm.startPrank(root);
        reg.addNode(human2, IOrgRegistry.NodeKind.HumanRoot, root);
        reg.setGovernor(address(gov));
        gov.setVotingPower(agentA, 1, GovernanceModule.SeatRole.Agent);
        gov.setVotingPower(agentB, 1, GovernanceModule.SeatRole.Agent);
        vm.stopPrank();

        uint256 id = gov.propose(GovernanceModule.Tier.Low, address(reg), abi.encodeCall(OrgRegistry.removeNode, (human2)));
        vm.prank(root);
        gov.vote(id, false); // 2 weight against
        vm.prank(agentA);
        gov.vote(id, true);
        vm.prank(agentB);
        gov.vote(id, true); // 2 for, 2 against: quorum 2 met
        gov.execute(id); // same block, no veto window
        vm.expectRevert();
        reg.getNode(human2);
    }

    // H-1b: outvoted Low-tier proposal still executes before the deadline.
    function test_lowTierExecutesWhileOutvoted() public {
        Treasury t;
        MockUSDC usdc = new MockUSDC();
        OrgRegistry reg = new OrgRegistry(root);
        GovernanceModule gov = new GovernanceModule(root, 5);
        t = new Treasury(address(reg), address(usdc), address(1));
        t.setGovernor(address(gov));
        vm.startPrank(root);
        gov.setVotingPower(agentA, 1, GovernanceModule.SeatRole.Agent);
        gov.setVotingPower(agentB, 1, GovernanceModule.SeatRole.Agent);
        vm.stopPrank();
        uint256 id = gov.propose(GovernanceModule.Tier.Low, address(t), abi.encodeCall(Treasury.setSpender, (agentA)));
        vm.prank(root);
        gov.vote(id, false); // 5 against
        vm.prank(agentA);
        gov.vote(id, true);
        vm.prank(agentB);
        gov.vote(id, true);
        gov.execute(id);
        assertEq(t.spender(), agentA);
    }

    // M: the streamer operator books the whole treasury into allowances in one tx.
    function test_streamerOperatorDrainsLiquidityInOneTx() public {
        MockUSDC usdc = new MockUSDC();
        OrgRegistry reg = new OrgRegistry(root);
        Treasury t = new Treasury(address(reg), address(usdc), address(1));
        EpochStreamer s = new EpochStreamer(address(t), root);
        t.setStreamer(address(s));
        usdc.mint(address(t), 1_000e6);
        vm.startPrank(root);
        s.setGrant(agentA, 100e6);
        for (uint64 e = 1; e <= 10; e++) s.runEpoch(e + 1000);
        vm.stopPrank();
        assertEq(t.allowanceBalance(agentA), 1_000e6);
        assertEq(t.liquidBalance(), 0);
    }

    // M (fixed by pull settlement): a purchase whose call fails costs nothing, so there
    // are no stranded tokens for another router caller to claim with a value-0 purchaseFor.
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
        // agentA's call carries a maxPrice below the price -> inner call reverts
        vm.prank(agentA);
        r.propose(agentA, address(m), 100e6, abi.encodeCall(MarketplacePayments.purchaseFor, (bytes32("L"), agentA, 99e6)));
        assertEq(t.allowanceBalance(agentA), 100e6, "failed call is refunded");
        assertEq(usdc.balanceOf(address(r)), 0, "router keeps nothing");
        assertFalse(m.hasPurchased(bytes32("L"), agentA));
        assertEq(m.totalOwed(), 0);

        // agentB has no allowance: a value-0 purchaseFor approves nothing, so it buys nothing.
        vm.prank(agentB);
        r.propose(agentB, address(m), 0, abi.encodeCall(MarketplacePayments.purchaseFor, (bytes32("L"), agentB, 100e6)));
        assertFalse(m.hasPurchased(bytes32("L"), agentB), "no free purchase");
        assertEq(m.totalOwed(), 0);
        assertEq(usdc.balanceOf(address(t)), 100e6);
    }

    // L/M: agent A exhausts agent B's per-node rate recorder through the router.
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
        wl.setAllowed(address(rlB), true); // e.g. a permissive / allow-all policy
        vm.prank(agentA);
        r.propose(agentA, address(rlB), 0, abi.encodeCall(RateLimitPolicy.record, (agentB)));
        (, uint32 count) = rlB.windows(agentB);
        assertEq(count, 1);
    }

    // ——— Post-fix expectations for the open findings (skipped until each fix lands) ———

    // H-1 fix: a Low-tier proposal cannot execute before its deadline.
    function test_fixed_lowTierAgentsFireHumanInstantly() public {
        vm.skip(true); // TODO: remove once Low tier waits for its deadline
        OrgRegistry reg = new OrgRegistry(root);
        GovernanceModule gov = new GovernanceModule(root, 2);
        vm.startPrank(root);
        reg.addNode(human2, IOrgRegistry.NodeKind.HumanRoot, root);
        reg.setGovernor(address(gov));
        gov.setVotingPower(agentA, 1, GovernanceModule.SeatRole.Agent);
        gov.setVotingPower(agentB, 1, GovernanceModule.SeatRole.Agent);
        vm.stopPrank();

        uint256 id = gov.propose(GovernanceModule.Tier.Low, address(reg), abi.encodeCall(OrgRegistry.removeNode, (human2)));
        vm.prank(root);
        gov.vote(id, false);
        vm.prank(agentA);
        gov.vote(id, true);
        vm.prank(agentB);
        gov.vote(id, true);
        vm.expectRevert();
        gov.execute(id);
        reg.getNode(human2); // still seated
    }

    // H-1b fix: an outvoted Low-tier proposal does not execute.
    function test_fixed_lowTierExecutesWhileOutvoted() public {
        vm.skip(true); // TODO: remove once Low tier waits for its deadline
        MockUSDC usdc = new MockUSDC();
        OrgRegistry reg = new OrgRegistry(root);
        GovernanceModule gov = new GovernanceModule(root, 5);
        Treasury t = new Treasury(address(reg), address(usdc), address(1));
        t.setGovernor(address(gov));
        vm.startPrank(root);
        gov.setVotingPower(agentA, 1, GovernanceModule.SeatRole.Agent);
        gov.setVotingPower(agentB, 1, GovernanceModule.SeatRole.Agent);
        vm.stopPrank();
        uint256 id = gov.propose(GovernanceModule.Tier.Low, address(t), abi.encodeCall(Treasury.setSpender, (agentA)));
        vm.prank(root);
        gov.vote(id, false);
        vm.prank(agentA);
        gov.vote(id, true);
        vm.prank(agentB);
        gov.vote(id, true);
        vm.expectRevert();
        gov.execute(id);
        assertEq(t.spender(), address(1));
    }

    // M fix: one operator transaction series cannot book the whole liquid balance.
    function test_fixed_streamerOperatorDrainsLiquidityInOneTx() public {
        vm.skip(true); // TODO: remove once the streamer is bounded per window
        MockUSDC usdc = new MockUSDC();
        OrgRegistry reg = new OrgRegistry(root);
        Treasury t = new Treasury(address(reg), address(usdc), address(1));
        EpochStreamer s = new EpochStreamer(address(t), root);
        t.setStreamer(address(s));
        usdc.mint(address(t), 1_000e6);
        vm.startPrank(root);
        s.setGrant(agentA, 100e6);
        for (uint64 e = 1; e <= 10; e++) {
            try s.runEpoch(e + 1000) {} catch {}
        }
        vm.stopPrank();
        assertLt(t.allowanceBalance(agentA), 1_000e6);
        assertGt(t.liquidBalance(), 0);
    }

    // L/M fix: an agent cannot aim a propose at another node's rate recorder.
    function test_fixed_crossAgentRateRecorderGrief() public {
        vm.skip(true); // TODO: remove once the router protects every bound recorder
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
        vm.expectRevert();
        r.propose(agentA, address(rlB), 0, abi.encodeCall(RateLimitPolicy.record, (agentB)));
        (, uint32 count) = rlB.windows(agentB);
        assertEq(count, 0);
    }
}
