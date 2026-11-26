// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IOrgRegistry} from "./interfaces/IOrgRegistry.sol";
import {ITreasurySpender} from "./interfaces/ITreasurySpender.sol";

/// @title Treasury
/// @notice Holds org ERC-20 funds and streams allowances downward on epoch schedules.
/// @dev Token stays in this contract until spent; `allowanceBalance` is working-capital bookkeeping.
///
///      Asset assumptions. The bookkeeping (`totalReserved` against `balanceOf`) holds only for
///      a token whose transfers move exactly the amount asked and whose balances change only
///      through transfers. Every movement here is measured, so a fee-on-transfer token reverts
///      (`TransferAmountMismatch`) instead of quietly reserving more than the treasury holds.
///      A rebasing token cannot be caught at transfer time: a negative rebase shows up as
///      `shortfall()`, and such tokens are unsupported. A token with an issuer blocklist (USDC,
///      USDT) can freeze this contract outright; nothing onchain routes around that, which is
///      why each asset gets its own treasury (see SPEC §4.2).
contract Treasury is ITreasurySpender {
    using SafeERC20 for IERC20;

    address public immutable orgRegistry;
    IERC20 public immutable token;

    /// @notice Deployer. Holds bootstrap authority until `governor` is bound, so the
    ///         window between deployment and `setGovernor` is not permissionless.
    address public immutable deployer;
    address public spender;
    /// @notice GovernanceModule (or the deployer while bootstrapping) for setSpender / stream authorization.
    address public governor;
    /// @notice Address named by the governor to take over; it has no power until it accepts.
    address public pendingGovernor;
    /// @notice Optional epoch job that may call `streamAllowance`.
    address public streamer;

    /// @notice Emergency stop: while set, `streamAllowance` and `spendAllowance` revert.
    ///         Deposits stay open, and the router's reject/cancel paths never touch the treasury.
    bool public paused;

    uint256 public totalReserved;
    mapping(address => uint256) public allowanceBalance;
    /// @notice The node's `OrgRegistry` incarnation its current allowance was granted under.
    ///         Allowance left by a removed node is not spendable by whoever re-takes the address.
    mapping(address => uint64) public allowanceGeneration;

    event SpenderUpdated(address indexed spender);
    event GovernorUpdated(address indexed governor);
    event PendingGovernorUpdated(address indexed pendingGovernor);
    event StreamerUpdated(address indexed streamer);
    event Deposited(address indexed from, uint256 amount);
    event AllowanceStreamed(address indexed node, uint256 amount, uint64 epoch);
    event AllowanceSpent(address indexed node, uint256 amount, address indexed to);
    event AllowanceRefunded(address indexed node, uint256 amount);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event AllowanceRevoked(address indexed node, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);

    error InsufficientAllowance(address node, uint256 requested, uint256 available);
    /// @dev The node's allowance predates its current incarnation; governance must
    ///      `revokeAllowance` it back to the treasury first.
    error StaleAllowance(address node);
    error InsufficientTreasury(uint256 requested, uint256 available);
    error NotSpender(address caller);
    error NotAuthorized(address caller);
    error ZeroAddress();
    /// @dev `acceptGovernor` was called by an address that is not the pending governor.
    error NotPendingGovernor(address caller);
    error GovernorAlreadySet();
    error EnforcedPause();
    error AlreadyPaused();
    error NotPaused();
    /// @dev The token moved a different amount than requested: fee-on-transfer or similar.
    error TransferAmountMismatch(uint256 expected, uint256 actual);

    constructor(address orgRegistry_, address token_, address spender_) {
        if (orgRegistry_ == address(0) || token_ == address(0)) revert ZeroAddress();
        orgRegistry = orgRegistry_;
        token = IERC20(token_);
        spender = spender_;
        deployer = msg.sender;
    }

    /// @notice Bind constitutional authority, once, by the deployer. Handing it on
    ///         afterwards is two steps: `setPendingGovernor`, then `acceptGovernor`.
    function setGovernor(address governor_) external {
        if (governor_ == address(0)) revert ZeroAddress();
        if (governor != address(0)) revert GovernorAlreadySet();
        if (msg.sender != deployer) revert NotAuthorized(msg.sender);
        governor = governor_;
        emit GovernorUpdated(governor_);
    }

    /// @notice Name the address that may take over governance. Current governor only;
    ///         naming another address replaces the pending one, and the zero address
    ///         cancels it. The governor keeps every power until the pending address calls
    ///         `acceptGovernor`, so a wrong address is corrected by naming the right one.
    function setPendingGovernor(address pending) external {
        if (governor == address(0) || msg.sender != governor) revert NotAuthorized(msg.sender);
        pendingGovernor = pending;
        emit PendingGovernorUpdated(pending);
    }

    /// @notice Complete the hand-over: only the pending governor may call it.
    function acceptGovernor() external {
        if (pendingGovernor == address(0) || msg.sender != pendingGovernor) {
            revert NotPendingGovernor(msg.sender);
        }
        governor = msg.sender;
        pendingGovernor = address(0);
        emit GovernorUpdated(msg.sender);
    }

    /// @notice Bind (or, with the zero address, unbind) the epoch job that may call
    ///         `streamAllowance`.
    /// @dev Binding a streamer is exclusive on purpose. The deployer's own
    ///      `streamAllowance` is a bootstrap convenience for a treasury with no payroll
    ///      wired; once a streamer is bound, allowances come from the schedule and the
    ///      deployer stops streaming directly, even while no governor is set. That
    ///      keeps one source of allowance per treasury, so the streamer's grant
    ///      schedule is the whole account of what nodes are paid. The deployer still
    ///      holds this setter until a governor is bound, so `setStreamer(address(0))`
    ///      returns it to direct streaming: exclusivity is a routing rule, not a
    ///      revocation of bootstrap authority.
    function setStreamer(address streamer_) external {
        _onlyGovernorOrBootstrap();
        streamer = streamer_;
        emit StreamerUpdated(streamer_);
    }

    /// @notice Update who may call `spendAllowance` (typically EscalationRouter).
    function setSpender(address spender_) external {
        _onlyGovernorOrBootstrap();
        if (spender_ == address(0)) revert ZeroAddress();
        spender = spender_;
        emit SpenderUpdated(spender_);
    }

    /// @notice Emergency stop. Any active human seat in the org tree, or the current
    ///         governance authority, may pause; only that authority (the governor once
    ///         bound, the deployer until then) can unpause, so lifting it goes through
    ///         governance while stopping it needs no vote.
    function pause() external {
        if (paused) revert AlreadyPaused();
        if (!_isHumanSeat(msg.sender) && msg.sender != _authority()) revert NotAuthorized(msg.sender);
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Lift the emergency stop.
    function unpause() external {
        _onlyGovernorOrBootstrap();
        if (!paused) revert NotPaused();
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Deposit ERC-20 into the treasury (caller must approve first).
    function deposit(uint256 amount) external {
        _pullExact(msg.sender, amount);
        emit Deposited(msg.sender, amount);
    }

    /// @notice Allocate unreserved treasury balance to `node` for an epoch.
    /// @dev Governor or streamer; the deployer only while neither is bound (see
    ///      `setStreamer` for why a bound streamer displaces the deployer).
    function streamAllowance(address node, uint256 amount, uint64 epoch) external {
        if (paused) revert EnforcedPause();
        if (governor != address(0) || streamer != address(0)) {
            if (msg.sender != governor && msg.sender != streamer) revert NotAuthorized(msg.sender);
        } else if (msg.sender != deployer) {
            revert NotAuthorized(msg.sender);
        }
        // Allowance booked to the zero address could never be spent: it would stay
        // reserved, out of the liquid balance, for good.
        if (node == address(0)) revert ZeroAddress();
        uint256 liquid = liquidBalance();
        if (liquid < amount) revert InsufficientTreasury(amount, liquid);

        _bindGeneration(node);
        allowanceBalance[node] += amount;
        totalReserved += amount;
        emit AllowanceStreamed(node, amount, epoch);
    }

    /// @inheritdoc ITreasurySpender
    function spendAllowance(address node, uint256 amount, address to) external {
        if (msg.sender != spender) revert NotSpender(msg.sender);
        if (paused) revert EnforcedPause();
        if (to == address(0)) revert ZeroAddress();
        _spend(node, amount, to);
    }

    /// @notice Debit `node` allowance and transfer tokens to the spender (router).
    function spendAllowance(address node, uint256 amount) external {
        if (msg.sender != spender) revert NotSpender(msg.sender);
        if (paused) revert EnforcedPause();
        _spend(node, amount, msg.sender);
    }

    /// @inheritdoc ITreasurySpender
    /// @dev The router returns what a pulling target left behind. The tokens come back by
    ///      transferFrom, measured, before the allowance is restored, so a refund can never
    ///      reserve more than actually arrived.
    function refundAllowance(address node, uint256 amount) external {
        if (msg.sender != spender) revert NotSpender(msg.sender);
        if (node == address(0)) revert ZeroAddress();
        _pullExact(msg.sender, amount);
        _bindGeneration(node);
        allowanceBalance[node] += amount;
        totalReserved += amount;
        emit AllowanceRefunded(node, amount);
    }

    /// @notice Return `amount` of `node`'s allowance to the liquid balance (e.g. after the
    ///         node is removed from the registry). Governor only; the deployer while no
    ///         governor is bound.
    function revokeAllowance(address node, uint256 amount) external {
        _onlyGovernorOrBootstrap();
        uint256 available = allowanceBalance[node];
        if (available < amount) revert InsufficientAllowance(node, amount, available);
        allowanceBalance[node] = available - amount;
        totalReserved -= amount;
        if (available == amount) delete allowanceGeneration[node];
        emit AllowanceRevoked(node, amount);
    }

    /// @notice Move unreserved funds out of the treasury (migration, wind-down, incident
    ///         response). Bounded by `liquidBalance()`; reserved allowances stay untouched.
    /// @dev Governor only. GovernanceModule forces proposals carrying this selector to
    ///      High tier, so it always clears the human quorum, timelock and veto window.
    function withdraw(address to, uint256 amount) external {
        _onlyGovernorOrBootstrap();
        if (to == address(0)) revert ZeroAddress();
        uint256 liquid = liquidBalance();
        if (liquid < amount) revert InsufficientTreasury(amount, liquid);
        uint256 before = token.balanceOf(to);
        token.safeTransfer(to, amount);
        uint256 received = token.balanceOf(to) - before;
        if (received != amount) revert TransferAmountMismatch(amount, received);
        emit Withdrawn(to, amount);
    }

    function liquidBalance() public view returns (uint256) {
        uint256 bal = token.balanceOf(address(this));
        return bal > totalReserved ? bal - totalReserved : 0;
    }

    /// @notice How far the balance has fallen below what is reserved. Zero for a vanilla
    ///         ERC-20; non-zero means the token changed balances outside a transfer (a negative
    ///         rebase, a seizure) and the last spenders would find their allowance unbacked.
    function shortfall() external view returns (uint256) {
        uint256 bal = token.balanceOf(address(this));
        return totalReserved > bal ? totalReserved - bal : 0;
    }

    /// @dev Governor once bound; the deployer until then.
    function _authority() private view returns (address) {
        return governor == address(0) ? deployer : governor;
    }

    function _isHumanSeat(address account) private view returns (bool) {
        try IOrgRegistry(orgRegistry).getNode(account) returns (IOrgRegistry.Node memory node) {
            return node.active && node.kind == IOrgRegistry.NodeKind.HumanRoot;
        } catch {
            return false;
        }
    }

    function _onlyGovernorOrBootstrap() private view {
        if (msg.sender != _authority()) revert NotAuthorized(msg.sender);
    }

    /// @dev An empty allowance starts under the node's current incarnation; a non-empty
    ///      one must already belong to it.
    function _bindGeneration(address node) private {
        uint64 current = IOrgRegistry(orgRegistry).generationOf(node);
        if (allowanceBalance[node] == 0) {
            allowanceGeneration[node] = current;
        } else if (allowanceGeneration[node] != current) {
            revert StaleAllowance(node);
        }
    }

    function _spend(address node, uint256 amount, address to) private {
        uint256 available = allowanceBalance[node];
        if (available < amount) revert InsufficientAllowance(node, amount, available);
        if (allowanceGeneration[node] != IOrgRegistry(orgRegistry).generationOf(node)) {
            revert StaleAllowance(node);
        }
        allowanceBalance[node] = available - amount;
        totalReserved -= amount;
        uint256 before = token.balanceOf(to);
        token.safeTransfer(to, amount);
        uint256 received = token.balanceOf(to) - before;
        if (received != amount) revert TransferAmountMismatch(amount, received);
        emit AllowanceSpent(node, amount, to);
    }

    function _pullExact(address from, uint256 amount) private {
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;
        if (received != amount) revert TransferAmountMismatch(amount, received);
    }
}
