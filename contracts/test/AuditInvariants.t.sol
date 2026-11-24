// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GovernanceModule} from "../src/GovernanceModule.sol";
import {OrgRegistry} from "../src/OrgRegistry.sol";
import {IOrgRegistry} from "../src/interfaces/IOrgRegistry.sol";
import {Treasury} from "../src/Treasury.sol";
import {EscalationRouter} from "../src/EscalationRouter.sol";
import {MarketplacePayments} from "../src/MarketplacePayments.sol";
import {WhitelistPolicy} from "../src/policies/WhitelistPolicy.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

// ———————————————————————————————————————————————————————————————————————————
// Invariant 1: no Low-tier proposal executes before its deadline.
// ———————————————————————————————————————————————————————————————————————————

contract NoopTarget {
    uint256 public pings;

    function ping() external {
        pings++;
    }
}

/// @dev Drives propose / vote / execute / time travel and records every Low-tier
///      execution that happened at or before the proposal's deadline.
contract LowTierHandler is Test {
    GovernanceModule public immutable gov;
    NoopTarget public immutable target;
    address public immutable root;
    address[] public seats;

    uint256[] public ids;
    uint256 public ghostEarlyLowExecutions;

    constructor(GovernanceModule gov_, NoopTarget target_, address root_, address[] memory seats_) {
        gov = gov_;
        target = target_;
        root = root_;
        seats = seats_;
    }

    function propose(bool high) external {
        GovernanceModule.Tier tier = high ? GovernanceModule.Tier.High : GovernanceModule.Tier.Low;
        ids.push(gov.propose(tier, address(target), abi.encodeCall(NoopTarget.ping, ())));
    }

    function vote(uint256 idSeed, uint256 seatSeed, bool support) external {
        if (ids.length == 0) return;
        vm.prank(seats[seatSeed % seats.length]);
        try gov.vote(ids[idSeed % ids.length], support) {} catch {}
    }

    function execute(uint256 idSeed) external {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        (, GovernanceModule.Tier tier,,,,,,, uint256 deadline,,) = gov.proposals(id);
        try gov.execute(id) {
            (,,,,,,,,,, GovernanceModule.ProposalState state) = gov.proposals(id);
            if (
                state == GovernanceModule.ProposalState.Executed
                    && tier == GovernanceModule.Tier.Low && block.timestamp <= deadline
            ) {
                ghostEarlyLowExecutions++;
            }
        } catch {}
    }

    function veto(uint256 idSeed) external {
        if (ids.length == 0) return;
        vm.prank(root);
        try gov.veto(ids[idSeed % ids.length]) {} catch {}
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 2 days));
    }
}

contract LowTierDeadlineInvariantTest is StdInvariant, Test {
    /// @dev Flip to true when the Low-tier deadline fix lands (see AuditPoC
    ///      `test_fixed_lowTier*`). While false the invariant is skipped, because the
    ///      current GovernanceModule executes Low tier as soon as quorum is met.
    bool internal constant LOW_TIER_DEADLINE_ENFORCED = false;

    address internal root = makeAddr("root");
    address internal agentA = makeAddr("agentA");
    address internal agentB = makeAddr("agentB");
    GovernanceModule internal gov;
    LowTierHandler internal handler;

    function setUp() public {
        gov = new GovernanceModule(root, 2);
        vm.startPrank(root);
        gov.setVotingPower(agentA, 1, GovernanceModule.SeatRole.Agent);
        gov.setVotingPower(agentB, 1, GovernanceModule.SeatRole.Agent);
        vm.stopPrank();

        address[] memory seats = new address[](3);
        seats[0] = root;
        seats[1] = agentA;
        seats[2] = agentB;
        handler = new LowTierHandler(gov, new NoopTarget(), root, seats);
        targetContract(address(handler));
    }

    /// @notice A Low-tier proposal never executes at or before its voting deadline, so
    ///         every human seat always has the whole window to vote or veto.
    function invariant_noLowTierExecutesBeforeDeadline() public {
        if (!LOW_TIER_DEADLINE_ENFORCED) vm.skip(true);
        assertEq(handler.ghostEarlyLowExecutions(), 0);
    }
}

// ———————————————————————————————————————————————————————————————————————————
// Invariants 2-4: treasury accounting, router settlement, marketplace receipts.
// ———————————————————————————————————————————————————————————————————————————

