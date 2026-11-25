// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {GovernanceModule} from "../src/GovernanceModule.sol";

contract SnapshotTarget {
    uint256 public value;

    function set(uint256 v) external {
        value = v;
    }
}

/// @notice LC-17: a proposal is decided on the seats, weights and bars that existed when it
///         was created. No seat change made while it is open moves its tally or its bars.
contract GovernanceSeatSnapshotTest is Test {
    address internal root = makeAddr("root");
    address internal partner = makeAddr("partner");
    address internal agent = makeAddr("agent");
    address internal late = makeAddr("late");

    GovernanceModule internal gov;
    SnapshotTarget internal target;

    function setUp() public {
        gov = new GovernanceModule(root, 2);
        target = new SnapshotTarget();
        vm.startPrank(root);
        gov.setLowTierSelector(SnapshotTarget.set.selector, true);
        gov.setVotingPower(agent, 1, GovernanceModule.SeatRole.Agent);
        vm.stopPrank();
    }

    function _propose(GovernanceModule.Tier tier) internal returns (uint256 id) {
        vm.prank(root);
        id = gov.propose(tier, address(target), abi.encodeCall(SnapshotTarget.set, (7)));
    }

    function _etaOf(uint256 id) internal view returns (uint256 eta) {
        (,,,,,,,,, eta,) = gov.proposals(id);
    }

    function _yesOf(uint256 id) internal view returns (uint256 yes, uint256 no, uint256 yesHuman) {
        (,,,,, yes, no, yesHuman,,,) = gov.proposals(id);
    }

    function _stateOf(uint256 id) internal view returns (GovernanceModule.ProposalState state) {
        (,,,,,,,,,, state) = gov.proposals(id);
    }

    /// Pass a High-tier action on the module itself while the root is the only human: its
    /// yes is unanimous, so the fast path executes it in the same block.
    function _passAsSoloRoot(bytes memory data) internal {
        vm.startPrank(root);
        uint256 id = gov.propose(GovernanceModule.Tier.High, address(gov), data);
        gov.vote(id, true);
        vm.stopPrank();
        gov.execute(id);
    }

    function test_snapshotRecordsTheElectorateAndBarsAtCreation() public {
        uint256 id = _propose(GovernanceModule.Tier.Low);
        (uint64 epoch, bool fastPath, uint256 quorum, uint256 total, uint256 human) = gov.proposalSnapshots(id);
        assertEq(epoch, gov.seatEpoch());
        assertTrue(fastPath);
        assertEq(quorum, gov.effectiveQuorumYes());
        assertEq(total, 3);
        assertEq(human, 2);

        uint256 high = _propose(GovernanceModule.Tier.High);
        (,, uint256 highQuorum,,) = gov.proposalSnapshots(high);
        assertEq(highQuorum, gov.effectiveQuorumHumanYes());
    }

    // ——— A seat granted after creation does not vote on it ———

    function test_agentSeatGrantedAfterCreationCannotVote() public {
        uint256 id = _propose(GovernanceModule.Tier.Low);
        vm.prank(root);
        gov.setVotingPower(late, 5, GovernanceModule.SeatRole.Agent);

        vm.prank(late);
        vm.expectRevert(abi.encodeWithSelector(GovernanceModule.NotSeatedAtProposal.selector, id, late));
        gov.vote(id, true);

        // A proposal created after the grant counts it.
        uint256 next = _propose(GovernanceModule.Tier.Low);
        vm.prank(late);
        gov.vote(next, true);
        (uint256 yes,,) = _yesOf(next);
        assertEq(yes, 5);
    }

    function test_humanAdmittedAfterCreationCannotVote() public {
        uint256 id = _propose(GovernanceModule.Tier.High);
        _passAsSoloRoot(abi.encodeCall(GovernanceModule.admitHuman, (partner, 1)));
        assertEq(gov.votingPower(partner), 1);

        vm.prank(partner);
        vm.expectRevert(abi.encodeWithSelector(GovernanceModule.NotSeatedAtProposal.selector, id, partner));
        gov.vote(id, false);
    }

    function test_neverSeatedStillRevertsNoVotingPower() public {
        uint256 id = _propose(GovernanceModule.Tier.Low);
        vm.prank(late);
        vm.expectRevert(abi.encodeWithSelector(GovernanceModule.NoVotingPower.selector, late));
        gov.vote(id, true);
    }

    // ——— A weight changed mid-vote does not move the bar ———

    function test_reweightMidVoteVotesWithTheSnapshotWeight() public {
        uint256 id = _propose(GovernanceModule.Tier.Low);
        vm.prank(root);
        gov.setVotingPower(agent, 9, GovernanceModule.SeatRole.Agent);

        vm.prank(agent);
        gov.vote(id, false);
        (, uint256 no,) = _yesOf(id);
        assertEq(no, 1, "snapshot weight, not the weight granted after creation");

        // The root's 2 beats the agent's snapshot 1, so the proposal carries.
        vm.prank(root);
        gov.vote(id, true);
        vm.warp(_etaOf(id));
        gov.execute(id);
        assertEq(target.value(), 7);
    }

    function test_quorumRaisedMidVoteDoesNotMoveTheBar() public {
        uint256 id = _propose(GovernanceModule.Tier.Low);
        vm.prank(root);
        gov.vote(id, true);
        // More seat weight plus a higher quorum would demand more than the root's 2 yes.
        vm.startPrank(root);
        gov.setVotingPower(late, 10, GovernanceModule.SeatRole.Agent);
        gov.setQuorumYes(10);
        vm.stopPrank();
        assertEq(gov.effectiveQuorumYes(), 10);

        vm.warp(_etaOf(id));
        gov.execute(id);
        assertEq(target.value(), 7);
    }

    function test_humanAdmittedMidVoteDoesNotRaiseTheUnanimityBar() public {
        uint256 id = _propose(GovernanceModule.Tier.High);
        vm.prank(root);
        gov.vote(id, true);
        _passAsSoloRoot(abi.encodeCall(GovernanceModule.admitHuman, (partner, 1)));
        assertEq(gov.totalHumanVotingPower(), 3);

        // Every human of the proposal's electorate (the root alone) voted yes: the fast
        // path still fires although the live human weight has grown.
        assertLt(block.timestamp, _etaOf(id));
        gov.execute(id);
        assertEq(target.value(), 7);
    }

    function test_humanRemovedMidVoteDoesNotLowerTheUnanimityBar() public {
        _passAsSoloRoot(abi.encodeCall(GovernanceModule.admitHuman, (partner, 1)));
        uint256 id = _propose(GovernanceModule.Tier.High);
        vm.prank(root);
        gov.vote(id, true);

        // Remove the partner through governance (both humans back it, so it fast-paths).
        vm.prank(root);
        uint256 removal =
            gov.propose(GovernanceModule.Tier.High, address(gov), abi.encodeCall(GovernanceModule.removeHuman, (partner)));
        vm.prank(root);
        gov.vote(removal, true);
        vm.prank(partner);
        gov.vote(removal, true);
        gov.execute(removal);
        assertEq(gov.totalHumanVotingPower(), 2);

        // Live, the root's 2 would now be every human's weight; the snapshot bar is 3.
        uint256 eta = _etaOf(id);
        vm.expectRevert(abi.encodeWithSelector(GovernanceModule.TimelockNotElapsed.selector, id, eta));
        gov.execute(id);
    }

    function test_fastPathSwitchedOffMidVoteKeepsTheSnapshotSetting() public {
        uint256 id = _propose(GovernanceModule.Tier.High);
        vm.startPrank(root);
        gov.vote(id, true);
        gov.setUnanimityFastPath(false);
        vm.stopPrank();
        gov.execute(id);
        assertEq(target.value(), 7);

        uint256 next = _propose(GovernanceModule.Tier.High);
        vm.prank(root);
        gov.vote(next, true);
        uint256 eta = _etaOf(next);
        vm.expectRevert(abi.encodeWithSelector(GovernanceModule.TimelockNotElapsed.selector, next, eta));
        gov.execute(next);
    }

    // ——— A seat revoked after creation keeps its snapshot weight ———

    function test_revokedSeatVoteCastBeforeRevocationStands() public {
        uint256 id = _propose(GovernanceModule.Tier.Low);
        vm.prank(agent);
        gov.vote(id, true);
        vm.prank(root);
        gov.setVotingPower(agent, 0, GovernanceModule.SeatRole.None);

        (uint256 yes,,) = _yesOf(id);
        assertEq(yes, 1);
        vm.prank(root);
        gov.vote(id, true);
        vm.warp(_etaOf(id));
        gov.execute(id);
        assertEq(target.value(), 7);
    }

    function test_revokedSeatStillVotesWithItsSnapshotWeight() public {
        uint256 id = _propose(GovernanceModule.Tier.Low);
        vm.prank(root);
        gov.setVotingPower(agent, 0, GovernanceModule.SeatRole.None);

        // Revoking a seat cannot silence it on a proposal it was seated for.
        vm.prank(agent);
        gov.vote(id, false);
        (, uint256 no,) = _yesOf(id);
        assertEq(no, 1);

        // But it cannot vote on a proposal made after the revocation.
        uint256 next = _propose(GovernanceModule.Tier.Low);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(GovernanceModule.NoVotingPower.selector, agent));
        gov.vote(next, false);
    }

    function test_revokedHumanVotesAsHumanOnHighTier() public {
        _passAsSoloRoot(abi.encodeCall(GovernanceModule.admitHuman, (partner, 1)));
        uint256 id = _propose(GovernanceModule.Tier.High);

        vm.prank(root);
        uint256 removal =
            gov.propose(GovernanceModule.Tier.High, address(gov), abi.encodeCall(GovernanceModule.removeHuman, (partner)));
        vm.prank(root);
        gov.vote(removal, true);
        vm.prank(partner);
        gov.vote(removal, true);
        gov.execute(removal);

        vm.prank(partner);
        gov.vote(id, false);
        assertEq(gov.noHumanVotes(id), 1, "counted with its snapshot Human role");
    }

    // ——— rotateRoot ———

    function test_rotateRootKeepsOpenProposalsOnTheirSnapshot() public {
        uint256 id = _propose(GovernanceModule.Tier.High);
        address fresh = makeAddr("fresh-root");
        _passAsSoloRoot(abi.encodeCall(GovernanceModule.rotateRoot, (fresh, new address[](0))));
        assertEq(gov.humanRoot(), fresh);
        assertEq(gov.votingPower(root), 0);
        assertEq(gov.votingPower(fresh), 2);

        // The new key's seat was created by the rotation, after the proposal.
        vm.prank(fresh);
        vm.expectRevert(abi.encodeWithSelector(GovernanceModule.NotSeatedAtProposal.selector, id, fresh));
        gov.vote(id, true);

        // The veto is live, not snapshotted: the new root holds it, the retired key does not.
        vm.prank(root);
        vm.expectRevert(abi.encodeWithSelector(GovernanceModule.NotHumanSeat.selector, root));
        gov.veto(id);
        vm.prank(fresh);
        gov.veto(id);
        assertEq(uint8(_stateOf(id)), uint8(GovernanceModule.ProposalState.Vetoed));

        // New proposals are decided by the new key.
        vm.prank(fresh);
        uint256 next = gov.propose(GovernanceModule.Tier.High, address(target), abi.encodeCall(SnapshotTarget.set, (9)));
        vm.prank(fresh);
        gov.vote(next, true);
        gov.execute(next);
        assertEq(target.value(), 9);
    }

    // ——— seatAt ———

    function test_seatAtReadsEachCheckpoint() public {
        uint256 e0 = gov.seatEpoch();
        vm.startPrank(root);
        gov.setVotingPower(late, 3, GovernanceModule.SeatRole.Agent);
        uint256 e1 = gov.seatEpoch();
        gov.setVotingPower(agent, 4, GovernanceModule.SeatRole.Agent);
        gov.setVotingPower(late, 5, GovernanceModule.SeatRole.Agent);
        uint256 e2 = gov.seatEpoch();
        gov.setVotingPower(late, 0, GovernanceModule.SeatRole.None);
        uint256 e3 = gov.seatEpoch();
        vm.stopPrank();

        (uint256 power, GovernanceModule.SeatRole role) = gov.seatAt(late, e0);
        assertEq(power, 0);
        assertEq(uint8(role), uint8(GovernanceModule.SeatRole.None));
        (power, role) = gov.seatAt(late, e1);
        assertEq(power, 3);
        assertEq(uint8(role), uint8(GovernanceModule.SeatRole.Agent));
        (power,) = gov.seatAt(late, e1 + 1);
        assertEq(power, 3);
        (power,) = gov.seatAt(late, e2);
        assertEq(power, 5);
        (power, role) = gov.seatAt(late, e3);
        assertEq(power, 0);
        assertEq(uint8(role), uint8(GovernanceModule.SeatRole.None));
        (power,) = gov.seatAt(root, 0);
        assertEq(power, 0);
        (power,) = gov.seatAt(root, 1);
        assertEq(power, 2);
    }

    function testFuzz_seatAtMatchesTheWeightAtEachEpoch(uint8[8] calldata weights) public {
        uint256[] memory epochs = new uint256[](weights.length);
        vm.startPrank(root);
        for (uint256 i = 0; i < weights.length; i++) {
            uint256 w = weights[i];
            gov.setVotingPower(late, w, w == 0 ? GovernanceModule.SeatRole.None : GovernanceModule.SeatRole.Agent);
            // Interleave another seat's change so the voter's epochs are not contiguous.
            gov.setVotingPower(agent, i + 1, GovernanceModule.SeatRole.Agent);
            epochs[i] = gov.seatEpoch() - 1;
        }
        vm.stopPrank();
        for (uint256 i = 0; i < weights.length; i++) {
            (uint256 power,) = gov.seatAt(late, epochs[i]);
            assertEq(power, weights[i]);
            (power,) = gov.seatAt(late, epochs[i] + 1);
            assertEq(power, weights[i]);
        }
    }
}
