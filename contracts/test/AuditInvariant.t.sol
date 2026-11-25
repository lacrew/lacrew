// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {GovernanceModule} from "../src/GovernanceModule.sol";
import {OrgRegistry} from "../src/OrgRegistry.sol";
import {IOrgRegistry} from "../src/interfaces/IOrgRegistry.sol";
import {Treasury} from "../src/Treasury.sol";
import {EscalationRouter} from "../src/EscalationRouter.sol";
import {MarketplacePayments} from "../src/MarketplacePayments.sol";
import {WhitelistPolicy} from "../src/policies/WhitelistPolicy.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {Verdict} from "../src/interfaces/IPolicyModule.sol";

/// @dev Invariants from the audit follow-up, kept as regression guards. Each states the
///      FIXED behaviour as main implements it, and names the finding it covers.

// ——— Governance: no Low-tier proposal executes early or while outvoted ———
// Covers: low-tier governance gate (#628) — allow-list, `lowTierDelay`, `Outvoted`.

contract GovSink {
    uint256 public calls;

    function noop() external {
        calls++;
    }
}

contract GovTierHandler is Test {
    GovernanceModule public immutable gov;
    GovSink public immutable sink;
    address[] internal voters;
    uint256[] internal ids;
    /// @notice Executions that happened before the proposal's low-tier delay elapsed.
    uint256 public earlyExecutions;
    /// @notice Executions whose yes-weight did not exceed their no-weight.
    uint256 public outvotedExecutions;
    /// @notice Executions of a proposal that had not reached the yes quorum.
    uint256 public belowQuorumExecutions;

    constructor(GovernanceModule gov_, GovSink sink_, address[] memory voters_) {
        gov = gov_;
        sink = sink_;
        voters = voters_;
    }

    function propose(uint256 voterSeed) external {
        // Allow-listed, parameter-neutral Low-tier action on a benign target.
        vm.prank(voters[voterSeed % voters.length]);
        ids.push(gov.propose(GovernanceModule.Tier.Low, address(sink), abi.encodeCall(GovSink.noop, ())));
    }

    function vote(uint256 idSeed, uint256 voterSeed, bool support) external {
        if (ids.length == 0) return;
        vm.prank(voters[voterSeed % voters.length]);
        try gov.vote(ids[idSeed % ids.length], support) {} catch {}
    }

    function execute(uint256 idSeed) external {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        (,,,,, uint256 yes, uint256 no,, uint256 deadline, uint256 eta, GovernanceModule.ProposalState state) =
            gov.proposals(id);
        deadline;
        uint256 callsBefore = sink.calls();
        try gov.execute(id) {
            // Only a real execution (the action ran) counts; a Defeated close does not.
            if (sink.calls() > callsBefore && state == GovernanceModule.ProposalState.Active) {
                if (block.timestamp < eta) earlyExecutions++;
                if (yes <= no) outvotedExecutions++;
                if (yes < gov.effectiveQuorumYes()) belowQuorumExecutions++;
            }
        } catch {}
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 4 days));
    }
}

contract GovernanceTierInvariant is StdInvariant, Test {
    GovTierHandler handler;

    function setUp() public {
        address root = makeAddr("root");
        GovernanceModule gov = new GovernanceModule(root, 2);
        GovSink sink = new GovSink();
        address a = makeAddr("agentA");
        address b = makeAddr("agentB");
        vm.startPrank(root);
        gov.setVotingPower(a, 1, GovernanceModule.SeatRole.Agent);
        gov.setVotingPower(b, 1, GovernanceModule.SeatRole.Agent);
        gov.setLowTierSelector(GovSink.noop.selector, true);
        // Unanimous human approval legitimately skips the delay; switch it off so any
        // early execution is a violation.
        gov.setUnanimityFastPath(false);
        vm.stopPrank();
        address[] memory voters = new address[](3);
        voters[0] = root;
        voters[1] = a;
        voters[2] = b;
        handler = new GovTierHandler(gov, sink, voters);
        targetContract(address(handler));
    }

    function invariant_noLowTierExecutesBeforeDelay() public view {
        assertEq(handler.earlyExecutions(), 0, "low-tier proposal executed before its delay");
    }

    function invariant_noLowTierExecutesWhileOutvoted() public view {
        assertEq(handler.outvotedExecutions(), 0, "low-tier proposal executed while outvoted");
        assertEq(handler.belowQuorumExecutions(), 0, "low-tier proposal executed below quorum");
    }
}

// ——— Treasury accounting + router value moves ———

/// @dev Target whose call can be made to fail; counts successful calls.
contract FlakySink {
    uint256 public okCalls;

    function work(bool fail) external {
        require(!fail, "sink failed");
        okCalls++;
    }
}

