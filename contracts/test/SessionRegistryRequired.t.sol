// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {OrgRegistry} from "../src/OrgRegistry.sol";
import {EscalationRouter} from "../src/EscalationRouter.sol";
import {SessionRegistry} from "../src/SessionRegistry.sol";
import {SpendCapPolicy} from "../src/policies/SpendCapPolicy.sol";
import {IOrgRegistry} from "../src/interfaces/IOrgRegistry.sol";

/// The router never falls back to "no session check": until a SessionRegistry is wired only
/// the agent itself can propose for itself, and the registry can be replaced but not cleared.
contract SessionRegistryRequiredTest is Test {
    address internal root = makeAddr("root");
    address internal worker = makeAddr("worker");
    address internal payee = makeAddr("payee");
    address internal stranger = makeAddr("stranger");

    OrgRegistry internal registry;
    EscalationRouter internal router;

    function setUp() public {
        registry = new OrgRegistry(root);
        vm.prank(root);
        registry.addNode(worker, IOrgRegistry.NodeKind.WorkerAgent, root);
        router = new EscalationRouter(address(registry), address(new SpendCapPolicy(100 ether)));
    }

    function test_strangerCannotProposeForAgentWhileNoRegistryIsSet() public {
        vm.prank(stranger);
        vm.expectRevert(EscalationRouter.SessionRegistryNotSet.selector);
        router.propose(worker, payee, 1 ether, "");
    }

    function test_agentCanProposeForItselfWhileNoRegistryIsSet() public {
        vm.prank(worker);
        router.propose(worker, payee, 1 ether, "");
    }

    function test_setSessionRegistryRejectsZero() public {
        vm.expectRevert(EscalationRouter.ZeroAddress.selector);
        router.setSessionRegistry(address(0));
    }

    function test_registryCannotBeClearedOnceSet() public {
        router.setSessionRegistry(address(new SessionRegistry(root, address(registry))));
        address wired = address(router.sessionRegistry());

        vm.expectRevert(EscalationRouter.ZeroAddress.selector);
        router.setSessionRegistry(address(0));
        assertEq(address(router.sessionRegistry()), wired);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(EscalationRouter.InvalidSession.selector, worker, stranger));
        router.propose(worker, payee, 1 ether, "");
    }
}
