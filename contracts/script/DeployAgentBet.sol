// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {PrefixRegistry} from "../src/PrefixRegistry.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {BetFactory} from "../src/BetFactory.sol";

/**
 * @title DeployAgentBet
 * @notice 部署 Agent Bet 全部核心合約
 *
 * Usage:
 *   forge script script/DeployAgentBet.sol:DeployAgentBet \
 *     --rpc-url sepolia \
 *     --broadcast \
 *     --verify \
 *     -vvvv
 */
contract DeployAgentBet is Script {
    function run() external {
        // ============ Configuration ============
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // PrefixRegistry: 註冊前綴費用 (0.001 ETH)
        uint256 registrationFee = 0.001 ether;

        // ProviderRegistry: 最小押金 (0.001 ETH for testnet)
        uint256 minStake = 0.001 ether;

        // BetFactory: 部署費用 (0 ETH for MVP), 平台費 1%
        uint256 deployFee = 0;
        uint256 platformFeeBps = 100; // 1%

        // ============ Deploy ============
        vm.startBroadcast(deployerPrivateKey);

        // 1. PrefixRegistry
        PrefixRegistry prefixRegistry = new PrefixRegistry(registrationFee);
        console.log("PrefixRegistry deployed at:", address(prefixRegistry));

        // 2. ProviderRegistry
        ProviderRegistry providerRegistry = new ProviderRegistry(
            address(prefixRegistry),
            minStake
        );
        console.log("ProviderRegistry deployed at:", address(providerRegistry));

        // 3. BetFactory
        BetFactory betFactory = new BetFactory(
            address(providerRegistry),
            deployFee,
            platformFeeBps
        );
        console.log("BetFactory deployed at:", address(betFactory));

        // ============ Post-deploy Setup ============

        // Add supported tokens (USDT, WBTC on Sepolia)
        // Sepolia USDT: 0x... (需要替換為實際地址)
        // Sepolia WBTC: 0x... (需要替換為實際地址)

        vm.stopBroadcast();

        // ============ Summary ============
        console.log("\n=== Deployment Summary ===");
        console.log("PrefixRegistry: ", address(prefixRegistry));
        console.log("ProviderRegistry:", address(providerRegistry));
        console.log("BetFactory:      ", address(betFactory));
        console.log("Registration Fee:", registrationFee);
        console.log("Min Stake:       ", minStake);
        console.log("Platform Fee:    ", platformFeeBps, "bps");
    }
}