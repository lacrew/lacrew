// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Treasury} from "../src/Treasury.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {EpochStreamer} from "../src/EpochStreamer.sol";

contract EpochStreamerTest is Test {
    uint256 internal constant ONE = 1e6;
    uint64 internal constant EPOCH = 1 days;

    MockUSDC internal usdc;
    Treasury internal treasury;
    EpochStreamer internal streamer;
    address internal operator = makeAddr("operator");
    address internal worker = makeAddr("worker");
    address internal manager = makeAddr("manager");

    function setUp() public {
        usdc = new MockUSDC();
        treasury = new Treasury(makeAddr("registry"), address(usdc), makeAddr("router"));
        streamer = new EpochStreamer(address(treasury), operator, uint64(block.timestamp), EPOCH);

        treasury.setStreamer(address(streamer));
        // Governor not set — streamer path alone authorizes after setStreamer.

        usdc.mint(address(this), 10_000 * ONE);
        usdc.approve(address(treasury), type(uint256).max);
        treasury.deposit(5_000 * ONE);

        vm.startPrank(operator);
        streamer.setGrant(worker, 100 * ONE);
        streamer.setGrant(manager, 50 * ONE);
        vm.stopPrank();
    }

    function test_runNextEpochStreamsGrants() public {
        vm.prank(operator);
        uint64 epoch = streamer.runNextEpoch();
        assertEq(epoch, 1);
        assertEq(treasury.allowanceBalance(worker), 100 * ONE);
        assertEq(treasury.allowanceBalance(manager), 50 * ONE);
        assertEq(streamer.currentEpoch(), 1);
        assertTrue(streamer.epochCompleted(1));
    }

    function test_secondEpochAddsAgain() public {
        vm.startPrank(operator);
        streamer.runNextEpoch();
        vm.warp(block.timestamp + EPOCH);
        streamer.runNextEpoch();
        vm.stopPrank();
        assertEq(treasury.allowanceBalance(worker), 200 * ONE);
        assertEq(streamer.currentEpoch(), 2);
    }

    /// Regression (audit PoC): back-to-back epochs must not book N payrolls in one tx.
    function test_rejectsBackToBackEpochs() public {
        vm.startPrank(operator);
        streamer.runNextEpoch();
        vm.expectRevert(
            abi.encodeWithSelector(
                EpochStreamer.EpochNotReady.selector, uint64(2), uint256(streamer.epochStart()) + EPOCH
            )
        );
        streamer.runNextEpoch();
        vm.stopPrank();
        assertEq(treasury.allowanceBalance(worker), 100 * ONE);
        assertEq(treasury.liquidBalance(), 5_000 * ONE - 150 * ONE);
    }

    /// Elapsed epochs back-fill one per call; never ahead of the clock.
    function test_backfillsElapsedEpochsOnly() public {
        vm.warp(block.timestamp + 2 * EPOCH);
        vm.startPrank(operator);
        streamer.runNextEpoch();
        streamer.runNextEpoch();
        streamer.runNextEpoch();
        vm.expectRevert();
        streamer.runNextEpoch();
        vm.stopPrank();
        assertEq(streamer.currentEpoch(), 3);
        assertEq(treasury.allowanceBalance(worker), 300 * ONE);
    }

    function test_epochUnlockTime() public view {
        assertEq(streamer.epochUnlockTime(1), streamer.epochStart());
        assertEq(streamer.epochUnlockTime(5), uint256(streamer.epochStart()) + 4 * EPOCH);
    }

    function test_rejectsZeroDuration() public {
        vm.expectRevert(EpochStreamer.ZeroDuration.selector);
        new EpochStreamer(address(treasury), operator, 0, 0);
    }

    function test_rejectsStranger() public {
        vm.expectRevert(abi.encodeWithSelector(EpochStreamer.NotOperator.selector, address(this)));
        streamer.runNextEpoch();
    }

    function test_governorCanSetGrant() public {
        address gov = makeAddr("gov");
        vm.prank(operator);
        streamer.setGovernor(gov);

        address newbie = makeAddr("newbie");
        vm.prank(gov);
        streamer.setGrant(newbie, 25 * ONE);
        assertEq(streamer.grantAmount(newbie), 25 * ONE);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(abi.encodeWithSelector(EpochStreamer.NotAuthorized.selector, makeAddr("stranger")));
        streamer.setGrant(newbie, 1);
    }

    function test_setGrantsBatchSetsAndClears() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        address[] memory nodes = new address[](3);
        uint256[] memory amounts = new uint256[](3);
        nodes[0] = a;
        amounts[0] = 10 * ONE;
        nodes[1] = b;
        amounts[1] = 20 * ONE;
        nodes[2] = worker; // clear the seeded worker in the same batch
        amounts[2] = 0;

        vm.prank(operator);
        streamer.setGrants(nodes, amounts);

        assertEq(streamer.grantAmount(a), 10 * ONE);
        assertEq(streamer.grantAmount(b), 20 * ONE);
        assertEq(streamer.grantAmount(worker), 0);
        // worker removed, a and b added, manager unchanged.
        assertEq(streamer.recipients().length, 3);
    }

    function test_setGrantsRejectsLengthMismatch() public {
        address[] memory nodes = new address[](2);
        uint256[] memory amounts = new uint256[](1);
        nodes[0] = makeAddr("a");
        nodes[1] = makeAddr("b");
        amounts[0] = 1;
        vm.prank(operator);
        vm.expectRevert(EpochStreamer.LengthMismatch.selector);
        streamer.setGrants(nodes, amounts);
    }

    function test_setGrantsRejectsStranger() public {
        address[] memory nodes = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        nodes[0] = makeAddr("a");
        amounts[0] = 1;
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(EpochStreamer.NotAuthorized.selector, stranger));
        streamer.setGrants(nodes, amounts);
    }

    function test_capsRecipientsAndFullEpochFitsInGas() public {
        uint256 max = streamer.MAX_RECIPIENTS();
        vm.startPrank(operator);
        // worker + manager already registered
        for (uint256 i = 2; i < max; i++) {
            streamer.setGrant(address(uint160(1000 + i)), 1);
        }
        vm.expectRevert(EpochStreamer.TooManyRecipients.selector);
        streamer.setGrant(address(uint160(9999)), 1);
        // Updating an existing recipient is still allowed at the cap.
        streamer.setGrant(worker, 7);
        uint256 g = gasleft();
        streamer.runNextEpoch();
        uint256 used = g - gasleft();
        vm.stopPrank();
        emit log_named_uint("full-epoch gas", used);
        assertLt(used, 30_000_000);
    }
}
