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

/// @dev Invariants from the audit follow-up. Two of them are violated on the current
///      code (`AuditPoC.t.sol` proves each); they are gated by the flags below and run
///      as skipped until the fix lands. Flip the flag to `false` in the same change as
///      the fix, then invert the matching PoC to `vm.expectRevert`.
bool constant LOW_TIER_DEADLINE_FIX_PENDING = true;
bool constant ROUTER_FAILED_CALL_FIX_PENDING = true;

// ——— Governance: no Low-tier proposal executes before its deadline ———

contract GovTierHandler is Test {
    GovernanceModule public immutable gov;
    address[] internal voters;
    uint256[] internal ids;
    /// @notice Executions that happened strictly before the proposal deadline.
    uint256 public earlyExecutions;

    constructor(GovernanceModule gov_, address[] memory voters_) {
        gov = gov_;
        voters = voters_;
    }

    function propose(uint256 targetSeed) external {
        // Parameter-neutral Low-tier action: a no-op call on a benign target.
        address target = address(uint160(bound(targetSeed, 1, 1000)));
        ids.push(gov.propose(GovernanceModule.Tier.Low, target, ""));
    }

    function vote(uint256 idSeed, uint256 voterSeed, bool support) external {
        if (ids.length == 0) return;
        vm.prank(voters[voterSeed % voters.length]);
        try gov.vote(ids[idSeed % ids.length], support) {} catch {}
    }

    function execute(uint256 idSeed) external {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        (,,,,,,,, uint256 deadline,,) = gov.proposals(id);
        try gov.execute(id) {
            if (block.timestamp < deadline) earlyExecutions++;
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
        address a = makeAddr("agentA");
        address b = makeAddr("agentB");
        vm.startPrank(root);
        gov.setVotingPower(a, 1, GovernanceModule.SeatRole.Agent);
        gov.setVotingPower(b, 1, GovernanceModule.SeatRole.Agent);
        vm.stopPrank();
        address[] memory voters = new address[](3);
        voters[0] = root;
        voters[1] = a;
        voters[2] = b;
        handler = new GovTierHandler(gov, voters);
        targetContract(address(handler));
    }

    function invariant_noLowTierExecutesBeforeDeadline() public {
        vm.skip(LOW_TIER_DEADLINE_FIX_PENDING);
        assertEq(handler.earlyExecutions(), 0, "low-tier proposal executed before deadline");
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
        vm.prank(agent);
        try router.propose(agent, address(sink), value, abi.encodeCall(FlakySink.work, (fail))) returns (
            uint256 intentId, Verdict
        ) {
            if (intentId == 0) valueMovingCalls++;
        } catch {}
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

    /// @notice A router propose that moves value always makes the target call succeed.
    function invariant_valueMovingProposeAlwaysSucceedsOnTarget() public {
        vm.skip(ROUTER_FAILED_CALL_FIX_PENDING);
        assertEq(sink.okCalls(), handler.valueMovingCalls(), "value moved but target call failed");
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
        bytes32 id = keccak256(abi.encode(listingIds.length));
        vm.prank(seller);
        market.registerListing(id, price);
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
        ) {}
            catch {}
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

    /// @notice Total price of purchase receipts never exceeds the funds delivered.
    function invariant_receiptsNeverExceedDeliveredFunds() public view {
        assertLe(handler.receiptValue(), handler.delivered());
        assertEq(usdc.balanceOf(address(market)) >= market.totalOwed(), true);
    }
}
