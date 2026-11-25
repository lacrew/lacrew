// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {OrgRegistry} from "../src/OrgRegistry.sol";
import {Treasury} from "../src/Treasury.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {EscalationRouter} from "../src/EscalationRouter.sol";
import {MarketplacePayments} from "../src/MarketplacePayments.sol";
import {SpendCapPolicy} from "../src/policies/SpendCapPolicy.sol";
import {IOrgRegistry} from "../src/interfaces/IOrgRegistry.sol";
import {Verdict} from "../src/interfaces/IPolicyModule.sol";

/// @dev Reverts with no revert data.
contract SilentReverter {
    fallback() external payable {
        revert();
    }
}

/// Regression for the audit finding "EscalationRouter settles payment even when the
/// target call fails": an org purchase through `MarketplacePayments.purchaseFor` that
/// reverts must not deliver funds, spend allowance, or resolve the intent.
contract AtomicActionTest is Test {
    uint256 internal constant ONE = 1e6;
    bytes32 internal constant CATALOG = keccak256("agent-payroll-manager");
    /// @dev Derived from (seller, CATALOG); set in setUp.
    bytes32 internal LISTING;

    address internal root = makeAddr("root");
    address internal manager = makeAddr("manager");
    address internal worker = makeAddr("worker");
    address internal seller = makeAddr("seller");
    address internal platform = makeAddr("platform");
    address internal governor = makeAddr("governor");

    MockUSDC internal usdc;
    OrgRegistry internal registry;
    Treasury internal treasury;
    EscalationRouter internal router;
    MarketplacePayments internal market;

    function setUp() public {
        usdc = new MockUSDC();
        registry = new OrgRegistry(root);
        vm.startPrank(root);
        registry.addNode(manager, IOrgRegistry.NodeKind.ManagerAgent, root);
        registry.addNode(worker, IOrgRegistry.NodeKind.WorkerAgent, manager);
        vm.stopPrank();

        // Worker may spend up to 150 alone; manager up to 1000.
        SpendCapPolicy spendCap = new SpendCapPolicy(150 * ONE);
        spendCap.setAgentCap(manager, 1_000 * ONE);
        spendCap.setAgentCap(root, type(uint256).max);

        router = new EscalationRouter(address(registry), address(spendCap));
        treasury = new Treasury(address(registry), address(usdc), address(router));
        router.setTreasury(address(treasury));

        usdc.mint(address(this), 1_000 * ONE);
        usdc.approve(address(treasury), type(uint256).max);
        treasury.deposit(1_000 * ONE);
        treasury.streamAllowance(worker, 500 * ONE, 1);

        market = new MarketplacePayments(address(usdc), platform, governor, 2000);

        LISTING = market.listingIdFor(seller, CATALOG);
        vm.prank(governor);
        market.setSettlementRouter(address(router));
        vm.prank(seller);
        market.registerListing(CATALOG, 100 * ONE);
    }

    function _buy(uint256 maxPrice) internal view returns (bytes memory) {
        return abi.encodeCall(MarketplacePayments.purchaseFor, (LISTING, worker, maxPrice));
    }

    function test_allowedPurchaseSettlesWithReceipt() public {
        (, Verdict verdict) = router.propose(worker, address(market), 100 * ONE, _buy(100 * ONE));
        assertEq(uint8(verdict), uint8(Verdict.ALLOW));
        assertTrue(market.hasPurchased(LISTING, worker));
        assertEq(usdc.balanceOf(address(market)), 100 * ONE);
        assertEq(treasury.allowanceBalance(worker), 400 * ONE);
    }

    /// The PoC: price moved past maxPrice. The whole propose reverts with the
    /// target's error, so no USDC is stranded at the market.
    function test_allowedPurchaseRevertsWhenCallFails() public {
        vm.prank(seller);
        market.registerListing(CATALOG, 120 * ONE);

        vm.expectRevert(abi.encodeWithSelector(MarketplacePayments.PriceExceedsMax.selector, 120 * ONE, 100 * ONE));
        router.propose(worker, address(market), 100 * ONE, _buy(100 * ONE));

        assertEq(usdc.balanceOf(address(market)), 0, "no funds stranded");
        assertEq(market.unallocatedBalance(), 0);
        assertEq(treasury.allowanceBalance(worker), 500 * ONE, "allowance untouched");
        assertFalse(market.hasPurchased(LISTING, worker));
    }

    function test_alreadyPurchasedRevertsWithoutSecondPayment() public {
        router.propose(worker, address(market), 100 * ONE, _buy(100 * ONE));

        vm.expectRevert(abi.encodeWithSelector(MarketplacePayments.AlreadyPurchased.selector, LISTING, worker));
        router.propose(worker, address(market), 100 * ONE, _buy(100 * ONE));

        assertEq(usdc.balanceOf(address(market)), 100 * ONE, "only the first purchase paid");
        assertEq(treasury.allowanceBalance(worker), 400 * ONE);
    }

    /// Escalated path: approving an intent whose call fails reverts, and the intent
    /// stays pending so it can be retried once the call would succeed, or rejected.
    function test_resolveRevertsAndKeepsIntentPendingWhenCallFails() public {
        vm.prank(seller);
        market.registerListing(CATALOG, 200 * ONE);
        (uint256 intentId, Verdict verdict) = router.propose(worker, address(market), 200 * ONE, _buy(200 * ONE));
        assertEq(uint8(verdict), uint8(Verdict.ESCALATE));

        vm.prank(seller);
        market.delist(LISTING);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(MarketplacePayments.ListingInactive.selector, LISTING));
        router.resolve(intentId, true);

        (,,,,, bool resolved, bool approved) = router.intents(intentId);
        assertFalse(resolved, "intent still pending");
        assertFalse(approved);
        assertEq(usdc.balanceOf(address(market)), 0);
        assertEq(treasury.allowanceBalance(worker), 500 * ONE);

        // Relisted, the same approval now settles payment and receipt together.
        vm.prank(seller);
        market.registerListing(CATALOG, 200 * ONE);
        vm.prank(manager);
        router.resolve(intentId, true);
        (,,,,, resolved, approved) = router.intents(intentId);
        assertTrue(resolved && approved);
        assertTrue(market.hasPurchased(LISTING, worker));
        assertEq(usdc.balanceOf(address(market)), 200 * ONE);
    }

    function test_failedIntentCanStillBeRejected() public {
        vm.prank(seller);
        market.registerListing(CATALOG, 200 * ONE);
        (uint256 intentId,) = router.propose(worker, address(market), 200 * ONE, _buy(200 * ONE));
        vm.prank(seller);
        market.delist(LISTING);

        vm.prank(manager);
        router.resolve(intentId, false);
        (,,,,, bool resolved, bool approved) = router.intents(intentId);
        assertTrue(resolved);
        assertFalse(approved);
        assertEq(treasury.allowanceBalance(worker), 500 * ONE);
    }

    function test_silentRevertUsesActionCallFailed() public {
        address target = address(new SilentReverter());
        vm.expectRevert(abi.encodeWithSelector(EscalationRouter.ActionCallFailed.selector, target));
        router.propose(worker, target, 10 * ONE, hex"1234");
        assertEq(usdc.balanceOf(target), 0);
        assertEq(treasury.allowanceBalance(worker), 500 * ONE);
    }

    function testFuzz_failedCallNeverMovesFunds(uint256 value, uint256 newPrice) public {
        value = bound(value, 1, 150 * ONE);
        newPrice = bound(newPrice, value + 1, 10_000 * ONE);
        vm.prank(seller);
        market.registerListing(CATALOG, newPrice);

        vm.expectRevert();
        router.propose(worker, address(market), value, _buy(value));
        assertEq(usdc.balanceOf(address(market)), 0);
        assertEq(treasury.allowanceBalance(worker), 500 * ONE);
    }
}
