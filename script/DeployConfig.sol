// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Per-chain deploy settings. Only these chains are supported.
library DeployConfig {
    struct Chain {
        string name;
        bool isMainnet; // live chain with real funds -> needs CONFIRM_MAINNET=yes to broadcast
        address usdc; // Circle native USDC (address(0) on anvil: a MockUSDC is deployed)
    }

    uint256 internal constant ETHEREUM = 1;
    uint256 internal constant BASE = 8453;
    uint256 internal constant ANVIL = 31337;

    address internal constant USDC_ETHEREUM = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function get(uint256 chainId) internal pure returns (Chain memory) {
        if (chainId == ETHEREUM) return Chain("Ethereum mainnet", true, USDC_ETHEREUM);
        if (chainId == BASE) return Chain("Base", true, USDC_BASE);
        if (chainId == ANVIL) return Chain("Local anvil", false, address(0));
        revert("DeployConfig: unsupported chain (only 1, 8453, 31337)");
    }
}
