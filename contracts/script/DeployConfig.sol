// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/// @notice Per-chain facts the production deploy scripts rely on.
/// @dev The mock-chain list is an allowlist: a chain that is not named here can never
///      receive a mock token, whatever it looks like. Mainnet chains are simply absent.
library DeployConfig {
    uint256 internal constant ANVIL = 31337;
    uint256 internal constant ETHEREUM_SEPOLIA = 11155111;
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant BASE = 8453;

    /// @dev Circle's native USDC on Base.
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    error MockAssetOnRealChain(uint256 chainId);
    error AssetRequired();
    error AssetNotAContract(address asset);
    error WrongCanonicalAsset(uint256 chainId, address asset, address expected);

    /// @notice Chains where `MockUSDC` / `MockWETH` may be deployed.
    function isMockChain(uint256 chainId) internal pure returns (bool) {
        return chainId == ANVIL || chainId == ETHEREUM_SEPOLIA || chainId == BASE_SEPOLIA;
    }

    /// @notice The only asset a chain with a canonical entry may use; zero when none is pinned.
    function canonicalAsset(uint256 chainId) internal pure returns (address) {
        if (chainId == BASE) return BASE_USDC;
        return address(0);
    }

    /// @notice Revert unless `asset` is acceptable as the treasury token on `chainId`.
    function requireRealAsset(uint256 chainId, address asset) internal view {
        if (asset == address(0)) revert AssetRequired();
        if (asset.code.length == 0) revert AssetNotAContract(asset);
        address expected = canonicalAsset(chainId);
        if (expected != address(0) && asset != expected) revert WrongCanonicalAsset(chainId, asset, expected);
    }

    /// @notice Revert if a mock asset was requested on a chain outside the mock allowlist.
    function requireMockAllowed(uint256 chainId) internal pure {
        if (!isMockChain(chainId)) revert MockAssetOnRealChain(chainId);
    }
}
