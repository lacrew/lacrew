// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISettlementContext} from "../../src/interfaces/ISettlementContext.sol";

/// @dev Stands in for EscalationRouter in unit tests: approves a target for the payment,
///      then calls it while reporting that payment through `currentSettlement`. Reverts from the target bubble
///      up so tests can assert on them.
contract MockSettlementRouter is ISettlementContext {
    address private transient _target;
    uint256 private transient _paid;

    function currentSettlement() external view returns (address target, uint256 paid) {
        return (_target, _paid);
    }

    /// Approves `target` to pull `amount` of `token` (held by this mock), then calls it.
    function settle(IERC20 token, address target, uint256 amount, bytes calldata data) external {
        token.approve(target, amount);
        _call(target, target, amount, data);
        token.approve(target, 0);
    }

    /// Calls `target` while reporting `reportedTarget` / `reportedPaid`, approving nothing.
    function settleReporting(
        address target,
        address reportedTarget,
        uint256 reportedPaid,
        bytes calldata data
    ) external {
        _call(target, reportedTarget, reportedPaid, data);
    }

    function _call(address target, address reportedTarget, uint256 reportedPaid, bytes calldata data)
        private
    {
        _target = reportedTarget;
        _paid = reportedPaid;
        (bool ok, bytes memory ret) = target.call(data);
        _target = address(0);
        _paid = 0;
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}
