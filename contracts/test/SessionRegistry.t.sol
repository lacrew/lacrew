// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SessionRegistry} from "../src/SessionRegistry.sol";
import {OrgRegistry} from "../src/OrgRegistry.sol";
import {IOrgRegistry} from "../src/interfaces/IOrgRegistry.sol";

contract SessionRegistryTest is Test {
    address internal root = makeAddr("root");
    address internal worker = makeAddr("worker");
    address internal key = makeAddr("sessionKey");
    address internal target = makeAddr("target");
    SessionRegistry internal registry;
    OrgRegistry internal org;

    /// @dev Resolved in setUp: reading it inline would consume the next vm.prank.
    uint256 internal allScopes;
    function setUp() public {
        org = new OrgRegistry(root);
        vm.startPrank(root);
        org.addNode(worker, IOrgRegistry.NodeKind.WorkerAgent, root);
        vm.stopPrank();
        registry = new SessionRegistry(root, address(org));
        vm.warp(1_700_000_000);
        allScopes = registry.SCOPE_ALL();
    }

    function test_issueAndValidate() public {
        uint256 scopes = registry.SCOPE_SPEND_WHITELIST();
        uint256 maxValue = 200e6;
        vm.prank(root);
        uint256 id = registry.issue(
            worker, key, uint64(block.timestamp + 1 hours), scopes, maxValue, target
        );

        assertTrue(registry.isValid(id));
        assertTrue(registry.isKeyValid(worker, key));
        (
            address agent,
            address k,
            uint64 exp,
            uint256 sc,
            uint256 mv,
            address at,
            bool revoked,
            bool exists,
            uint32 windowStart,
            uint32 windowEnd
        ) = registry.sessions(id);
        assertEq(agent, worker);
        assertEq(k, key);
        assertEq(exp, uint64(block.timestamp + 1 hours));
        assertEq(sc, scopes);
        assertEq(mv, maxValue);
        assertEq(at, target);
        assertFalse(revoked);
        assertTrue(exists);
        assertEq(windowStart, 0);
        assertEq(windowEnd, 0);

        (bool valid, uint256 lim, address allowed, uint256 sh) = registry.keyLimits(worker, key);
        assertTrue(valid);
        assertEq(lim, maxValue);
        assertEq(allowed, target);
        assertEq(sh, scopes);
    }

    function test_expires() public {
        vm.prank(root);
        uint256 id = registry.issue(
            worker, key, uint64(block.timestamp + 10), allScopes, type(uint256).max, address(0)
        );
        vm.warp(block.timestamp + 11);
        assertFalse(registry.isValid(id));
        assertFalse(registry.isKeyValid(worker, key));
    }

    function test_rootRevokes() public {
        vm.prank(root);
        uint256 id = registry.issue(
            worker, key, uint64(block.timestamp + 1 hours), allScopes, type(uint256).max, address(0)
        );
        vm.prank(root);
        registry.revoke(id);
        assertFalse(registry.isValid(id));
    }

    function test_strangerCannotIssue() public {
        vm.expectRevert(abi.encodeWithSelector(SessionRegistry.NotAuthorized.selector, address(this)));
        registry.issue(
            worker, key, uint64(block.timestamp + 1 hours), allScopes, type(uint256).max, address(0)
        );
    }

    function test_issuerCanIssueAfterSet() public {
        address orch = makeAddr("orch");
        vm.prank(root);
        registry.setIssuer(orch);
        vm.prank(orch);
        uint256 id = registry.issue(
            worker, key, uint64(block.timestamp + 1 hours), allScopes, type(uint256).max, address(0)
        );
        assertTrue(registry.isValid(id));
    }

    function _issuer() internal returns (address orch) {
        orch = makeAddr("orch");
        vm.prank(root);
        registry.setIssuer(orch);
    }

    function test_issuerCannotMintForRoot() public {
        address orch = _issuer();
        vm.prank(orch);
        vm.expectRevert(abi.encodeWithSelector(SessionRegistry.IssuerAgentNotEligible.selector, root));
        registry.issue(
            root, key, uint64(block.timestamp + 1 hours), allScopes, type(uint256).max, address(0)
        );
    }

    function test_issuerCannotMintForPeerHuman() public {
        address peer = makeAddr("peer");
        vm.prank(root);
        org.addNode(peer, IOrgRegistry.NodeKind.HumanRoot, root);
        address orch = _issuer();
        vm.prank(orch);
        vm.expectRevert(abi.encodeWithSelector(SessionRegistry.IssuerAgentNotEligible.selector, peer));
        registry.issue(
            peer, key, uint64(block.timestamp + 1 hours), allScopes, type(uint256).max, address(0)
        );
    }

    function test_issuerCannotMintForUnknownOrInactiveNode() public {
        address orch = _issuer();
        address ghost = makeAddr("ghost");
        vm.prank(orch);
        vm.expectRevert(abi.encodeWithSelector(SessionRegistry.IssuerAgentNotEligible.selector, ghost));
        registry.issue(
            ghost, key, uint64(block.timestamp + 1 hours), allScopes, type(uint256).max, address(0)
        );

        vm.prank(root);
        org.setActive(worker, false);
        vm.prank(orch);
        vm.expectRevert(abi.encodeWithSelector(SessionRegistry.IssuerAgentNotEligible.selector, worker));
        registry.issue(
            worker, key, uint64(block.timestamp + 1 hours), allScopes, type(uint256).max, address(0)
        );
    }

    function test_issuerCanMintForManager() public {
        address mgr = makeAddr("mgr");
        vm.prank(root);
        org.addNode(mgr, IOrgRegistry.NodeKind.ManagerAgent, root);
        address orch = _issuer();
        vm.prank(orch);
        uint256 id = registry.issue(
            mgr, key, uint64(block.timestamp + 1 hours), allScopes, type(uint256).max, address(0)
        );
        assertTrue(registry.isValid(id));
        assertEq(registry.issuedBy(id), orch);
    }

    function test_rootCanStillMintForRoot() public {
        vm.prank(root);
        uint256 id = registry.issue(
            root, key, uint64(block.timestamp + 1 hours), allScopes, type(uint256).max, address(0)
        );
        assertTrue(registry.isValid(id));
        assertEq(registry.issuedBy(id), root);
    }

    function test_issuerCannotRevokeRootIssuedSession() public {
        vm.prank(root);
        uint256 id = registry.issue(
            root, key, uint64(block.timestamp + 1 hours), allScopes, type(uint256).max, address(0)
        );
        address orch = _issuer();
        vm.prank(orch);
        vm.expectRevert(abi.encodeWithSelector(SessionRegistry.NotAuthorized.selector, orch));
        registry.revoke(id);
        assertTrue(registry.isValid(id));
    }

    function test_issuerCanRevokeOwnSessionAndRootCanRevokeAny() public {
        address orch = _issuer();
        vm.prank(orch);
        uint256 id = registry.issue(
            worker, key, uint64(block.timestamp + 1 hours), allScopes, type(uint256).max, address(0)
        );
        vm.prank(orch);
        registry.revoke(id);
        assertFalse(registry.isValid(id));

        vm.prank(orch);
        uint256 id2 = registry.issue(
            worker, key, uint64(block.timestamp + 1 hours), allScopes, type(uint256).max, address(0)
        );
        vm.prank(root);
        registry.revoke(id2);
        assertFalse(registry.isValid(id2));
    }

    function test_issuerCannotSupersedeRootIssuedSession() public {
        vm.prank(root);
        uint256 id = registry.issue(
            worker, key, uint64(block.timestamp + 1 hours), allScopes, type(uint256).max, address(0)
        );
        address orch = _issuer();
        vm.prank(orch);
        vm.expectRevert(abi.encodeWithSelector(SessionRegistry.NotAuthorized.selector, orch));
        registry.issue(
            worker, key, uint64(block.timestamp + 1 hours), allScopes, type(uint256).max, address(0)
        );
        assertTrue(registry.isValid(id));
    }

    function test_constructorRejectsZeroOrgRegistry() public {
        vm.expectRevert(SessionRegistry.ZeroAddress.selector);
        new SessionRegistry(root, address(0));
    }
}
