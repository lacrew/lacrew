// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {MarketplacePayments} from "../src/MarketplacePayments.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {DeployConfig} from "./DeployConfig.sol";

/// @notice Release deploy of `MarketplacePayments`, the one protocol-owned contract.
/// @dev Env: `MARKETPLACE_GOVERNOR` and `PLATFORM_FEE_RECIPIENT` (both required, no
///      fallback to the broadcaster), `ASSET` (unless `DEPLOY_MOCK_ASSET` on a mock chain),
///      `PLATFORM_FEE_BPS` (default 2000). The governor is passed to the constructor, so
///      the deployer never holds any role.
contract DeployProtocol is Script {
    error GovernorRequired();
    error FeeRecipientRequired();
    error PostConditionFailed(string what);

    struct Config {
        address governor;
        address feeRecipient;
        address asset;
        bool mockAsset;
        uint16 feeBps;
    }

    function run() external returns (MarketplacePayments) {
        return execute(
            Config({
                governor: vm.envOr("MARKETPLACE_GOVERNOR", address(0)),
                feeRecipient: vm.envOr("PLATFORM_FEE_RECIPIENT", address(0)),
                asset: vm.envOr("ASSET", address(0)),
                mockAsset: vm.envOr("DEPLOY_MOCK_ASSET", false),
                feeBps: uint16(vm.envOr("PLATFORM_FEE_BPS", uint256(2000)))
            })
        );
    }

    function execute(Config memory c) public returns (MarketplacePayments m) {
        address governor = c.governor;
        address feeRecipient = c.feeRecipient;
        uint16 feeBps = c.feeBps;
        address asset = c.asset;
        if (governor == address(0)) revert GovernorRequired();
        if (feeRecipient == address(0)) revert FeeRecipientRequired();

        bool mock = c.mockAsset;
        if (mock) DeployConfig.requireMockAllowed(block.chainid);
        else DeployConfig.requireRealAsset(block.chainid, asset);

        vm.startBroadcast();
        if (mock) asset = address(new MockUSDC());
        m = new MarketplacePayments(asset, feeRecipient, governor, feeBps);
        vm.stopBroadcast();

        if (m.governor() != governor) revert PostConditionFailed("governor");
        if (m.feeRecipient() != feeRecipient) revert PostConditionFailed("feeRecipient");
        if (address(m.token()) != asset) revert PostConditionFailed("token");
        if (m.feeBps() != feeBps) revert PostConditionFailed("feeBps");
        console2.log("MarketplacePayments", address(m));
    }
}
