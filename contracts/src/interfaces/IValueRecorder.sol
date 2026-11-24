// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/// @title IValueRecorder
/// @notice Optional hook EscalationRouter calls after an action settles with value,
///         so a module can budget what an agent (and an agent per payee) spends.
interface IValueRecorder {
    function recordValue(address agent, address target, uint256 value) external;
}
