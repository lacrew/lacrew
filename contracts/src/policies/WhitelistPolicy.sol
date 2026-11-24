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

    event TargetAllowed(address indexed target, bool allowed);
    event GovernorUpdated(address indexed governor);

    error NotAuthorized(address caller);
    error ZeroAddress();
    error GovernorAlreadySet();

    constructor() {
        admin = msg.sender;
    }

    /// @notice Bind constitutional authority. Callable once by admin, which it then drops.
    function setGovernor(address governor_) external {
        if (msg.sender != admin) revert NotAuthorized(msg.sender);
        if (governor_ == address(0)) revert ZeroAddress();
        if (governor != address(0)) revert GovernorAlreadySet();
        governor = governor_;
        admin = address(0);
        emit GovernorUpdated(governor_);
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
