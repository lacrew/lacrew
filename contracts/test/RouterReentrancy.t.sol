// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SessionWiring} from "./utils/SessionWiring.sol";
import {OrgRegistry} from "../src/OrgRegistry.sol";
import {EscalationRouter} from "../src/EscalationRouter.sol";
import {RateLimitPolicy} from "../src/policies/RateLimitPolicy.sol";
import {IOrgRegistry} from "../src/interfaces/IOrgRegistry.sol";

/// A target that calls back into the router while its action is executing.
contract ReentrantTarget {
    EscalationRouter public router;
    RateLimitPolicy public rate;
    address public agent;
    uint32 public countSeenInCallback;
    bool public reenterSucceeded;

    constructor(EscalationRouter router_, RateLimitPolicy rate_, address agent_) {
        router = router_;
        rate = rate_;
        agent = agent_;
    }

    fallback() external {
        (, countSeenInCallback) = rate.windows(agent);
        try router.propose(agent, address(this), 0, hex"01") {
            reenterSucceeded = true;
        } catch {}
    }
}

contract RouterReentrancyTest is SessionWiring {
    address internal root = makeAddr("root");
    address internal worker = makeAddr("worker");

    EscalationRouter internal router;
    RateLimitPolicy internal rate;
    ReentrantTarget internal target;

    function setUp() public {
        OrgRegistry registry = new OrgRegistry(root);
        vm.prank(root);
        registry.addNode(worker, IOrgRegistry.NodeKind.WorkerAgent, root);

        rate = new RateLimitPolicy(1, 1 hours);
        router = new EscalationRouter(address(registry), address(rate));
        {
            address[] memory agents_ = new address[](1);
            agents_[0] = worker;
            _wireSessions(router, registry, root, agents_);
        }
        router.setRateRecorder(address(rate));
        rate.setRecorder(address(router));
        target = new ReentrantTarget(router, rate, worker);
    }

    function test_actionIsCountedBeforeTheExternalCall() public {
        router.propose(worker, address(target), 0, hex"01");
        assertEq(target.countSeenInCallback(), 1);
    }

    function test_nestedProposeIsRefused() public {
        router.propose(worker, address(target), 0, hex"01");
        assertFalse(target.reenterSucceeded());
        (, uint32 count) = rate.windows(worker);
        assertEq(count, 1);
    }
}
