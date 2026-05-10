pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {PrefixRegistry} from "../src/PrefixRegistry.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {OptionFactory} from "../src/OptionFactory.sol";
import {Option} from "../src/Option.sol";

contract MinimalTest is Test {
    function test_deploy() public {
        address d = address(0x200);
        vm.startPrank(d);
        PrefixRegistry pre = new PrefixRegistry(0.001 ether);
        ProviderRegistry prov = new ProviderRegistry(address(pre), 0.0001 ether);
        OptionFactory f = new OptionFactory(address(prov));
        vm.stopPrank();
        assertTrue(address(f) != address(0));
    }

    function test_createOption() public {
        address d = address(0x200); address p1 = vm.addr(1);
        vm.deal(d, 10 ether); vm.deal(p1, 10 ether);
        vm.startPrank(d);
        PrefixRegistry pre = new PrefixRegistry(0.001 ether);
        ProviderRegistry prov = new ProviderRegistry(address(pre), 0.0001 ether);
        OptionFactory f = new OptionFactory(address(prov));
        
        pre.register{value: 0.001 ether}("ai");
        prov.registerImage("aijudge", bytes32(uint256(0xdeadbeef01)));
        vm.stopPrank();

        vm.prank(p1); prov.registerProvider{value: 0.0001 ether}("aijudge", 1, 0.0001 ether);

        Option.Config memory c = Option.Config({
            question: "Will ETH exceed $5000?",
            judgeAppId: "aijudge", judgeVersion: 1,
            judgeFingerprint: bytes32(uint256(0xdeadbeef01)),
            tradingEndTime: block.timestamp + 1 hours,
            resolveDeadline: block.timestamp + 2 hours,
            token: address(0),
            teeVerifier: address(0)
        });

        vm.prank(d); address opt = f.create(c);
        Option o = Option(payable(opt));
        assertEq(uint256(o.status()), 1);

        // Deposit and buy
        vm.deal(address(this), 10 ether);
        o.deposit{value: 1 ether}();
        assertEq(o.balances(address(this)), 1 ether);

        o.placeBuy(0, 0.6 ether, 0.01 ether);
        (uint256[] memory bp, uint256[] memory ba, uint256[] memory ap, uint256[] memory aa) = o.getBook(0);
        assertEq(bp.length, 1);
        assertEq(bp[0], 0.6 ether);
    }
}
