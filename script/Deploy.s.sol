// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {SteppedAgentVaultFactory} from "../src/SteppedAgentVaultFactory.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {DeployConfig} from "./DeployConfig.sol";

interface IERC20Meta {
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

/// @notice Deploys SteppedAgentVaultFactory on Ethereum mainnet (1), Base (8453) or local anvil (31337).
///         - Prints the chain it is on.
///         - Checks the chain's canonical USDC (symbol "USDC", 6 decimals) before doing anything.
///         - REFUSES to broadcast on chain 1 / 8453 unless env CONFIRM_MAINNET=yes.
///         - On a live broadcast, writes the factory (and USDC) address into web/src/deployments.json.
///         Dry run (no --broadcast) is always allowed and prints gas estimates.
contract Deploy is Script {
    string internal constant DEPLOYMENTS_PATH = "web/src/deployments.json";

    function run() external returns (SteppedAgentVaultFactory factory, address usdc) {
        DeployConfig.Chain memory c = DeployConfig.get(block.chainid);
        console2.log("==> Chain:", c.name);
        console2.log("    chainId:", block.chainid);

        bool broadcasting =
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        if (c.isMainnet) {
            _checkUsdc(c.usdc);
            if (broadcasting) {
                require(
                    keccak256(bytes(vm.envOr("CONFIRM_MAINNET", string("")))) == keccak256("yes"),
                    "Deploy: refusing to broadcast on a live chain without CONFIRM_MAINNET=yes"
                );
                console2.log("    CONFIRM_MAINNET=yes - LIVE BROADCAST");
            } else {
                console2.log("    dry run (no --broadcast): nothing will be sent");
            }
        }

        vm.startBroadcast();
        usdc = c.isMainnet ? c.usdc : address(new MockUSDC());
        factory = new SteppedAgentVaultFactory(usdc);
        vm.stopBroadcast();

        console2.log("SteppedAgentVaultFactory", address(factory));
        console2.log("USDC", usdc);

        if (broadcasting) {
            _writeWebConfig(address(factory), usdc);
        }
    }

    function _checkUsdc(address usdc) internal view {
        require(usdc.code.length > 0, "Deploy: USDC has no code on this chain");
        require(keccak256(bytes(IERC20Meta(usdc).symbol())) == keccak256("USDC"), "Deploy: USDC symbol mismatch");
        require(IERC20Meta(usdc).decimals() == 6, "Deploy: USDC decimals mismatch");
        console2.log("    USDC verified (symbol USDC, 6 decimals):", usdc);
    }

    /// @dev Updates only this chain's entry in web/src/deployments.json. No-op if the file is missing.
    function _writeWebConfig(address factory, address usdc) internal {
        string memory path = vm.envOr("DEPLOYMENTS_PATH", DEPLOYMENTS_PATH);
        if (!vm.exists(path)) {
            console2.log("    skip writing dapp config: file not found:", path);
            return;
        }
        string memory key = string.concat(".", vm.toString(block.chainid));
        string memory obj = "dep";
        vm.serializeAddress(obj, "factory", factory);
        string memory json = vm.serializeAddress(obj, "usdc", usdc);
        vm.writeJson(json, path, key);
        console2.log("    wrote factory + USDC to", path);
    }
}
