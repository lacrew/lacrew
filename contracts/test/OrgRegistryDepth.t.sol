// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {OrgRegistry} from "../src/OrgRegistry.sol";
import {EscalationRouter} from "../src/EscalationRouter.sol";
import {SpendCapPolicy} from "../src/policies/SpendCapPolicy.sol";
import {PolicyStack} from "../src/policies/PolicyStack.sol";
import {IOrgRegistry} from "../src/interfaces/IOrgRegistry.sol";
import {IPolicyModule, Verdict} from "../src/interfaces/IPolicyModule.sol";

/// @notice What a tree deeper than MAX_DEPTH does to the registry and the router.
/// @dev Who may call `reparent`: only `root`, or the governor once one is bound
///      (`_authorize`). Not an agent, not an arbitrary caller.
contract OrgRegistryDepthTest is Test {
    address internal root = makeAddr("root");
    address internal mgr = makeAddr("mgr");
    address internal mid = makeAddr("mid");
    address internal leaf = makeAddr("leaf");
    address internal target = makeAddr("target");

    OrgRegistry internal registry;
    uint256 internal max;

    function setUp() public {
        registry = new OrgRegistry(root);
        max = registry.MAX_DEPTH();
    }

    function _seat(uint256 i) internal pure returns (address) {
        return address(uint160(0x3000 + i));
    }

    /// @dev seat(1) .. seat(n) chained under root; seat(i) sits at depth i.
    function _chain(uint256 n) internal {
        vm.startPrank(root);
        for (uint256 i = 1; i <= n; i++) {
            registry.addNode(_seat(i), IOrgRegistry.NodeKind.ManagerAgent, i == 1 ? root : _seat(i - 1));
        }
        vm.stopPrank();
    }

    /// @dev mgr -> mid -> leaf.
    function _subtree() internal {
        vm.startPrank(root);
        registry.addNode(mgr, IOrgRegistry.NodeKind.ManagerAgent, root);
        registry.addNode(mid, IOrgRegistry.NodeKind.ManagerAgent, mgr);
        registry.addNode(leaf, IOrgRegistry.NodeKind.WorkerAgent, mid);
        vm.stopPrank();
    }

    function _depthOf(address a) internal view returns (uint256 d) {
        address c = registry.getNode(a).parent;
        while (c != address(0)) {
            d++;
            c = registry.getNode(c).parent;
        }
    }

    // ---- the cap ----

    function test_reparentRefusesAMoveThatPassesMaxDepth() public {
        _chain(max);
        _subtree();
        // mgr under seat(32) would sit at 33, leaf at 35.
        vm.prank(root);
        vm.expectRevert(abi.encodeWithSelector(OrgRegistry.MaxDepthExceeded.selector, mgr));
        registry.reparent(mgr, _seat(max));
        assertEq(registry.getNode(mgr).parent, root);
    }

    function test_reparentRefusesWhenOnlyTheSubtreeTipPassesTheCap() public {
        _chain(max - 1);
        _subtree();
        // mgr at 32 is fine on its own, but leaf (two below) would be 34.
        vm.prank(root);
        vm.expectRevert(abi.encodeWithSelector(OrgRegistry.MaxDepthExceeded.selector, mgr));
        registry.reparent(mgr, _seat(max - 1));
    }

    function test_reparentAllowsAMoveThatLandsExactlyOnMaxDepth() public {
        _chain(max - 2);
        _subtree();
        // seat(30) is depth 30: mgr 31, mid 32, leaf 33 is one too deep.
        vm.prank(root);
        vm.expectRevert(abi.encodeWithSelector(OrgRegistry.MaxDepthExceeded.selector, mgr));
        registry.reparent(mgr, _seat(max - 2));
        // One level up: mgr 30, mid 31, leaf 32 == MAX_DEPTH.
        vm.prank(root);
        registry.reparent(mgr, _seat(max - 3));
        assertEq(_depthOf(leaf), max);
        // addNode refuses a level deeper, so the two caps agree.
        vm.prank(root);
        vm.expectRevert(abi.encodeWithSelector(OrgRegistry.MaxDepthExceeded.selector, target));
        registry.addNode(target, IOrgRegistry.NodeKind.WorkerAgent, leaf);
    }

    function test_reparentOfASingleSeatIntoTheDeepestSeatIsRefused() public {
        _chain(max);
        vm.prank(root);
        registry.addNode(leaf, IOrgRegistry.NodeKind.WorkerAgent, root);
        vm.prank(root);
        vm.expectRevert(abi.encodeWithSelector(OrgRegistry.MaxDepthExceeded.selector, leaf));
        registry.reparent(leaf, _seat(max));
        vm.prank(root);
        registry.reparent(leaf, _seat(max - 1));
        assertEq(_depthOf(leaf), max);
    }

    function test_reparentUpTheTreeAlwaysWorks() public {
        _chain(max);
        vm.prank(root);
        registry.reparent(_seat(max - 5), root);
        assertEq(_depthOf(_seat(max)), 6);
    }

    function test_noOpReparentOfADeepSeatDoesNotRevert() public {
        _chain(max);
        vm.prank(root);
        registry.reparent(_seat(max), _seat(max - 1));
    }

    function test_onlyRootOrGovernorMayReparent() public {
        _subtree();
        vm.expectRevert(abi.encodeWithSelector(OrgRegistry.NotAuthorized.selector, address(this)));
        registry.reparent(leaf, root);
        vm.prank(root);
        registry.setGovernor(address(this));
        vm.prank(root);
        vm.expectRevert(abi.encodeWithSelector(OrgRegistry.NotAuthorized.selector, root));
        registry.reparent(leaf, root);
        registry.reparent(leaf, root);
    }

    // ---- gas ----

    /// @dev Worst case for the cap's walk: a MAX_DEPTH-tall subtree with 20 reports on
    ///      every level, moved between two shallow parents.
    function test_worstCaseReparentGas() public {
        vm.startPrank(root);
        registry.addNode(mgr, IOrgRegistry.NodeKind.ManagerAgent, root);
        address prev = mgr;
        for (uint256 i = 0; i < max - 3; i++) {
            address n = address(uint160(0x5000 + i));
            registry.addNode(n, IOrgRegistry.NodeKind.ManagerAgent, prev);
            for (uint256 j = 0; j < 20; j++) {
                registry.addNode(
                    address(uint160(0x100000 + i * 100 + j)), IOrgRegistry.NodeKind.WorkerAgent, n
                );
            }
            prev = n;
        }
        address other = makeAddr("other");
        registry.addNode(other, IOrgRegistry.NodeKind.ManagerAgent, root);
        uint256 g = gasleft();
        registry.reparent(mgr, other);
        uint256 used = g - gasleft();
        vm.stopPrank();
        emit log_named_uint("reparent gas, full-height 20-wide subtree", used);
        assertLt(used, 4_000_000);
    }
}
