pragma solidity ^0.8.20;
import {Script,console} from "forge-std/Script.sol";
import {PrefixRegistry} from "../src/PrefixRegistry.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {OptionFactory} from "../src/OptionFactory.sol";
contract DeployOption is Script {
    function run() external {
        uint256 k = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(k);
        PrefixRegistry p = new PrefixRegistry(0.001 ether);
        console.log("PrefixRegistry:", address(p));
        ProviderRegistry r = new ProviderRegistry(address(p), 0.0001 ether);
        console.log("ProviderRegistry:", address(r));
        OptionFactory f = new OptionFactory(address(r));
        console.log("OptionFactory:", address(f));
        vm.stopBroadcast();
    }
}
