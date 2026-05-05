// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {PrefixRegistry} from "../src/PrefixRegistry.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {OptionFactory} from "../src/OptionFactory.sol";

contract DeployOption is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint256 registrationFee = 0.001 ether;
        uint256 minStake = 0.001 ether;
        uint256 deployFee = 0;

        vm.startBroadcast(deployerPrivateKey);

        PrefixRegistry prefixRegistry = new PrefixRegistry(registrationFee);
        console.log("PrefixRegistry deployed at:", address(prefixRegistry));

        ProviderRegistry providerRegistry = new ProviderRegistry(address(prefixRegistry), minStake);
        console.log("ProviderRegistry deployed at:", address(providerRegistry));

        OptionFactory optionFactory = new OptionFactory(address(providerRegistry), deployFee);
        console.log("OptionFactory deployed at:", address(optionFactory));

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("PrefixRegistry:  ", address(prefixRegistry));
        console.log("ProviderRegistry:", address(providerRegistry));
        console.log("OptionFactory:   ", address(optionFactory));
    }
}
