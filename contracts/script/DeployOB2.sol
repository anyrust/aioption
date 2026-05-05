pragma solidity ^0.8.20;
import {Script} from "forge-std/Script.sol";
import {OrderBookContract} from "../src/OrderBook.sol";

contract DeployOB2 is Script {
    function run() external {
        vm.startBroadcast();
        new OrderBookContract(0x89B2d7144183899F36d857fa26463Df4691513ED, 2);
        vm.stopBroadcast();
    }
}
