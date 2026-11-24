// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {IPolicyModule, Verdict} from "../interfaces/IPolicyModule.sol";
import {IValueRecorder} from "../interfaces/IValueRecorder.sol";

/// @title CumulativeValuePolicy
/// @notice Escalates when the next spend would take an agent's settled value inside
///         `windowSeconds` over `maxValue`, and, when `maxValuePerTarget` is non-zero,
///         when it would take the agent's value to one target over that budget.
///         A per-call cap (`SpendCapPolicy`) admits any number of calls just under the
///         cap; summing what settled is what stops a large spend split into small ones.
/// @dev Windows are anchored: a window opens at the first settled spend after the
///      previous one lapsed and lasts `windowSeconds`. Any span of `windowSeconds`
///      overlaps at most two windows, so value settled without escalation is bounded
///      by `maxValue` within a window and by `2 * maxValue` over any such span.
///
///      Who may record is the whole security of the module, exactly as for
///      `RateLimitPolicy`: an open `recordValue` lets anyone fill every agent's budget,
///      and a recorder bound by a stranger makes the router's own call revert. The
///      recorder is bound once, by the deployer, and until then only the deployer records.
contract CumulativeValuePolicy is IPolicyModule, IValueRecorder {
    /// @notice Budget for an agent's settled value per window, across all targets.
    uint256 public immutable maxValue;
    /// @notice Budget for an agent's settled value to one target per window; 0 = off.
    uint256 public immutable maxValuePerTarget;
    uint256 public immutable windowSeconds;

    /// @notice Deployer; the only account that may bind the recorder.
    address public immutable admin;
    address public recorder;
    bool public recorderLocked;

    struct Window {
        uint64 windowStart;
        uint192 spent;
    }

    mapping(address => Window) public agentWindows;
    mapping(address => mapping(address => Window)) public targetWindows;

    event RecorderBound(address indexed recorder);
    event ValueRecorded(address indexed agent, address indexed target, uint256 value);

    error NotRecorder(address caller);
    error NotAuthorized(address caller);
    error RecorderLocked();
    error ZeroAddress();
    error ZeroWindow();

    constructor(uint256 maxValue_, uint256 maxValuePerTarget_, uint256 windowSeconds_) {
        if (windowSeconds_ == 0) revert ZeroWindow();
        maxValue = maxValue_;
        maxValuePerTarget = maxValuePerTarget_;
        windowSeconds = windowSeconds_;
        admin = msg.sender;
    }

    /// @notice Bind who may call `recordValue` (typically EscalationRouter). Deployer-only, once.
    function setRecorder(address recorder_) external {
        if (msg.sender != admin) revert NotAuthorized(msg.sender);
        if (recorderLocked) revert RecorderLocked();
        if (recorder_ == address(0)) revert ZeroAddress();
        recorder = recorder_;
        recorderLocked = true;
        emit RecorderBound(recorder_);
    }

    /// @notice Value the agent has settled in its live window (0 once it lapsed).
    function spentOf(address agent) public view returns (uint256) {
        return _live(agentWindows[agent]);
    }

    /// @notice Value the agent has settled to `target` in their live window.
    function spentTo(address agent, address target) public view returns (uint256) {
        return _live(targetWindows[agent][target]);
    }

    /// @inheritdoc IPolicyModule
    function check(
        address agent,
        address target,
        uint256 value,
        bytes calldata
    ) external view returns (Verdict verdict) {
        if (value == 0) return Verdict.ALLOW;
        if (_crosses(spentOf(agent), value, maxValue)) return Verdict.ESCALATE;
        if (maxValuePerTarget != 0 && _crosses(spentTo(agent, target), value, maxValuePerTarget)) {
            return Verdict.ESCALATE;
        }
        return Verdict.ALLOW;
    }

    /// @inheritdoc IValueRecorder
    /// @dev Records settled value, including spends a parent approved over budget, so
    ///      an approved overage still fills the window it landed in.
    function recordValue(address agent, address target, uint256 value) external {
        address allowed = recorder == address(0) ? admin : recorder;
        if (msg.sender != allowed) revert NotRecorder(msg.sender);
        if (value == 0) return;

        _add(agentWindows[agent], value);
        if (maxValuePerTarget != 0) _add(targetWindows[agent][target], value);
        emit ValueRecorded(agent, target, value);
    }

    /// @dev `spent + value > budget` without the addition, so a huge `value` reads as
    ///      ESCALATE rather than reverting the whole propose on overflow.
    function _crosses(uint256 spent, uint256 value, uint256 budget) private pure returns (bool) {
        return spent > budget || value > budget - spent;
    }

    function _live(Window memory w) private view returns (uint256) {
        if (w.windowStart == 0 || block.timestamp >= uint256(w.windowStart) + windowSeconds) {
            return 0;
        }
        return w.spent;
    }

    /// @dev Saturates at `uint192` max: a window that full escalates every spend anyway,
    ///      and reverting here would undo a settlement a parent already approved.
    function _add(Window storage w, uint256 value) private {
        uint256 spent = value;
        if (w.windowStart != 0 && block.timestamp < uint256(w.windowStart) + windowSeconds) {
            spent = w.spent + (value > type(uint192).max ? type(uint192).max : value);
        } else {
            w.windowStart = uint64(block.timestamp);
        }
        w.spent = spent > type(uint192).max ? type(uint192).max : uint192(spent);
    }
}
