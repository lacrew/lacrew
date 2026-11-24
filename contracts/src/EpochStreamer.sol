// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Treasury} from "./Treasury.sol";

/// @title EpochStreamer
/// @notice Payroll-style job: streams fixed grants to configured nodes once per epoch.
/// @dev Authorized as Treasury.streamer. Operator runs epochs; grant schedule can also
///      be mutated by `governor` (GovernanceModule) for constitutional budget changes.
///      Epochs are strictly sequential and time-gated: epoch n unlocks at
///      `epochStart + (n - 1) * epochDuration`, so a compromised operator key can
///      stream at most one payroll per period (and at most the elapsed backlog),
///      never N payrolls in a single transaction.
contract EpochStreamer {
    Treasury public immutable treasury;
    /// @notice Timestamp at which epoch 1 unlocks.
    uint64 public immutable epochStart;
    /// @notice Seconds between consecutive epoch unlocks (non-zero).
    uint64 public immutable epochDuration;
    address public operator;
    /// @notice When non-zero, may call `setGrant` (typically GovernanceModule).
    address public governor;

    /// @notice Max grant recipients. `_runEpoch` makes one Treasury call per recipient
    ///         in a single tx, so this keeps payroll under the block gas limit.
    uint256 public constant MAX_RECIPIENTS = 100;

    uint64 public currentEpoch;
    mapping(address => uint256) public grantAmount;
    address[] private _recipients;
    mapping(address => bool) private _isRecipient;
    mapping(uint64 => bool) public epochCompleted;

    event OperatorUpdated(address indexed operator);
    event GovernorUpdated(address indexed governor);
    event GrantUpdated(address indexed node, uint256 amount);
    event EpochRun(uint64 indexed epoch, uint256 recipientCount);

    error NotOperator(address caller);
    error NotAuthorized(address caller);
    error EpochAlreadyRun(uint64 epoch);
    error EpochNotReady(uint64 epoch, uint256 unlockTime);
    error ZeroDuration();
    error ZeroAddress();
    error EmptySchedule();
    error GovernorAlreadySet();
    error LengthMismatch();
    error TooManyRecipients();

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator(msg.sender);
        _;
    }

    constructor(address treasury_, address operator_, uint64 epochStart_, uint64 epochDuration_) {
        if (treasury_ == address(0) || operator_ == address(0)) revert ZeroAddress();
        if (epochDuration_ == 0) revert ZeroDuration();
        treasury = Treasury(treasury_);
        operator = operator_;
        epochStart = epochStart_;
        epochDuration = epochDuration_;
    }

    function setOperator(address operator_) external onlyOperator {
        if (operator_ == address(0)) revert ZeroAddress();
        operator = operator_;
        emit OperatorUpdated(operator_);
    }

    /// @notice Bind constitutional authority for grant schedule. Callable once by operator.
    function setGovernor(address governor_) external onlyOperator {
        if (governor_ == address(0)) revert ZeroAddress();
        if (governor != address(0)) revert GovernorAlreadySet();
        governor = governor_;
        emit GovernorUpdated(governor_);
    }

    /// @notice Set (or clear with amount=0) the per-epoch grant for `node`.
    function setGrant(address node, uint256 amount) external {
        if (msg.sender != operator && msg.sender != governor) revert NotAuthorized(msg.sender);
        _setGrant(node, amount);
    }

    /// @notice Batch form of `setGrant` — set/clear many grants at once, so a
    ///         cadence-change rescale is one call (and, through governance, one
    ///         proposal) instead of N. Same authorization; arrays must align.
    function setGrants(address[] calldata nodes, uint256[] calldata amounts) external {
        if (msg.sender != operator && msg.sender != governor) revert NotAuthorized(msg.sender);
        if (nodes.length != amounts.length) revert LengthMismatch();
        for (uint256 i = 0; i < nodes.length; i++) {
            _setGrant(nodes[i], amounts[i]);
        }
    }

    function _setGrant(address node, uint256 amount) private {
        if (node == address(0)) revert ZeroAddress();
        if (amount == 0) {
            if (_isRecipient[node]) {
                _isRecipient[node] = false;
                grantAmount[node] = 0;
                _removeRecipient(node);
            }
        } else {
            grantAmount[node] = amount;
            if (!_isRecipient[node]) {
                if (_recipients.length >= MAX_RECIPIENTS) revert TooManyRecipients();
                _isRecipient[node] = true;
                _recipients.push(node);
            }
        }
        emit GrantUpdated(node, amount);
    }

    function recipients() external view returns (address[] memory) {
        return _recipients;
    }

    /// @notice Timestamp at which `epoch` (1-based) unlocks.
    function epochUnlockTime(uint64 epoch) public view returns (uint256) {
        return uint256(epochStart) + (uint256(epoch) - 1) * uint256(epochDuration);
    }

    /// @notice Advance `currentEpoch` by exactly one and stream all grants. Reverts
    ///         until that epoch's unlock time; elapsed epochs may be back-filled
    ///         one call at a time, never ahead of the clock.
    function runNextEpoch() external onlyOperator returns (uint64 epoch) {
        epoch = currentEpoch + 1;
        uint256 unlock = epochUnlockTime(epoch);
        if (block.timestamp < unlock) revert EpochNotReady(epoch, unlock);
        _runEpoch(epoch);
        currentEpoch = epoch;
    }

    function _runEpoch(uint64 epoch) private {
        if (epochCompleted[epoch]) revert EpochAlreadyRun(epoch);
        uint256 n = _recipients.length;
        if (n == 0) revert EmptySchedule();

        epochCompleted[epoch] = true;
        for (uint256 i = 0; i < n; i++) {
            address node = _recipients[i];
            uint256 amount = grantAmount[node];
            if (amount == 0) continue;
            treasury.streamAllowance(node, amount, epoch);
        }
        emit EpochRun(epoch, n);
    }

    function _removeRecipient(address node) private {
        uint256 n = _recipients.length;
        for (uint256 i = 0; i < n; i++) {
            if (_recipients[i] == node) {
                _recipients[i] = _recipients[n - 1];
                _recipients.pop();
                return;
            }
        }
    }
}
