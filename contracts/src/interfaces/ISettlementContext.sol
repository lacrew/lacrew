// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/// @title ISettlementContext
/// @notice What a settling router made available for the call it is making right now.
/// @dev A target the router pays and then calls can read this from inside that call to
///      learn exactly what *this* action paid, instead of inferring it from its own
///      token balance (which also holds stray transfers). The router approves the target for
///      `paid` and the target pulls from it. Outside an action, both values are zero.
interface ISettlementContext {
    /// @return target The address the in-flight action calls.
    /// @return paid Tokens treasury paid out of the agent's allowance for this action, and which the router approved `target` to pull.
    function currentSettlement() external view returns (address target, uint256 paid);
}
