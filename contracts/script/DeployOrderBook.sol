pragma solidity ^0.8.20;
import {Script} from "forge-std/Script.sol";
import {OrderBookContract} from "../src/OrderBook.sol";

contract DeployOrderBook is Script {
    function run() external {
        vm.startBroadcast();
        new OrderBookContract(0x882768B21e8f114C9A85c967541F1440C500836A, 2);
        vm.stopBroadcast();
    }
}