contract RouterTreasuryHandler is Test {
    EscalationRouter public immutable router;
    Treasury public immutable treasury;
    FlakySink public immutable sink;
    address[] public agents;
    /// @notice Router proposes that moved value (allowance spent) with calldata.
    uint256 public valueMovingCalls;
    /// @notice Failed proposes that changed an allowance or left tokens at the sink or router.
    uint256 public failedCallLeaks;

    constructor(EscalationRouter r, Treasury t, FlakySink s, address[] memory agents_) {
        router = r;
        treasury = t;
        sink = s;
        agents = agents_;
    }

    function fund(uint256 agentSeed, uint256 amount) external {
        amount = bound(amount, 1, 50e6);
        address agent = agents[agentSeed % agents.length];
        if (treasury.liquidBalance() < amount) return;
        treasury.streamAllowance(agent, amount, uint64(block.timestamp));
    }

    function propose(uint256 agentSeed, uint256 value, bool fail) external {
        address agent = agents[agentSeed % agents.length];
        value = bound(value, 1, 50e6);
        uint256 allowanceBefore = treasury.allowanceBalance(agent);
        uint256 reservedBefore = treasury.totalReserved();
        vm.prank(agent);
        try router.propose(agent, address(sink), value, abi.encodeCall(FlakySink.work, (fail))) returns (
            uint256 intentId, Verdict
        ) {
            if (intentId == 0) valueMovingCalls++;
        } catch {
            // A failed target call reverts the whole action: nothing is spent or stranded.
            if (
                treasury.allowanceBalance(agent) != allowanceBefore || treasury.totalReserved() != reservedBefore
                    || treasury.token().balanceOf(address(sink)) != 0
                    || treasury.token().balanceOf(address(router)) != 0
            ) failedCallLeaks++;
        }
    }
}

contract TreasuryRouterInvariant is StdInvariant, Test {
    MockUSDC usdc;
    Treasury treasury;
    FlakySink sink;
    RouterTreasuryHandler handler;
    address[] agents;

    function setUp() public {
        address root = makeAddr("root");
        usdc = new MockUSDC();
        OrgRegistry reg = new OrgRegistry(root);
        agents.push(makeAddr("agentA"));
        agents.push(makeAddr("agentB"));
        vm.startPrank(root);
        reg.addNode(agents[0], IOrgRegistry.NodeKind.WorkerAgent, root);
        reg.addNode(agents[1], IOrgRegistry.NodeKind.WorkerAgent, root);
        vm.stopPrank();
        WhitelistPolicy wl = new WhitelistPolicy();
        EscalationRouter router = new EscalationRouter(address(reg), address(wl));
        treasury = new Treasury(address(reg), address(usdc), address(router));
        router.setTreasury(address(treasury));
        sink = new FlakySink();
        wl.setAllowed(address(sink), true);
        usdc.mint(address(treasury), 1_000e6);
        handler = new RouterTreasuryHandler(router, treasury, sink, agents);
        // The handler acts as the treasury's bootstrap governor to stream allowances.
        treasury.setGovernor(address(handler));
        targetContract(address(handler));
    }

    /// @notice totalReserved == sum(allowanceBalance).
    function invariant_totalReservedEqualsSumAllowances() public view {
        uint256 sum;
        for (uint256 i; i < agents.length; i++) {
            sum += treasury.allowanceBalance(agents[i]);
        }
        assertEq(treasury.totalReserved(), sum);
        assertGe(usdc.balanceOf(address(treasury)), treasury.totalReserved());
    }

    /// @notice Covers: atomic settlement (#640). A router propose that moves value always
    ///         makes the target call succeed; a failed call reverts the action instead.
    function invariant_valueMovingProposeAlwaysSucceedsOnTarget() public view {
        assertEq(sink.okCalls(), handler.valueMovingCalls(), "value moved but target call failed");
    }

    /// @notice Covers: atomic settlement (#640). A failed call strands no funds at the
    ///         target or the router and leaves the agent's allowance untouched.
    function invariant_failedCallStrandsNothing() public view {
        assertEq(handler.failedCallLeaks(), 0, "failed call changed allowance or stranded funds");
        assertEq(usdc.balanceOf(address(sink)), 0);
    }
}

// ——— Marketplace: purchased receipts <= delivered funds ———

