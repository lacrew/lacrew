// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IOrgRegistry} from "../src/interfaces/IOrgRegistry.sol";
import {Treasury} from "../src/Treasury.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {FeeOnTransferToken} from "./utils/SettlementFixtures.sol";

contract TreasuryTest is Test {
    MockUSDC internal usdc;
    Treasury internal treasury;
    address internal registry = makeAddr("registry");
    address internal router = makeAddr("router");
    address internal worker = makeAddr("worker");
    address internal recipient = makeAddr("recipient");

    uint256 internal constant ONE = 1e6;

    function setUp() public {
        usdc = new MockUSDC();
        vm.mockCall(registry, abi.encodeWithSelector(IOrgRegistry.generationOf.selector), abi.encode(uint64(0)));
        treasury = new Treasury(registry, address(usdc), router);
        usdc.mint(address(this), 1_000_000 * ONE);
        usdc.approve(address(treasury), type(uint256).max);
    }

    function test_depositAndStream() public {
        treasury.deposit(1000 * ONE);
        assertEq(treasury.liquidBalance(), 1000 * ONE);

        treasury.streamAllowance(worker, 100 * ONE, 1);
        assertEq(treasury.allowanceBalance(worker), 100 * ONE);
        assertEq(treasury.liquidBalance(), 900 * ONE);
        assertEq(treasury.totalReserved(), 100 * ONE);
    }

    function test_spendByRouter() public {
        treasury.deposit(500 * ONE);
        treasury.streamAllowance(worker, 50 * ONE, 1);

        vm.prank(router);
        treasury.spendAllowance(worker, 20 * ONE, recipient);

        assertEq(usdc.balanceOf(recipient), 20 * ONE);
        assertEq(treasury.allowanceBalance(worker), 30 * ONE);
        assertEq(treasury.totalReserved(), 30 * ONE);
    }

    function test_spendToRouterOverload() public {
        treasury.deposit(100 * ONE);
        treasury.streamAllowance(worker, 40 * ONE, 1);

        vm.prank(router);
        treasury.spendAllowance(worker, 10 * ONE);

        assertEq(usdc.balanceOf(router), 10 * ONE);
    }

    function test_revertsInsufficientTreasury() public {
        treasury.deposit(10 * ONE);
        vm.expectRevert(
            abi.encodeWithSelector(Treasury.InsufficientTreasury.selector, 20 * ONE, 10 * ONE)
        );
        treasury.streamAllowance(worker, 20 * ONE, 1);
    }

    function test_revertsInsufficientAllowance() public {
        treasury.deposit(100 * ONE);
        treasury.streamAllowance(worker, 10 * ONE, 1);
        vm.prank(router);
        vm.expectRevert(
            abi.encodeWithSelector(Treasury.InsufficientAllowance.selector, worker, 11 * ONE, 10 * ONE)
        );
        treasury.spendAllowance(worker, 11 * ONE, recipient);
    }

    function test_revertsNotSpender() public {
        treasury.deposit(100 * ONE);
        treasury.streamAllowance(worker, 10 * ONE, 1);
        vm.expectRevert(abi.encodeWithSelector(Treasury.NotSpender.selector, address(this)));
        treasury.spendAllowance(worker, 1 * ONE, recipient);
    }

    /// Allowance booked to the zero address is reserved for a node that can never
    /// propose, so it would leave the liquid balance for good.
    function test_streamAllowanceRejectsZeroNode() public {
        treasury.deposit(100 * ONE);
        vm.expectRevert(Treasury.ZeroAddress.selector);
        treasury.streamAllowance(address(0), 10 * ONE, 1);

        assertEq(treasury.totalReserved(), 0);
        assertEq(treasury.liquidBalance(), 100 * ONE);
    }

    /// Binding a streamer hands it the streaming role outright: the deployer's own
    /// bootstrap `streamAllowance` ends there, and comes back only by unbinding.
    function test_bindingAStreamerEndsTheDeployersDirectStreaming() public {
        address streamer = makeAddr("streamer");
        treasury.deposit(100 * ONE);
        treasury.streamAllowance(worker, 10 * ONE, 1);

        treasury.setStreamer(streamer);
        vm.expectRevert(abi.encodeWithSelector(Treasury.NotAuthorized.selector, address(this)));
        treasury.streamAllowance(worker, 10 * ONE, 2);

        vm.prank(streamer);
        treasury.streamAllowance(worker, 10 * ONE, 2);

        treasury.setStreamer(address(0));
        treasury.streamAllowance(worker, 10 * ONE, 3);
        assertEq(treasury.allowanceBalance(worker), 30 * ONE);
    }

    // ——— Pull-settlement refunds ———

    function test_refundRestoresAllowanceFromReturnedTokens() public {
        treasury.deposit(100 * ONE);
        treasury.streamAllowance(worker, 40 * ONE, 1);
        vm.prank(router);
        treasury.spendAllowance(worker, 40 * ONE);

        vm.startPrank(router);
        usdc.approve(address(treasury), 15 * ONE);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit Treasury.AllowanceRefunded(worker, 15 * ONE);
        treasury.refundAllowance(worker, 15 * ONE);
        vm.stopPrank();

        assertEq(treasury.allowanceBalance(worker), 15 * ONE);
        assertEq(treasury.totalReserved(), 15 * ONE);
        assertEq(usdc.balanceOf(router), 25 * ONE);
        assertEq(treasury.liquidBalance(), 60 * ONE, "a refund never grows liquid funds");
    }

    function test_refundRevertsForNonSpender() public {
        vm.prank(worker);
        vm.expectRevert(abi.encodeWithSelector(Treasury.NotSpender.selector, worker));
        treasury.refundAllowance(worker, 1);
    }

    /// The tokens must actually come back: a spender cannot mint allowance by asking.
    function test_refundRevertsWithoutTheTokens() public {
        vm.prank(router);
        vm.expectRevert();
        treasury.refundAllowance(worker, 10 * ONE);
        assertEq(treasury.allowanceBalance(worker), 0);
    }

    // ——— Non-vanilla tokens ———

    function test_feeOnTransferDepositReverts() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        Treasury t = new Treasury(registry, address(fot), router);
        fot.mint(address(this), 100 * ONE);
        fot.approve(address(t), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(Treasury.TransferAmountMismatch.selector, 100 * ONE, 99 * ONE)
        );
        t.deposit(100 * ONE);
    }

    /// A fee token that reached the treasury anyway (sent directly) still cannot be spent
    /// short: the recipient must receive exactly what the allowance was debited.
    function test_feeOnTransferSpendReverts() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        Treasury t = new Treasury(registry, address(fot), router);
        fot.mint(address(t), 100 * ONE);
        t.streamAllowance(worker, 50 * ONE, 1);
        vm.prank(router);
        vm.expectRevert(
            abi.encodeWithSelector(Treasury.TransferAmountMismatch.selector, 20 * ONE, 19.8e6)
        );
        t.spendAllowance(worker, 20 * ONE, recipient);
    }

    function test_shortfallReportsUnbackedReservations() public {
        treasury.deposit(100 * ONE);
        treasury.streamAllowance(worker, 80 * ONE, 1);
        assertEq(treasury.shortfall(), 0);

        // A negative rebase or a seizure: balance drops without a transfer out.
        vm.prank(address(treasury));
        usdc.transfer(address(0xdead), 50 * ONE);
        assertEq(treasury.shortfall(), 30 * ONE);
        assertEq(treasury.liquidBalance(), 0);
    }

    // ——— Governed revoke and withdraw ———

    function test_revokeAllowanceReturnsFundsToLiquid() public {
        treasury.deposit(100 * ONE);
        treasury.streamAllowance(worker, 40 * ONE, 1);
        treasury.revokeAllowance(worker, 25 * ONE);
        assertEq(treasury.allowanceBalance(worker), 15 * ONE);
        assertEq(treasury.totalReserved(), 15 * ONE);
        assertEq(treasury.liquidBalance(), 85 * ONE);
    }

    function test_revokeAllowanceBoundedAndAuthorized() public {
        treasury.deposit(100 * ONE);
        treasury.streamAllowance(worker, 10 * ONE, 1);
        vm.expectRevert(
            abi.encodeWithSelector(Treasury.InsufficientAllowance.selector, worker, 11 * ONE, 10 * ONE)
        );
        treasury.revokeAllowance(worker, 11 * ONE);
        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSelector(Treasury.NotAuthorized.selector, recipient));
        treasury.revokeAllowance(worker, 1);
    }

    function test_withdrawBoundedByLiquid() public {
        treasury.deposit(100 * ONE);
        treasury.streamAllowance(worker, 40 * ONE, 1);
        treasury.withdraw(recipient, 60 * ONE);
        assertEq(usdc.balanceOf(recipient), 60 * ONE);
        assertEq(treasury.allowanceBalance(worker), 40 * ONE);
        vm.expectRevert(abi.encodeWithSelector(Treasury.InsufficientTreasury.selector, 1, 0));
        treasury.withdraw(recipient, 1);
    }

    function test_withdrawGuards() public {
        treasury.deposit(10 * ONE);
        vm.expectRevert(Treasury.ZeroAddress.selector);
        treasury.withdraw(address(0), 1);
        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSelector(Treasury.NotAuthorized.selector, recipient));
        treasury.withdraw(recipient, 1);
    }
}
