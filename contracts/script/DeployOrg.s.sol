// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {OrgRegistry} from "../src/OrgRegistry.sol";
import {Treasury} from "../src/Treasury.sol";
import {EscalationRouter} from "../src/EscalationRouter.sol";
import {GovernanceModule} from "../src/GovernanceModule.sol";
import {EpochStreamer} from "../src/EpochStreamer.sol";
import {SessionRegistry} from "../src/SessionRegistry.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {SpendCapPolicy} from "../src/policies/SpendCapPolicy.sol";
import {WhitelistPolicy} from "../src/policies/WhitelistPolicy.sol";
import {RateLimitPolicy} from "../src/policies/RateLimitPolicy.sol";
import {TimeWindowPolicy} from "../src/policies/TimeWindowPolicy.sol";
import {PolicyStack} from "../src/policies/PolicyStack.sol";
import {IPolicyModule} from "../src/interfaces/IPolicyModule.sol";
import {DeployConfig} from "./DeployConfig.sol";

/// @notice Release deploy of one org stack. No demo agents, no x402 target, no funding.
/// @dev Env: `HUMAN_ROOT` (required off Anvil), `ASSET` (required unless `DEPLOY_MOCK_ASSET`
///      on a mock chain), `DEFAULT_SPEND_CAP` (asset base units, required),
///      `EPOCH_DURATION` (seconds, default 1 day), `ROOT_VOTE_POWER` (default 2).
///      The broadcaster must be `HUMAN_ROOT`: `OrgRegistry` and `SessionRegistry` only let
///      the root bind their governor. Rotate the root to a Safe afterwards with the High-tier
///      `rotateRoot` proposal. Every wiring step and every post-condition runs in this one
///      script, so a half-wired deploy reverts and nothing is published.
contract DeployOrg is Script {
    error RootRequired();
    error BroadcasterNotRoot(address broadcaster, address root);
    error SpendCapRequired();
    error PostConditionFailed(string what);

    struct Stack {
        address asset;
        OrgRegistry registry;
        GovernanceModule gov;
        Treasury treasury;
        EscalationRouter router;
        EpochStreamer streamer;
        SessionRegistry sessions;
        SpendCapPolicy spendCap;
        WhitelistPolicy whitelist;
        RateLimitPolicy rateLimit;
        TimeWindowPolicy timeWindow;
        PolicyStack policyStack;
    }

    struct Config {
        address root;
        address asset;
        bool mockAsset;
        uint256 defaultCap;
        uint256 epochDuration;
        uint256 rootVotePower;
    }

    function run() external returns (Stack memory) {
        address root = vm.envOr("HUMAN_ROOT", block.chainid == DeployConfig.ANVIL ? msg.sender : address(0));
        if (root != address(0) && msg.sender != root) revert BroadcasterNotRoot(msg.sender, root);
        return execute(
            Config({
                root: root,
                asset: vm.envOr("ASSET", address(0)),
                mockAsset: vm.envOr("DEPLOY_MOCK_ASSET", false),
                defaultCap: vm.envOr("DEFAULT_SPEND_CAP", uint256(0)),
                epochDuration: vm.envOr("EPOCH_DURATION", uint256(1 days)),
                rootVotePower: vm.envOr("ROOT_VOTE_POWER", uint256(2))
            })
        );
    }

    function execute(Config memory c) public returns (Stack memory s) {
        if (c.root == address(0)) revert RootRequired();
        if (c.defaultCap == 0) revert SpendCapRequired();

        if (c.mockAsset) DeployConfig.requireMockAllowed(block.chainid);
        else DeployConfig.requireRealAsset(block.chainid, c.asset);

        vm.startBroadcast();
        if (c.mockAsset) c.asset = address(new MockUSDC());
        s = _deploy(c);
        vm.stopBroadcast();

        verify(s, c.root);
        _log(s);
    }

    function _deploy(Config memory c) private returns (Stack memory s) {
        address root = c.root;
        address asset = c.asset;
        s.asset = asset;
        s.registry = new OrgRegistry(root);
        s.gov = new GovernanceModule(root, c.rootVotePower);

        s.whitelist = new WhitelistPolicy();
        s.spendCap = new SpendCapPolicy(c.defaultCap);
        s.rateLimit = new RateLimitPolicy(10, 1 hours);
        s.timeWindow = new TimeWindowPolicy(0, 1 days);
        IPolicyModule[] memory modules = new IPolicyModule[](4);
        modules[0] = s.timeWindow;
        modules[1] = s.whitelist;
        modules[2] = s.spendCap;
        modules[3] = s.rateLimit;
        s.policyStack = new PolicyStack(modules);

        s.router = new EscalationRouter(address(s.registry), address(s.policyStack));
        s.treasury = new Treasury(address(s.registry), asset, address(s.router));
        s.router.setTreasury(address(s.treasury));
        s.router.setRateRecorder(address(s.rateLimit));
        s.rateLimit.setRecorder(address(s.router));

        s.streamer = new EpochStreamer(
            address(s.treasury), root, uint64(block.timestamp), uint64(c.epochDuration)
        );
        s.treasury.setStreamer(address(s.streamer));

        s.sessions = new SessionRegistry(root, address(s.registry));
        s.router.setSessionRegistry(address(s.sessions));
        s.sessions.setEscalationRouter(address(s.router));

        // Hand every bootstrap power to the GovernanceModule. After this the deployer
        // holds no authority beyond the root seat it was deployed for.
        s.registry.setGovernor(address(s.gov));
        s.sessions.setGovernor(address(s.gov));
        s.treasury.setGovernor(address(s.gov));
        s.router.setGovernor(address(s.gov));
        s.streamer.setGovernor(address(s.gov));
        s.whitelist.setGovernor(address(s.gov));
        s.spendCap.setGovernor(address(s.gov));
    }

    /// @notice Read-only post-conditions; also usable as an independent check on a live stack.
    function verify(Stack memory s, address root) public view {
        address gov = address(s.gov);
        _check(s.gov.humanRoot() == root, "gov root");
        _check(s.registry.governor() == gov, "registry governor");
        _check(s.sessions.governor() == gov, "sessions governor");
        _check(s.treasury.governor() == gov, "treasury governor");
        _check(s.router.governor() == gov, "router governor");
        _check(s.streamer.governor() == gov, "streamer governor");
        _check(s.whitelist.governor() == gov, "whitelist governor");
        _check(s.spendCap.governor() == gov, "spendCap governor");
        _check(s.whitelist.admin() == address(0), "whitelist admin");
        _check(s.spendCap.admin() == address(0), "spendCap admin");
        _check(address(s.treasury.token()) == s.asset, "treasury token");
        _check(s.treasury.spender() == address(s.router), "treasury spender");
        _check(s.treasury.streamer() == address(s.streamer), "treasury streamer");
        _check(address(s.router.treasury()) == address(s.treasury), "router treasury");
        _check(address(s.router.rateRecorder()) == address(s.rateLimit), "router rateRecorder");
        _check(address(s.router.sessionRegistry()) == address(s.sessions), "router sessionRegistry");
        _check(s.rateLimit.recorder() == address(s.router), "rateLimit recorder");
        _check(s.rateLimit.recorderLocked(), "rateLimit recorder lock");
        _check(s.sessions.escalationRouter() == address(s.router), "sessions router");
        address canonical = DeployConfig.canonicalAsset(block.chainid);
        _check(canonical == address(0) || s.asset == canonical, "canonical asset");
    }

    function _check(bool ok, string memory what) private pure {
        if (!ok) revert PostConditionFailed(what);
    }

    function _log(Stack memory s) private pure {
        console2.log("asset", s.asset);
        console2.log("OrgRegistry", address(s.registry));
        console2.log("GovernanceModule", address(s.gov));
        console2.log("Treasury", address(s.treasury));
        console2.log("EscalationRouter", address(s.router));
        console2.log("EpochStreamer", address(s.streamer));
        console2.log("SessionRegistry", address(s.sessions));
        console2.log("PolicyStack", address(s.policyStack));
    }
}
