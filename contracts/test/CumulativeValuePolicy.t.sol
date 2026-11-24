// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {OrgRegistry} from "../src/OrgRegistry.sol";
import {EscalationRouter} from "../src/EscalationRouter.sol";
import {SpendCapPolicy} from "../src/policies/SpendCapPolicy.sol";
import {WhitelistPolicy} from "../src/policies/WhitelistPolicy.sol";
import {CumulativeValuePolicy} from "../src/policies/CumulativeValuePolicy.sol";
import {PolicyStack} from "../src/policies/PolicyStack.sol";
import {IOrgRegistry} from "../src/interfaces/IOrgRegistry.sol";
import {IPolicyModule, Verdict} from "../src/interfaces/IPolicyModule.sol";

/// Unit behaviour of the module on its own, recorded by the deployer.
contract CumulativeValuePolicyTest is Test {
    address internal agent = makeAddr("agent");
    address internal payeeA = makeAddr("payeeA");
    address internal payeeB = makeAddr("payeeB");

    CumulativeValuePolicy internal policy;

    function setUp() public {
        vm.warp(1_000_000);
        // 10 ether per agent per hour, 4 ether per payee per hour.
        policy = new CumulativeValuePolicy(10 ether, 4 ether, 1 hours);
    }

    function _check(address target, uint256 value) internal view returns (Verdict) {
        return policy.check(agent, target, value, "");
    }

    function test_allowsUpToTheBudgetThenEscalates() public {
        assertEq(uint8(_check(payeeA, 4 ether)), uint8(Verdict.ALLOW));
        policy.recordValue(agent, payeeA, 4 ether);
        policy.recordValue(agent, payeeB, 4 ether);
        assertEq(policy.spentOf(agent), 8 ether);

        address payeeC = makeAddr("payeeC");
        // Exactly reaching the budget is allowed; one wei over escalates.
        assertEq(uint8(_check(payeeC, 2 ether)), uint8(Verdict.ALLOW));
        assertEq(uint8(_check(payeeC, 2 ether + 1)), uint8(Verdict.ESCALATE));
    }

    function test_perTargetBudgetEscalatesSplitsToOnePayee() public {
        policy.recordValue(agent, payeeA, 3 ether);
        assertEq(policy.spentTo(agent, payeeA), 3 ether);
        // Agent budget has 7 left, but payee A has only 1.
        assertEq(uint8(_check(payeeA, 1 ether + 1)), uint8(Verdict.ESCALATE));
        assertEq(uint8(_check(payeeB, 4 ether)), uint8(Verdict.ALLOW));
    }

    function test_singleSpendOverBudgetEscalates() public view {
        assertEq(uint8(policy.check(agent, payeeA, 11 ether, "")), uint8(Verdict.ESCALATE));
    }

    function test_zeroValueAlwaysAllowed() public {
        policy.recordValue(agent, payeeA, 10 ether);
        assertEq(uint8(_check(payeeA, 0)), uint8(Verdict.ALLOW));
    }

    function test_hugeValueEscalatesWithoutOverflow() public {
        policy.recordValue(agent, payeeA, 1 ether);
        assertEq(uint8(_check(payeeA, type(uint256).max)), uint8(Verdict.ESCALATE));
    }

    function test_windowLapsesAndReopens() public {
        policy.recordValue(agent, payeeA, 4 ether);
        uint256 start = block.timestamp;
        vm.warp(start + 1 hours - 1);
        assertEq(policy.spentOf(agent), 4 ether);
        vm.warp(start + 1 hours);
        assertEq(policy.spentOf(agent), 0);
        assertEq(policy.spentTo(agent, payeeA), 0);

        policy.recordValue(agent, payeeA, 1 ether);
        (uint64 windowStart, uint192 spent) = policy.agentWindows(agent);
        assertEq(windowStart, start + 1 hours);
        assertEq(spent, 1 ether);
    }

    function test_perTargetOffSkipsPayeeTracking() public {
        CumulativeValuePolicy agentOnly = new CumulativeValuePolicy(10 ether, 0, 1 hours);
        agentOnly.recordValue(agent, payeeA, 9 ether);
        assertEq(agentOnly.spentTo(agent, payeeA), 0);
        assertEq(uint8(agentOnly.check(agent, payeeA, 1 ether, "")), uint8(Verdict.ALLOW));
        assertEq(uint8(agentOnly.check(agent, payeeA, 1 ether + 1, "")), uint8(Verdict.ESCALATE));
    }

    function test_recordSaturatesInsteadOfReverting() public {
        policy.recordValue(agent, payeeA, type(uint256).max);
        policy.recordValue(agent, payeeA, type(uint256).max);
        assertEq(policy.spentOf(agent), type(uint192).max);
    }

    function test_zeroWindowRejected() public {
        vm.expectRevert(CumulativeValuePolicy.ZeroWindow.selector);
        new CumulativeValuePolicy(1, 0, 0);
    }

    function test_recorderBoundOnceByDeployer() public {
        address router = makeAddr("router");
        address stranger = makeAddr("stranger");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(CumulativeValuePolicy.NotAuthorized.selector, stranger));
        policy.setRecorder(stranger);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(CumulativeValuePolicy.NotRecorder.selector, stranger));
        policy.recordValue(agent, payeeA, 1);

        vm.expectRevert(CumulativeValuePolicy.ZeroAddress.selector);
        policy.setRecorder(address(0));

        policy.setRecorder(router);
        vm.expectRevert(CumulativeValuePolicy.RecorderLocked.selector);
        policy.setRecorder(stranger);

        // Once bound, even the deployer can no longer record.
        vm.expectRevert(abi.encodeWithSelector(CumulativeValuePolicy.NotRecorder.selector, address(this)));
        policy.recordValue(agent, payeeA, 1);

        vm.prank(router);
        policy.recordValue(agent, payeeA, 1);
        assertEq(policy.spentOf(agent), 1);
    }

    function testFuzz_settledWithoutEscalationNeverExceedsBudget(uint96[8] memory spends) public {
        uint256 settled;
        for (uint256 i = 0; i < spends.length; i++) {
            uint256 v = uint256(spends[i]) % 5 ether;
            if (policy.check(agent, payeeA, v, "") == Verdict.ALLOW) {
                policy.recordValue(agent, payeeA, v);
                settled += v;
            }
        }
        assertLe(settled, 4 ether);
    }
}

