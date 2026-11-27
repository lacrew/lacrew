// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {IPolicyModule, Verdict} from "../interfaces/IPolicyModule.sol";

/// @title WhitelistPolicy
/// @notice ALLOWs calls to whitelisted targets; DENYs everything else.
/// @dev Mutators gated by admin (deployer) until `setGovernor` binds, then by the governor
///      alone: binding the governor drops `admin` to zero, so the deployer keeps no authority.
contract WhitelistPolicy is IPolicyModule {
    mapping(address => bool) public allowed;
    address public admin;
    address public governor;
    /// @notice Address named by the governor to take over; it has no power until it accepts.
    address public pendingGovernor;

    event TargetAllowed(address indexed target, bool allowed);
    event GovernorUpdated(address indexed governor);
    event PendingGovernorUpdated(address indexed pendingGovernor);

    error NotAuthorized(address caller);
    error ZeroAddress();
    error GovernorAlreadySet();
    /// @dev `acceptGovernor` was called by an address that is not the pending governor.
    error NotPendingGovernor(address caller);

    constructor() {
        admin = msg.sender;
    }

    /// @notice Bind constitutional authority. Callable once by admin, which it then drops. Handing it on
    ///         afterwards is `setPendingGovernor` then `acceptGovernor`.
    function setGovernor(address governor_) external {
        if (msg.sender != admin) revert NotAuthorized(msg.sender);
        if (governor_ == address(0)) revert ZeroAddress();
        if (governor != address(0)) revert GovernorAlreadySet();
        governor = governor_;
        admin = address(0);
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

    function setAllowed(address target, bool isAllowed) external {
        if (msg.sender != admin && msg.sender != governor) revert NotAuthorized(msg.sender);
        allowed[target] = isAllowed;
        emit TargetAllowed(target, isAllowed);
    }

    /// @inheritdoc IPolicyModule
    function check(
        address,
        address target,
        uint256,
        bytes calldata
    ) external view returns (Verdict verdict) {
        if (allowed[target]) return Verdict.ALLOW;
        return Verdict.DENY;
    }
}
