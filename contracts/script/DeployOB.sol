pragma solidity ^0.8.20;
import {Script} from "forge-std/Script.sol";
import {OrderBookContract} from "../src/OrderBook.sol";

contract DeployOB is Script {
    function run() external {
        vm.startBroadcast();
        new OrderBookContract(0x0cc786879B3e1D6bF2555e4dC56FFc7dFEE9dC82, 2);
        vm.stopBroadcast();
    }
}