/// End to end through the router: splitting a spend no longer settles it.
contract CumulativeValueRouterTest is Test {
    address internal root = makeAddr("root");
    address internal manager = makeAddr("manager");
    address internal worker = makeAddr("worker");
    address internal other = makeAddr("other");
    address internal payee = makeAddr("payee");
    address internal payee2 = makeAddr("payee2");

    OrgRegistry internal registry;
    EscalationRouter internal router;
    CumulativeValuePolicy internal globalBudget;
    CumulativeValuePolicy internal customBudget;

    function setUp() public {
        vm.warp(1_000_000);
        registry = new OrgRegistry(root);
        vm.prank(root);
        registry.addNode(manager, IOrgRegistry.NodeKind.ManagerAgent, root);
        vm.prank(root);
        registry.addNode(worker, IOrgRegistry.NodeKind.WorkerAgent, manager);
        vm.prank(root);
        registry.addNode(other, IOrgRegistry.NodeKind.WorkerAgent, manager);

        WhitelistPolicy whitelist = new WhitelistPolicy();
        whitelist.setAllowed(payee, true);
        whitelist.setAllowed(payee2, true);
        // Per-call cap of 5: every split below passes it on its own.
        SpendCapPolicy spendCap = new SpendCapPolicy(5 ether);
        globalBudget = new CumulativeValuePolicy(10 ether, 0, 1 days);
        customBudget = new CumulativeValuePolicy(100 ether, 3 ether, 1 days);

        IPolicyModule[] memory defMods = new IPolicyModule[](3);
        defMods[0] = whitelist;
        defMods[1] = spendCap;
        defMods[2] = globalBudget;
        PolicyStack defaultStack = new PolicyStack(defMods);

        IPolicyModule[] memory customMods = new IPolicyModule[](3);
        customMods[0] = whitelist;
        customMods[1] = spendCap;
        customMods[2] = customBudget;
        PolicyStack customStack = new PolicyStack(customMods);

        router = new EscalationRouter(address(registry), address(defaultStack));
        router.setValueRecorder(address(globalBudget));
        globalBudget.setRecorder(address(router));
        customBudget.setRecorder(address(router));

        router.setNodePolicy(other, address(customStack));
        router.setNodeValueRecorder(other, address(customBudget));
    }

    function test_splitSpendEscalatesOnceTheWindowBudgetIsUsed() public {
        (, Verdict v0) = router.propose(worker, payee, 5 ether, "");
        (, Verdict v1) = router.propose(worker, payee, 5 ether, "");
        assertEq(uint8(v0), uint8(Verdict.ALLOW));
        assertEq(uint8(v1), uint8(Verdict.ALLOW));
        assertEq(globalBudget.spentOf(worker), 10 ether);

        (uint256 intentId, Verdict v2) = router.propose(worker, payee, 1, "");
        assertEq(uint8(v2), uint8(Verdict.ESCALATE));
        assertGt(intentId, 0);
        // An escalated intent spent nothing yet.
        assertEq(globalBudget.spentOf(worker), 10 ether);
    }

    function test_approvedOverageIsCharged() public {
        router.propose(worker, payee, 5 ether, "");
        router.propose(worker, payee, 5 ether, "");
        (uint256 intentId,) = router.propose(worker, payee, 2 ether, "");
        // The manager is under the same default stack and over nothing of its own.
        vm.prank(manager);
        router.resolve(intentId, true);
        assertEq(globalBudget.spentOf(worker), 12 ether);
    }

    function test_windowLapseReopensTheBudget() public {
        router.propose(worker, payee, 5 ether, "");
        router.propose(worker, payee, 5 ether, "");
        vm.warp(block.timestamp + 1 days);
        (, Verdict v) = router.propose(worker, payee, 5 ether, "");
        assertEq(uint8(v), uint8(Verdict.ALLOW));
    }

    function test_nodeRecorderChargesItsOwnModule() public {
        (, Verdict v0) = router.propose(other, payee, 3 ether, "");
        assertEq(uint8(v0), uint8(Verdict.ALLOW));
        assertEq(customBudget.spentTo(other, payee), 3 ether);
        assertEq(globalBudget.spentOf(other), 0);

        // Payee budget is 3: the next split to the same payee escalates, another payee does not.
        (, Verdict v1) = router.propose(other, payee, 1, "");
        assertEq(uint8(v1), uint8(Verdict.ESCALATE));
        (, Verdict v2) = router.propose(other, payee2, 3 ether, "");
        assertEq(uint8(v2), uint8(Verdict.ALLOW));
    }

    function test_valueRecordersAreProtectedTargets() public {
        vm.expectRevert(
            abi.encodeWithSelector(EscalationRouter.ProtectedTarget.selector, address(globalBudget))
        );
        router.propose(worker, address(globalBudget), 0, "");
        vm.expectRevert(
            abi.encodeWithSelector(EscalationRouter.ProtectedTarget.selector, address(customBudget))
        );
        router.propose(other, address(customBudget), 0, "");
    }

    function test_valueRecorderSettersAreGoverned() public {
        address stranger = makeAddr("stranger");
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(EscalationRouter.NotAuthorized.selector, stranger));
        router.setValueRecorder(stranger);
        vm.expectRevert(abi.encodeWithSelector(EscalationRouter.NotAuthorized.selector, stranger));
        router.setNodeValueRecorder(worker, stranger);
        vm.stopPrank();

        vm.expectRevert(EscalationRouter.ZeroAddress.selector);
        router.setNodeValueRecorder(address(0), address(customBudget));

        // Clearing the node binding falls back to the global recorder.
        router.setNodeValueRecorder(other, address(0));
        assertEq(address(router.valueRecorderOf(other)), address(0));
    }
}
