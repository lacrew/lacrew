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
import {CumulativeValuePolicy} from "../src/policies/CumulativeValuePolicy.sol";
import {PolicyStack} from "../src/policies/PolicyStack.sol";
import {IOrgRegistry} from "../src/interfaces/IOrgRegistry.sol";
import {IPolicyModule, Verdict} from "../src/interfaces/IPolicyModule.sol";
import {PullingTarget, IgnoringTarget} from "./utils/SettlementFixtures.sol";

/// @dev Re-enters the router from inside a settlement call.
contract ReentrantTarget {
    EscalationRouter public immutable router;
    address public immutable agent;

    constructor(EscalationRouter router_, address agent_) {
        router = router_;
        agent = agent_;
    }

    function reenter() external {
        router.propose(agent, address(this), 1, "");
    }
}

/// A call with value is settled pull-style: the target is approved for the value, takes what
/// it needs, and whatever it leaves goes back to the agent's allowance.
contract PullSettlementTest is Test {
    uint256 internal constant ONE = 1e6;

    address internal root = makeAddr("root");
    address internal manager = makeAddr("manager");
    address internal worker = makeAddr("worker");
    address internal vendor = makeAddr("vendor");

    MockUSDC internal usdc;
    OrgRegistry internal registry;
    Treasury internal treasury;
    EscalationRouter internal router;
    WhitelistPolicy internal whitelist;
    CumulativeValuePolicy internal budget;
    PullingTarget internal puller;
    IgnoringTarget internal ignorer;

    function setUp() public {
        usdc = new MockUSDC();
        registry = new OrgRegistry(root);
        vm.startPrank(root);
        registry.addNode(manager, IOrgRegistry.NodeKind.ManagerAgent, root);
        registry.addNode(worker, IOrgRegistry.NodeKind.WorkerAgent, manager);
        vm.stopPrank();

        puller = new PullingTarget(usdc);
        ignorer = new IgnoringTarget();

        whitelist = new WhitelistPolicy();
        whitelist.setAllowed(vendor, true);
        whitelist.setAllowed(address(puller), true);
        whitelist.setAllowed(address(ignorer), true);
        SpendCapPolicy spendCap = new SpendCapPolicy(100 * ONE);
        spendCap.setAgentCap(root, type(uint256).max);
        budget = new CumulativeValuePolicy(1_000 * ONE, 0, 1 days);

        IPolicyModule[] memory modules = new IPolicyModule[](3);
        modules[0] = whitelist;
        modules[1] = spendCap;
        modules[2] = budget;
        PolicyStack stack = new PolicyStack(modules);

        router = new EscalationRouter(address(registry), address(stack));
        treasury = new Treasury(address(registry), address(usdc), address(router));
        router.setTreasury(address(treasury));
        router.setValueRecorder(address(budget));
        budget.setRecorder(address(router));

        usdc.mint(address(this), 1_000 * ONE);
        usdc.approve(address(treasury), type(uint256).max);
        treasury.deposit(500 * ONE);
        treasury.streamAllowance(worker, 100 * ONE, 1);
    }

    function _assertNoResidue(address target) private view {
        assertEq(usdc.balanceOf(address(router)), 0, "router holds nothing after settlement");
        assertEq(usdc.allowance(address(router), target), 0, "approval does not outlive the call");
        assertEq(usdc.allowance(address(router), address(treasury)), 0, "refund approval consumed");
    }

    function test_paymentWithoutDataStillPushes() public {
        router.propose(worker, vendor, 40 * ONE, "");
        assertEq(usdc.balanceOf(vendor), 40 * ONE);
        assertEq(treasury.allowanceBalance(worker), 60 * ONE);
        assertEq(budget.spentOf(worker), 40 * ONE);
    }

    function test_pullingTargetTakesTheValue() public {
        (, Verdict verdict) = router.propose(
            worker, address(puller), 40 * ONE, abi.encodeCall(PullingTarget.pull, (40 * ONE))
        );
        assertEq(uint8(verdict), uint8(Verdict.ALLOW));
        assertEq(usdc.balanceOf(address(puller)), 40 * ONE);
        assertEq(treasury.allowanceBalance(worker), 60 * ONE);
        assertEq(treasury.totalReserved(), 60 * ONE);
        assertEq(budget.spentOf(worker), 40 * ONE);
        _assertNoResidue(address(puller));
    }

    function test_partialPullReturnsTheRest() public {
        vm.expectEmit(true, true, false, true, address(router));
        emit EscalationRouter.SettlementReturned(worker, address(puller), 15 * ONE);
        vm.expectEmit(true, true, false, true, address(router));
        emit EscalationRouter.ActionExecuted(worker, address(puller), 25 * ONE, true);
        router.propose(
            worker, address(puller), 40 * ONE, abi.encodeCall(PullingTarget.pull, (25 * ONE))
        );
        assertEq(usdc.balanceOf(address(puller)), 25 * ONE);
        assertEq(treasury.allowanceBalance(worker), 75 * ONE, "unpulled value is allowance again");
        assertEq(treasury.totalReserved(), 75 * ONE);
        assertEq(budget.spentOf(worker), 25 * ONE, "only what the target kept is charged");
        _assertNoResidue(address(puller));
    }

    function test_changeSentBackCountsAsUnpulled() public {
        router.propose(
            worker,
            address(puller),
            40 * ONE,
            abi.encodeCall(PullingTarget.pullWithChange, (40 * ONE, 10 * ONE))
        );
        assertEq(usdc.balanceOf(address(puller)), 30 * ONE);
        assertEq(treasury.allowanceBalance(worker), 70 * ONE);
        assertEq(budget.spentOf(worker), 30 * ONE);
        _assertNoResidue(address(puller));
    }

    /// The case push settlement lost money on: tokens sent to a contract that ignores them.
    function test_ignoringTargetCostsNothing() public {
        (, Verdict verdict) = router.propose(
            worker, address(ignorer), 40 * ONE, abi.encodeCall(IgnoringTarget.ping, ())
        );
        assertEq(uint8(verdict), uint8(Verdict.ALLOW));
        assertEq(ignorer.pings(), 1, "the call itself still ran");
        assertEq(usdc.balanceOf(address(ignorer)), 0);
        assertEq(treasury.allowanceBalance(worker), 100 * ONE);
        assertEq(budget.spentOf(worker), 0);
        _assertNoResidue(address(ignorer));
    }

    /// A failed call reverts the whole action with the target's revert data: nothing is spent.
    function test_failedCallRevertsAndCostsNothing() public {
        vm.expectRevert(bytes("boom"));
        router.propose(worker, address(puller), 40 * ONE, abi.encodeCall(PullingTarget.boom, ()));
        assertEq(treasury.allowanceBalance(worker), 100 * ONE);
        assertEq(budget.spentOf(worker), 0);
        _assertNoResidue(address(puller));
    }

    function test_targetCannotPullBeyondTheValue() public {
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientAllowance(address,uint256,uint256)",
                address(puller),
                0,
                40 * ONE
            )
        );
        router.propose(
            worker, address(puller), 40 * ONE, abi.encodeCall(PullingTarget.pullTwice, (40 * ONE))
        );
        assertEq(usdc.balanceOf(address(puller)), 0, "the over-pull reverted the whole action");
        assertEq(treasury.allowanceBalance(worker), 100 * ONE);
        _assertNoResidue(address(puller));
    }

    /// Tokens someone sent the router directly are never spent or refunded as allowance.
    function test_strayRouterBalanceIsNotSettled() public {
        usdc.mint(address(router), 7 * ONE);
        router.propose(
            worker, address(puller), 40 * ONE, abi.encodeCall(PullingTarget.pull, (20 * ONE))
        );
        assertEq(usdc.balanceOf(address(router)), 7 * ONE);
        assertEq(treasury.allowanceBalance(worker), 80 * ONE);
    }

    function test_escalatedCallSettlesPullStyleOnApproval() public {
        (uint256 intentId, Verdict verdict) = router.propose(
            worker, address(puller), 150 * ONE, abi.encodeCall(PullingTarget.pull, (90 * ONE))
        );
        assertEq(uint8(verdict), uint8(Verdict.ESCALATE));
        treasury.streamAllowance(worker, 100 * ONE, 2);

        vm.prank(manager);
        router.resolve(intentId, true); // manager's cap is 100: climbs to root
        vm.prank(root);
        router.resolve(intentId, true);

        assertEq(usdc.balanceOf(address(puller)), 90 * ONE);
        assertEq(treasury.allowanceBalance(worker), 110 * ONE);
        assertEq(budget.spentOf(worker), 90 * ONE);
        _assertNoResidue(address(puller));
    }

    function test_treasuryTokenIsAProtectedTarget() public {
        whitelist.setAllowed(address(usdc), true);
        vm.expectRevert(
            abi.encodeWithSelector(EscalationRouter.ProtectedTarget.selector, address(usdc))
        );
        router.propose(
            worker, address(usdc), 0, abi.encodeWithSignature("approve(address,uint256)", worker, 1)
        );
    }

    function test_targetCannotReenterTheRouter() public {
        ReentrantTarget reentrant = new ReentrantTarget(router, worker);
        whitelist.setAllowed(address(reentrant), true);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        router.propose(
            worker, address(reentrant), 10 * ONE, abi.encodeCall(ReentrantTarget.reenter, ())
        );
        assertEq(treasury.allowanceBalance(worker), 100 * ONE);
    }

    /// End to end: the marketplace pulls the price and the agent keeps any headroom.
    function test_marketplacePurchasePullsOnlyThePrice() public {
        MarketplacePayments market =
            new MarketplacePayments(address(usdc), makeAddr("platform"), address(this), 2000);
        market.setSettlementRouter(address(router));
        whitelist.setAllowed(address(market), true);
        bytes32 listing = keccak256("listing");
        vm.prank(vendor);
        market.registerListing(listing, 30 * ONE);

        router.propose(
            worker,
            address(market),
            50 * ONE,
            abi.encodeCall(MarketplacePayments.purchaseFor, (listing, worker, 50 * ONE))
        );

        assertTrue(market.hasPurchased(listing, worker));
        assertEq(usdc.balanceOf(address(market)), 30 * ONE);
        assertEq(market.unallocatedBalance(), 0);
        assertEq(treasury.allowanceBalance(worker), 70 * ONE, "headroom above the price returns");
        assertEq(budget.spentOf(worker), 30 * ONE);
        _assertNoResidue(address(market));
    }
}
