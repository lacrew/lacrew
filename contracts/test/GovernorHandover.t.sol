// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {OrgRegistry} from "../src/OrgRegistry.sol";
import {SessionRegistry} from "../src/SessionRegistry.sol";
import {Treasury} from "../src/Treasury.sol";
import {EscalationRouter} from "../src/EscalationRouter.sol";
import {EpochStreamer} from "../src/EpochStreamer.sol";
import {WhitelistPolicy} from "../src/policies/WhitelistPolicy.sol";
import {SpendCapPolicy} from "../src/policies/SpendCapPolicy.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {IOrgRegistry} from "../src/interfaces/IOrgRegistry.sol";

interface IGoverned {
    function governor() external view returns (address);
    function pendingGovernor() external view returns (address);
    function setGovernor(address) external;
    function setPendingGovernor(address) external;
    function acceptGovernor() external;
}

/// @notice The two-step governor hand-over shared by every governed contract: the
///         governor names a pending successor, and only that address may accept.
///         Each contract is driven through the same scenario; `_probeData` is one call
///         that only the governor may make, used to show who holds power at each step.
contract GovernorHandoverTest is Test {
    event GovernorUpdated(address indexed governor);
    event PendingGovernorUpdated(address indexed pendingGovernor);

    address internal root = makeAddr("root");
    address internal gov = makeAddr("gov");
    address internal next = makeAddr("next");
    address internal wrong = makeAddr("wrong");
    address internal stranger = makeAddr("stranger");

    uint160 internal nonce = 0x5000;

    OrgRegistry internal registry;
    SessionRegistry internal sessions;
    Treasury internal treasury;
    EscalationRouter internal router;
    EpochStreamer internal streamer;
    WhitelistPolicy internal whitelist;
    SpendCapPolicy internal spendCap;

    function setUp() public {
        // This test contract is the deployer / operator / admin of everything below,
        // and `root` is the org root where a contract takes its root as bootstrap.
        MockUSDC usdc = new MockUSDC();
        registry = new OrgRegistry(root);
        sessions = new SessionRegistry(root, address(registry));
        whitelist = new WhitelistPolicy();
        spendCap = new SpendCapPolicy(100);
        router = new EscalationRouter(address(registry), address(whitelist));
        treasury = new Treasury(address(registry), address(usdc), address(router));
        streamer = new EpochStreamer(address(treasury), address(this), uint64(block.timestamp), 1 days);
    }

    function _probeData(address c) internal returns (bytes memory) {
        nonce++;
        address any = address(nonce);
        if (c == address(registry)) {
            return abi.encodeCall(OrgRegistry.addNode, (any, IOrgRegistry.NodeKind.ManagerAgent, root));
        }
        if (c == address(sessions)) return abi.encodeCall(SessionRegistry.setIssuer, (any));
        if (c == address(treasury)) return abi.encodeCall(Treasury.setSpender, (any));
        if (c == address(router)) return abi.encodeCall(EscalationRouter.setIntentTtl, (uint64(2 hours)));
        if (c == address(streamer)) return abi.encodeCall(EpochStreamer.setGrant, (any, 1));
        if (c == address(whitelist)) return abi.encodeCall(WhitelistPolicy.setAllowed, (any, true));
        return abi.encodeCall(SpendCapPolicy.setAgentCap, (any, 7));
    }

    function _can(address c, address caller) internal returns (bool ok) {
        bytes memory data = _probeData(c);
        vm.prank(caller);
        (ok,) = c.call(data);
    }

    /// @dev The party that makes the one-time bind, by contract.
    function _binder(address c) internal view returns (address) {
        if (c == address(registry) || c == address(sessions)) return root;
        return address(this);
    }

    function _all() internal view returns (address[7] memory a) {
        a = [
            address(registry),
            address(sessions),
            address(treasury),
            address(router),
            address(streamer),
            address(whitelist),
            address(spendCap)
        ];
    }

    function _bind(address c) internal {
        vm.prank(_binder(c));
        IGoverned(c).setGovernor(gov);
    }

    function test_bindIsOneTime() public {
        address[7] memory all = _all();
        for (uint256 i = 0; i < all.length; i++) {
            _bind(all[i]);
            assertEq(IGoverned(all[i]).governor(), gov);
            // Neither the binder nor the governor can bind again: a hand-over is two steps.
            for (uint256 j = 0; j < 2; j++) {
                vm.prank(j == 0 ? _binder(all[i]) : gov);
                (bool ok,) = all[i].call(abi.encodeCall(IGoverned.setGovernor, (next)));
                assertFalse(ok, "second bind must revert");
            }
            assertEq(IGoverned(all[i]).governor(), gov);
        }
    }

    function test_onlyGovernorNamesPending() public {
        address[7] memory all = _all();
        for (uint256 i = 0; i < all.length; i++) {
            IGoverned c = IGoverned(all[i]);
            // Before any governor is bound nobody can name a successor, not even the binder.
            vm.prank(_binder(all[i]));
            vm.expectRevert();
            c.setPendingGovernor(next);

            _bind(all[i]);
            address[3] memory outsiders = [_binder(all[i]), stranger, next];
            for (uint256 j = 0; j < outsiders.length; j++) {
                vm.prank(outsiders[j]);
                vm.expectRevert();
                c.setPendingGovernor(next);
            }
            assertEq(c.pendingGovernor(), address(0));
        }
    }

    function test_strangerCannotAccept() public {
        address[7] memory all = _all();
        for (uint256 i = 0; i < all.length; i++) {
            IGoverned c = IGoverned(all[i]);
            _bind(all[i]);
            // Nothing pending: nobody can accept.
            vm.prank(stranger);
            vm.expectRevert();
            c.acceptGovernor();

            vm.prank(gov);
            c.setPendingGovernor(next);
            address[3] memory outsiders = [stranger, gov, _binder(all[i])];
            for (uint256 j = 0; j < outsiders.length; j++) {
                vm.prank(outsiders[j]);
                vm.expectRevert();
                c.acceptGovernor();
            }
            assertEq(c.governor(), gov);
            assertEq(c.pendingGovernor(), next);
        }
    }

    function test_oldGovernorKeepsPowerUntilAcceptance() public {
        address[7] memory all = _all();
        for (uint256 i = 0; i < all.length; i++) {
            IGoverned c = IGoverned(all[i]);
            _bind(all[i]);
            vm.prank(gov);
            c.setPendingGovernor(next);

            assertTrue(_can(all[i], gov), "old governor keeps its powers");
            assertFalse(_can(all[i], next), "pending has none before accepting");

            vm.prank(next);
            c.acceptGovernor();
            assertEq(c.governor(), next);
            assertEq(c.pendingGovernor(), address(0));

            assertTrue(_can(all[i], next), "new governor holds the powers");
            assertFalse(_can(all[i], gov), "old governor lost them");
            // The pending slot is cleared, so accepting twice fails.
            vm.prank(next);
            vm.expectRevert();
            c.acceptGovernor();
        }
    }

    function test_wrongHandoverCanBeCorrected() public {
        address[7] memory all = _all();
        for (uint256 i = 0; i < all.length; i++) {
            IGoverned c = IGoverned(all[i]);
            _bind(all[i]);
            vm.prank(gov);
            c.setPendingGovernor(wrong);
            // Naming another address replaces the first, which can no longer accept.
            vm.prank(gov);
            c.setPendingGovernor(next);
            assertEq(c.pendingGovernor(), next);
            vm.prank(wrong);
            vm.expectRevert();
            c.acceptGovernor();
            assertTrue(_can(all[i], gov));
            vm.prank(next);
            c.acceptGovernor();
            assertEq(c.governor(), next);
        }
    }

    function test_governorCanCancelPending() public {
        address[7] memory all = _all();
        for (uint256 i = 0; i < all.length; i++) {
            IGoverned c = IGoverned(all[i]);
            _bind(all[i]);
            vm.prank(gov);
            c.setPendingGovernor(wrong);
            vm.prank(gov);
            c.setPendingGovernor(address(0));
            vm.prank(wrong);
            vm.expectRevert();
            c.acceptGovernor();
            assertEq(c.governor(), gov);
        }
    }

    function test_handoverEmitsBothSteps() public {
        address[7] memory all = _all();
        for (uint256 i = 0; i < all.length; i++) {
            IGoverned c = IGoverned(all[i]);
            vm.expectEmit(true, false, false, false, all[i]);
            emit GovernorUpdated(gov);
            _bind(all[i]);

            vm.expectEmit(true, false, false, false, all[i]);
            emit PendingGovernorUpdated(next);
            vm.prank(gov);
            c.setPendingGovernor(next);

            vm.expectEmit(true, false, false, false, all[i]);
            emit GovernorUpdated(next);
            vm.prank(next);
            c.acceptGovernor();
        }
    }

    function test_zeroGovernorBindReverts() public {
        address[7] memory all = _all();
        for (uint256 i = 0; i < all.length; i++) {
            vm.prank(_binder(all[i]));
            vm.expectRevert();
            IGoverned(all[i]).setGovernor(address(0));
        }
    }

    function test_strangerCannotBind() public {
        address[7] memory all = _all();
        for (uint256 i = 0; i < all.length; i++) {
            vm.prank(stranger);
            vm.expectRevert();
            IGoverned(all[i]).setGovernor(stranger);
        }
    }
}