contract MarketHandler is Test {
    MarketplacePayments public immutable market;
    MockUSDC public immutable usdc;
    EscalationRouter public immutable router;
    Treasury public immutable treasury;
    address[] public agents;
    bytes32[] public listingIds;
    /// @notice Sum of list prices over every receipt written.
    uint256 public receiptValue;
    /// @notice Every token that reached the marketplace (pulls, router rail, donations).
    uint256 public delivered;
    /// @notice Router purchases that succeeded without delivering exactly the list price.
    uint256 public inexactPurchases;
    /// @notice Refused router purchases that still left tokens at the marketplace.
    uint256 public strandedOnFailure;

    constructor(MarketplacePayments m, MockUSDC u, EscalationRouter r, Treasury t, address[] memory agents_) {
        market = m;
        usdc = u;
        router = r;
        treasury = t;
        agents = agents_;
    }

    function list(uint256 seed, uint256 price) external {
        price = bound(price, 0, 100e6);
        address seller = address(uint160(0xBEEF00 + (seed % 3)));
        bytes32 catalog = keccak256(abi.encode(listingIds.length));
        bytes32 id = market.listingIdFor(seller, catalog);
        vm.prank(seller);
        market.registerListing(catalog, price);
        listingIds.push(id);
    }

    function directPurchase(uint256 idSeed, uint256 buyerSeed) external {
        if (listingIds.length == 0) return;
        bytes32 id = listingIds[idSeed % listingIds.length];
        address buyer = address(uint160(0xB0B000 + (buyerSeed % 4)));
        (, uint256 price,) = _listing(id);
        usdc.mint(buyer, price);
        vm.startPrank(buyer);
        usdc.approve(address(market), price);
        try market.purchase(id, price) {
            receiptValue += price;
            delivered += price;
        } catch {}
        vm.stopPrank();
    }

    function routedPurchase(uint256 idSeed, uint256 agentSeed, uint256 paid, uint256 maxPrice) external {
        if (listingIds.length == 0) return;
        bytes32 id = listingIds[idSeed % listingIds.length];
        address agent = agents[agentSeed % agents.length];
        (, uint256 price,) = _listing(id);
        paid = bound(paid, 0, 100e6);
        maxPrice = bound(maxPrice, 0, 100e6);
        if (paid > 0) {
            if (treasury.liquidBalance() < paid) return;
            treasury.streamAllowance(agent, paid, uint64(block.timestamp));
        }
        bool had = market.hasPurchased(id, agent);
        uint256 balBefore = usdc.balanceOf(address(market));
        vm.prank(agent);
        try router.propose(
            agent, address(market), paid, abi.encodeCall(MarketplacePayments.purchaseFor, (id, agent, maxPrice))
        ) {
            // Covers: exact-payment purchaseFor (#626): a purchase that goes through
            // delivers exactly the list price to the marketplace.
            if (usdc.balanceOf(address(market)) - balBefore != price) inexactPurchases++;
        } catch {
            // Covers: atomic settlement (#640): a refused purchase delivers nothing.
            if (usdc.balanceOf(address(market)) != balBefore) strandedOnFailure++;
        }
        uint256 balAfter = usdc.balanceOf(address(market));
        if (balAfter > balBefore) delivered += balAfter - balBefore;
        if (!had && market.hasPurchased(id, agent)) receiptValue += price;
    }

    function _listing(bytes32 id) internal view returns (address seller, uint256 price, bool active) {
        (seller, price, active) = market.listings(id);
    }
}

contract MarketplaceReceiptInvariant is StdInvariant, Test {
    MarketHandler handler;
    MarketplacePayments market;
    MockUSDC usdc;

    function setUp() public {
        address root = makeAddr("root");
        usdc = new MockUSDC();
        OrgRegistry reg = new OrgRegistry(root);
        address[] memory agents = new address[](2);
        agents[0] = makeAddr("agentA");
        agents[1] = makeAddr("agentB");
        vm.startPrank(root);
        reg.addNode(agents[0], IOrgRegistry.NodeKind.WorkerAgent, root);
        reg.addNode(agents[1], IOrgRegistry.NodeKind.WorkerAgent, root);
        vm.stopPrank();
        WhitelistPolicy wl = new WhitelistPolicy();
        EscalationRouter router = new EscalationRouter(address(reg), address(wl));
        Treasury treasury = new Treasury(address(reg), address(usdc), address(router));
        router.setTreasury(address(treasury));
        market = new MarketplacePayments(address(usdc), root, root, 0);
        vm.prank(root);
        market.setSettlementRouter(address(router));
        wl.setAllowed(address(market), true);
        usdc.mint(address(treasury), 10_000e6);
        handler = new MarketHandler(market, usdc, router, treasury, agents);
        treasury.setGovernor(address(handler));
        targetContract(address(handler));
    }

    /// @notice Covers: exact-payment purchaseFor (#626) and atomic settlement (#640).
    ///         Every routed purchase is paid exactly, and a refused one strands nothing.
    function invariant_routedPurchasesPaidExactlyAndNothingStranded() public view {
        assertEq(handler.inexactPurchases(), 0, "purchase succeeded without exact payment");
        assertEq(handler.strandedOnFailure(), 0, "refused purchase left funds at the marketplace");
    }

    /// @notice Total price of purchase receipts never exceeds the funds delivered.
    function invariant_receiptsNeverExceedDeliveredFunds() public view {
        assertLe(handler.receiptValue(), handler.delivered());
        assertEq(usdc.balanceOf(address(market)) >= market.totalOwed(), true);
    }
}
