// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ITreasurySpender
/// @notice Surface EscalationRouter uses to settle an agent's spend against its allowance.
interface ITreasurySpender {
    /// @notice The single asset this treasury holds and streams.
    function token() external view returns (IERC20);

    /// @notice Push settlement: debit `node` and transfer `amount` to `to`.
    function spendAllowance(address node, uint256 amount, address to) external;

    /// @notice Pull settlement, first half: debit `node` and transfer `amount` to the spender,
    ///         which then lets the target pull what it needs.
    function spendAllowance(address node, uint256 amount) external;

    /// @notice Pull settlement, second half: the spender returns what the target did not pull
    ///         (transferFrom the spender) and `node` gets that much allowance back.
    function refundAllowance(address node, uint256 amount) external;
}
