pragma solidity ^0.8.20;
import {Script} from "forge-std/Script.sol";
import {OrderBookContract} from "../src/OrderBook.sol";
contract DeployOB3 is Script {
    function run() external {
        vm.startBroadcast();
        new OrderBookContract(address(0x003267501421419f5123F8234DD1664fa4D7ED51DF), 2);
        vm.stopBroadcast();
    }
}
