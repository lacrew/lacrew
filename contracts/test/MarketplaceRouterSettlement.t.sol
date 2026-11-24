// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {OrgRegistry} from "../src/OrgRegistry.sol";
import {Treasury} from "../src/Treasury.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {EscalationRouter} from "../src/EscalationRouter.sol";
import {MarketplacePayments} from "../src/MarketplacePayments.sol";
import {SpendCapPolicy} from "../src/policies/SpendCapPolicy.sol";
import {WhitelistPolicy} from "../src/policies/WhitelistPolicy.sol";
import {PolicyStack} from "../src/policies/PolicyStack.sol";
import {IOrgRegistry} from "../src/interfaces/IOrgRegistry.sol";
import {IPolicyModule} from "../src/interfaces/IPolicyModule.sol";

/// @notice Org-funded marketplace purchases through the real router and treasury.
/// @dev Regression for the audit finding where `purchaseFor` measured delivery as
///      `balanceOf - priorOwed`: a shared pool, so agent B could propose value=0 and
///      take the listing agent A had paid for in a call that failed. Settlement is pull
///      based and atomic now, so the stranded payment cannot arise; these tests pin that
///      `purchaseFor` still settles only from the payment of its own call.
contract MarketplaceRouterSettlementTest is Test {
    uint256 internal constant ONE = 1e6;
    uint256 internal constant PRICE = 100 * ONE;
    bytes32 internal constant LISTING = keccak256("agent-payroll-manager");

    address internal root = makeAddr("root");
    address internal agentA = makeAddr("agentA");
    address internal agentB = makeAddr("agentB");
    address internal seller = makeAddr("seller");
    address internal platform = makeAddr("platform");
    address internal governor = makeAddr("governor");

    MockUSDC internal usdc;
    Treasury internal treasury;
    EscalationRouter internal router;
    MarketplacePayments internal market;

    function setUp() public {
        usdc = new MockUSDC();
        OrgRegistry registry = new OrgRegistry(root);
        vm.startPrank(root);
        registry.addNode(agentA, IOrgRegistry.NodeKind.WorkerAgent, root);
        registry.addNode(agentB, IOrgRegistry.NodeKind.WorkerAgent, root);
        vm.stopPrank();

        market = new MarketplacePayments(address(usdc), platform, governor, 2000);

        WhitelistPolicy whitelist = new WhitelistPolicy();
        whitelist.setAllowed(address(market), true);
        IPolicyModule[] memory modules = new IPolicyModule[](2);
        modules[0] = whitelist;
        modules[1] = new SpendCapPolicy(1_000 * ONE);
        router = new EscalationRouter(address(registry), address(new PolicyStack(modules)));
        treasury = new Treasury(address(registry), address(usdc), address(router));
        router.setTreasury(address(treasury));

        vm.prank(governor);
        market.setSettlementRouter(address(router));
        vm.prank(seller);
        market.registerListing(LISTING, PRICE);

        usdc.mint(address(this), 1_000 * ONE);
        usdc.approve(address(treasury), type(uint256).max);
        treasury.deposit(1_000 * ONE);
        treasury.streamAllowance(agentA, 500 * ONE, 1);
    }

    function _buy(address agent, address buyer, uint256 value, uint256 maxPrice) private {
        router.propose(
            agent,
            address(market),
            value,
            abi.encodeCall(MarketplacePayments.purchaseFor, (LISTING, buyer, maxPrice))
        );
    }

    function test_paidPurchaseSettles() public {
        _buy(agentA, agentA, PRICE, PRICE);

        assertTrue(market.hasPurchased(LISTING, agentA));
        assertEq(market.owed(seller), 80 * ONE);
        assertEq(market.unallocatedBalance(), 0);
        (address target, uint256 paid) = router.currentSettlement();
        assertEq(target, address(0), "context cleared after the action");
        assertEq(paid, 0);
    }

    /// The audit PoC: A pays, A's call fails, B proposes value=0 for the same listing.
    /// A failed call now reverts the whole action, so nothing is stranded for B to take.
    function test_zeroValuePurchaseCannotTakeFailedPayment() public {
        // A's maxPrice is below the price, so the purchase call reverts.
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketplacePayments.PriceExceedsMax.selector, PRICE, PRICE - 1
            )
        );
        _buy(agentA, agentA, PRICE, PRICE - 1);
        assertFalse(market.hasPurchased(LISTING, agentA));
        assertEq(usdc.balanceOf(address(market)), 0, "A's payment was not stranded");
        assertEq(usdc.balanceOf(address(router)), 0);

        vm.expectRevert(
            abi.encodeWithSelector(MarketplacePayments.DeliveryMismatch.selector, PRICE, 0)
        );
        _buy(agentB, agentB, 0, type(uint256).max);
        assertFalse(market.hasPurchased(LISTING, agentB), "B got a listing it never paid for");
        assertEq(market.totalOwed(), 0);
    }

    /// A stray transfer is no more spendable than a stranded payment.
    function test_zeroValuePurchaseCannotSpendStrayTransfer() public {
        usdc.mint(address(market), PRICE);
        vm.expectRevert(
            abi.encodeWithSelector(MarketplacePayments.DeliveryMismatch.selector, PRICE, 0)
        );
        _buy(agentB, agentB, 0, type(uint256).max);
        assertFalse(market.hasPurchased(LISTING, agentB));
        assertEq(market.unallocatedBalance(), PRICE, "still recoverable by sweep");
    }

    /// Paying above the price does not settle: the whole action reverts and nothing moves.
    function test_overPaymentRevertsTheAction() public {
        uint256 treasuryBefore = usdc.balanceOf(address(treasury));
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketplacePayments.DeliveryMismatch.selector, PRICE, PRICE + ONE
            )
        );
        _buy(agentA, agentA, PRICE + ONE, PRICE + ONE);
        assertFalse(market.hasPurchased(LISTING, agentA));
        assertEq(market.totalOwed(), 0);
        assertEq(usdc.balanceOf(address(treasury)), treasuryBefore);
    }

    /// Underpaying does not settle either, even with a stray balance to draw on.
    function test_underPaymentCannotBeToppedUpFromStrayFunds() public {
        usdc.mint(address(market), PRICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketplacePayments.DeliveryMismatch.selector, PRICE, PRICE - ONE
            )
        );
        _buy(agentA, agentA, PRICE - ONE, PRICE);
        assertFalse(market.hasPurchased(LISTING, agentA));
        assertEq(market.totalOwed(), 0);
    }
}
