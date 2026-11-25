// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {GovernanceModule} from "../src/GovernanceModule.sol";

contract ExpiryTarget {
    uint256 public value;

    function set(uint256 v) external {
        value = v;
    }
}

/// @notice A passed proposal is executable for a bounded window, so a stale yes-majority
///         cannot be cashed in after the electorate it was cast under has changed.
contract GovernanceExecutionExpiryTest is Test {
    address internal root = makeAddr("root");

    GovernanceModule internal gov;
    ExpiryTarget internal target;

    function setUp() public {
        gov = new GovernanceModule(root, 2);
        target = new ExpiryTarget();
    }

    function _passedHigh() internal returns (uint256 id, uint256 eta) {
        vm.startPrank(root);
        id = gov.propose(GovernanceModule.Tier.High, address(target), abi.encodeCall(ExpiryTarget.set, (7)));
        gov.vote(id, true);
        vm.stopPrank();
        (,,,,,,,,, eta,) = gov.proposals(id);
    }

    function test_executesInsideTheWindow() public {
        (uint256 id, uint256 eta) = _passedHigh();
        vm.warp(eta + gov.EXECUTION_WINDOW());
        gov.execute(id);
        assertEq(target.value(), 7);
    }

    function test_expiresAfterTheWindow() public {
        (uint256 id, uint256 eta) = _passedHigh();
        vm.warp(eta + gov.EXECUTION_WINDOW() + 1);
        gov.execute(id);
        assertEq(target.value(), 0);
        (,,,,,,,,,, GovernanceModule.ProposalState state) = gov.proposals(id);
        assertEq(uint8(state), uint8(GovernanceModule.ProposalState.Expired));
        vm.expectRevert(abi.encodeWithSelector(GovernanceModule.ProposalNotActive.selector, id));
        gov.execute(id);
    }
}
