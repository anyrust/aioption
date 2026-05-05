pragma solidity ^0.8.20;
import {Script} from "forge-std/Script.sol";
import {OptionFactory} from "../src/OptionFactory.sol";

contract DeployOF is Script {
    function run() external {
        vm.startBroadcast();
        new OptionFactory(0x8Bd88478bE5f55F5be473De80C7117e5cE5117D3, 0);
        vm.stopBroadcast();
    }
}
