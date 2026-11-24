// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployOrg} from "../script/DeployOrg.s.sol";
import {DeployProtocol} from "../script/DeployProtocol.s.sol";
import {DeployConfig} from "../script/DeployConfig.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MarketplacePayments} from "../src/MarketplacePayments.sol";

/// @notice The release scripts refuse unsafe configs and end with a fully wired stack.
contract DeployScriptsTest is Test {
    DeployOrg internal org;
    DeployProtocol internal protocol;
    address internal root;

    function setUp() public {
        org = new DeployOrg();
        protocol = new DeployProtocol();
        // Forge's default broadcast sender: the key `vm.startBroadcast()` signs with in tests.
        root = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;
    }

    function _org(bool mock, address asset) internal view returns (DeployOrg.Config memory) {
        return DeployOrg.Config({
            root: root,
            asset: asset,
            mockAsset: mock,
            defaultCap: 50e6,
            epochDuration: 1 days,
            rootVotePower: 2
        });
    }

    function _proto(bool mock, address governor, address fees) internal pure returns (DeployProtocol.Config memory) {
        return DeployProtocol.Config({
            governor: governor,
            feeRecipient: fees,
            asset: address(0),
            mockAsset: mock,
            feeBps: 2000
        });
    }

    function test_mockOrgDeploysOnSepoliaWithPostConditions() public {
        vm.chainId(DeployConfig.ETHEREUM_SEPOLIA);
        DeployOrg.Stack memory s = org.execute(_org(true, address(0)));
        assertEq(s.whitelist.admin(), address(0));
        assertEq(s.spendCap.admin(), address(0));
        assertEq(s.registry.governor(), address(s.gov));
        assertEq(address(s.treasury.token()), s.asset);
    }

    function test_refusesMockOnBase() public {
        vm.chainId(DeployConfig.BASE);
        vm.expectRevert(abi.encodeWithSelector(DeployConfig.MockAssetOnRealChain.selector, DeployConfig.BASE));
        org.execute(_org(true, address(0)));
    }

    function test_refusesMockOnUnlistedChain() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(DeployConfig.MockAssetOnRealChain.selector, 1));
        org.execute(_org(true, address(0)));
    }

    function test_baseRejectsNonCanonicalAsset() public {
        vm.chainId(DeployConfig.BASE);
        MockUSDC fake = new MockUSDC();
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployConfig.WrongCanonicalAsset.selector, DeployConfig.BASE, address(fake), DeployConfig.BASE_USDC
            )
        );
        org.execute(_org(false, address(fake)));
    }

    function test_baseAcceptsCanonicalUsdc() public {
        vm.chainId(DeployConfig.BASE);
        vm.etch(DeployConfig.BASE_USDC, address(new MockUSDC()).code);
        DeployOrg.Stack memory s = org.execute(_org(false, DeployConfig.BASE_USDC));
        assertEq(address(s.treasury.token()), DeployConfig.BASE_USDC);
    }

    function test_noRootFallbackOffAnvil() public {
        vm.chainId(DeployConfig.BASE_SEPOLIA);
        DeployOrg.Config memory c = _org(true, address(0));
        c.root = address(0);
        vm.expectRevert(DeployOrg.RootRequired.selector);
        org.execute(c);
    }

    function test_protocolRequiresExplicitRoles() public {
        vm.chainId(DeployConfig.BASE_SEPOLIA);
        vm.expectRevert(DeployProtocol.GovernorRequired.selector);
        protocol.execute(_proto(true, address(0), makeAddr("fees")));
        vm.expectRevert(DeployProtocol.FeeRecipientRequired.selector);
        protocol.execute(_proto(true, makeAddr("safe"), address(0)));
    }

    function test_protocolGovernorIsNeverTheDeployer() public {
        vm.chainId(DeployConfig.BASE_SEPOLIA);
        address safe = makeAddr("safe");
        MarketplacePayments m = protocol.execute(_proto(true, safe, makeAddr("fees")));
        assertEq(m.governor(), safe);
    }

    function test_protocolRefusesMockOnBase() public {
        vm.chainId(DeployConfig.BASE);
        vm.expectRevert(abi.encodeWithSelector(DeployConfig.MockAssetOnRealChain.selector, DeployConfig.BASE));
        protocol.execute(_proto(true, makeAddr("safe"), makeAddr("fees")));
    }
}