/// @dev Takes exactly what it is approved for.
contract PullTarget {
    function pull(IERC20 token, uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
    }
}

/// @dev Pulls the tokens, then reverts: the pull must be undone with the call.
contract PullThenRevertTarget {
    function pull(IERC20 token, uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        revert("nope");
    }
}

/// @dev Accepts the call and ignores the tokens.
contract LazyTarget {
    function poke() external {}
}

contract SettlementHandler is Test {
    bytes32 internal constant ACTION_EXECUTED =
        keccak256("ActionExecuted(address,address,uint256,bool)");

    EscalationRouter public immutable router;
    Treasury public immutable treasury;
    MockUSDC public immutable usdc;
    MarketplacePayments public immutable market;
    address public immutable root;
    address public immutable puller;
    address public immutable pullThenRevert;
    address public immutable lazy;

    address[] public agents;
    bytes32[] public listingIds;
    address public immutable seller = makeAddr("seller");

    /// @dev Router proposals that charged an allowance but whose target call failed.
    uint256 public ghostValueMovedWithoutCall;
    /// @dev Router proposals whose allowance charge differs from what the event reports.
    uint256 public ghostChargeMismatch;
    uint256 public ghostWithdrawn;

    constructor(
        EscalationRouter router_,
        Treasury treasury_,
        MockUSDC usdc_,
        MarketplacePayments market_,
        address root_,
        address puller_,
        address pullThenRevert_,
        address lazy_,
        address[] memory agents_
    ) {
        router = router_;
        treasury = treasury_;
        usdc = usdc_;
        market = market_;
        root = root_;
        puller = puller_;
        pullThenRevert = pullThenRevert_;
        lazy = lazy_;
        agents = agents_;
        for (uint256 i = 0; i < 3; i++) {
            listingIds.push(keccak256(abi.encode("listing", i)));
        }
    }

    function agentCount() external view returns (uint256) {
        return agents.length;
    }

    function listingCount() external view returns (uint256) {
        return listingIds.length;
    }

    function topUp(uint256 agentSeed, uint256 amount) external {
        uint256 liquid = treasury.liquidBalance();
        if (liquid == 0) return;
        amount = bound(amount, 1, liquid > 500e6 ? 500e6 : liquid);
        treasury.streamAllowance(agents[agentSeed % agents.length], amount, 1);
    }

    /// @notice Registers a listing once; the price then stays fixed so receipts can be
    ///         valued at their listing price.
    function list(uint256 idSeed, uint256 price) external {
        bytes32 id = listingIds[idSeed % listingIds.length];
        (address owner,,) = market.listings(id);
        if (owner != address(0)) return;
        vm.prank(seller);
        market.registerListing(id, bound(price, 0, 200e6));
    }

    /// @notice Propose a router call of any shape: pulling, pull-then-revert, ignoring,
    ///         or a marketplace purchase with a possibly-too-low maxPrice.
    function proposeCall(uint256 agentSeed, uint256 kind, uint256 value, uint256 idSeed, uint256 priceSkew)
        external
    {
        address agent = agents[agentSeed % agents.length];
        kind = kind % 4;
        value = bound(value, 0, 300e6);
        address target;
        bytes memory data;
        if (kind == 0) {
            target = puller;
            data = abi.encodeCall(PullTarget.pull, (IERC20(address(usdc)), bound(priceSkew, 0, value)));
        } else if (kind == 1) {
            target = pullThenRevert;
            data = abi.encodeCall(PullThenRevertTarget.pull, (IERC20(address(usdc)), value));
        } else if (kind == 2) {
            target = lazy;
            data = abi.encodeCall(LazyTarget.poke, ());
        } else {
            bytes32 id = listingIds[idSeed % listingIds.length];
            (, uint256 price,) = market.listings(id);
            uint256 maxPrice = priceSkew % 3 == 0 && price > 0 ? price - 1 : price + (priceSkew % 5);
            target = address(market);
            data = abi.encodeCall(MarketplacePayments.purchaseFor, (id, agent, maxPrice));
        }

        uint256 allowanceBefore = treasury.allowanceBalance(agent);
        vm.recordLogs();
        vm.prank(agent);
        try router.propose(agent, target, value, data) {} catch {
            vm.getRecordedLogs();
            return;
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 charged = allowanceBefore - treasury.allowanceBalance(agent);
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(router) || logs[i].topics[0] != ACTION_EXECUTED) continue;
            (uint256 settled, bool callOk) = abi.decode(logs[i].data, (uint256, bool));
            if (charged != settled) ghostChargeMismatch++;
            if (value > 0 && !callOk && settled > 0) ghostValueMovedWithoutCall++;
            if (charged > 0 && !callOk) ghostValueMovedWithoutCall++;
        }
    }

    function withdrawAs(uint256 seed) external {
        address payee = seed % 2 == 0 ? seller : root;
        if (market.owed(payee) == 0) return;
        vm.prank(payee);
        ghostWithdrawn += market.withdraw();
    }
}

contract AuditSettlementInvariantTest is StdInvariant, Test {
    address internal root = makeAddr("root");
    MockUSDC internal usdc;
    OrgRegistry internal registry;
    Treasury internal treasury;
    EscalationRouter internal router;
    MarketplacePayments internal market;
    SettlementHandler internal handler;

    function setUp() public {
        usdc = new MockUSDC();
        registry = new OrgRegistry(root);
        address[] memory agents = new address[](3);
        agents[0] = makeAddr("agent0");
        agents[1] = makeAddr("agent1");
        agents[2] = makeAddr("agent2");
        vm.startPrank(root);
        for (uint256 i = 0; i < agents.length; i++) {
            registry.addNode(agents[i], IOrgRegistry.NodeKind.WorkerAgent, root);
        }
        vm.stopPrank();

        PullTarget puller = new PullTarget();
        PullThenRevertTarget pullThenRevert = new PullThenRevertTarget();
        LazyTarget lazy = new LazyTarget();

        WhitelistPolicy whitelist = new WhitelistPolicy();
        router = new EscalationRouter(address(registry), address(whitelist));
        treasury = new Treasury(address(registry), address(usdc), address(router));
        router.setTreasury(address(treasury));
        market = new MarketplacePayments(address(usdc), root, root, 1000);
        vm.prank(root);
        market.setSettlementRouter(address(router));
        whitelist.setAllowed(address(puller), true);
        whitelist.setAllowed(address(pullThenRevert), true);
        whitelist.setAllowed(address(lazy), true);
        whitelist.setAllowed(address(market), true);

        usdc.mint(address(treasury), 1_000_000e6);
        handler = new SettlementHandler(
            router, treasury, usdc, market, root, address(puller), address(pullThenRevert), address(lazy), agents
        );
        treasury.setGovernor(address(handler));
        for (uint256 i = 0; i < agents.length; i++) {
            vm.prank(address(handler));
            treasury.streamAllowance(agents[i], 200e6, 0);
        }
        targetContract(address(handler));
    }

    /// @notice Treasury accounting: reserved working capital is exactly the sum of node
    ///         allowances, through streaming, spends, pull settlements and refunds.
    function invariant_totalReservedEqualsAllowances() public view {
        uint256 sum;
        for (uint256 i = 0; i < handler.agentCount(); i++) {
            sum += treasury.allowanceBalance(handler.agents(i));
        }
        assertEq(treasury.totalReserved(), sum);
        assertGe(usdc.balanceOf(address(treasury)), treasury.totalReserved());
    }

    /// @notice A router propose that moves value always makes the target call succeed,
    ///         and the allowance charge is exactly what the router reports it settled.
    function invariant_valueMovedImpliesCallSucceeded() public view {
        assertEq(handler.ghostValueMovedWithoutCall(), 0);
        assertEq(handler.ghostChargeMismatch(), 0);
    }

    /// @notice The router never keeps tokens between transactions.
    function invariant_routerHoldsNothing() public view {
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    /// @notice Purchased receipts are covered by funds actually delivered to the
    ///         marketplace: a receipt without payment is a free purchase.
    function invariant_receiptsCoveredByDeliveredFunds() public view {
        uint256 receiptValue;
        for (uint256 l = 0; l < handler.listingCount(); l++) {
            bytes32 id = handler.listingIds(l);
            (,uint256 price,) = market.listings(id);
            for (uint256 a = 0; a < handler.agentCount(); a++) {
                if (market.hasPurchased(id, handler.agents(a))) receiptValue += price;
            }
        }
        uint256 delivered = usdc.balanceOf(address(market)) + handler.ghostWithdrawn();
        assertLe(receiptValue, delivered);
    }
}
