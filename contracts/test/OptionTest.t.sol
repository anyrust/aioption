// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PrefixRegistry} from "../src/PrefixRegistry.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {OptionFactory} from "../src/OptionFactory.sol";
import {Option} from "../src/Option.sol";

contract OptionTest is Test {
    PrefixRegistry public pre;
    ProviderRegistry public prov;
    OptionFactory public factory;

    address deployer = address(0x200);
    address dev = address(0x300);
    address p1; address p2; address p3; address p4;
    uint256 constant PK1 = 1; uint256 constant PK2 = 2; uint256 constant PK3 = 3; uint256 constant PK4 = 4;
    address u1 = address(0x600); address u2 = address(0x700);

    bytes32 constant FP = bytes32(uint256(0xdeadbeef01));

    function setUp() public {
        p1 = vm.addr(PK1); p2 = vm.addr(PK2); p3 = vm.addr(PK3); p4 = vm.addr(PK4);
        vm.startPrank(deployer);
        pre = new PrefixRegistry(0.001 ether);
        prov = new ProviderRegistry(address(pre), 0.001 ether);
        factory = new OptionFactory(address(prov), 0);
        vm.stopPrank();
        vm.deal(deployer, 100 ether); vm.deal(dev, 100 ether);
        vm.deal(p1, 100 ether); vm.deal(p2, 100 ether); vm.deal(p3, 100 ether); vm.deal(p4, 100 ether);
        vm.deal(u1, 100 ether); vm.deal(u2, 100 ether);
    }

    function _setup() internal {
        vm.startPrank(dev); pre.register{value: 0.001 ether}("ai"); prov.registerImage("aijudge", FP); vm.stopPrank();
        vm.prank(p1); prov.registerProvider{value: 0.001 ether}("aijudge", 1, 0.001 ether);
        vm.prank(p2); prov.registerProvider{value: 0.001 ether}("aijudge", 1, 0.001 ether);
        vm.prank(p3); prov.registerProvider{value: 0.001 ether}("aijudge", 1, 0.001 ether);
        vm.prank(p4); prov.registerProvider{value: 0.001 ether}("aijudge", 1, 0.001 ether);
    }

    function _cfg() internal view returns (Option.Config memory) {
        string[] memory o = new string[](3); o[0]="YES"; o[1]="NO"; o[2]="UNCLEAR";
        return Option.Config({
            question: "Will ETH exceed $5000 by 2026?",
            judgeAppId: "aijudge", judgeVersion: 1, judgeFingerprint: FP,
            tradingStartTime: block.timestamp, tradingEndTime: block.timestamp + 7 days,
            resolveDeadline: block.timestamp + 8 days, minResolutions: 2,
            options: o
        });
    }

    function _sign(address opt, string memory q, uint256 r, uint256 pk) internal pure returns (bytes memory) {
        bytes32 h = keccak256(abi.encodePacked(opt, q, r));
        (uint8 v, bytes32 rs, bytes32 s) = vm.sign(pk, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", h)));
        return abi.encodePacked(rs, s, v);
    }

    // ===== Deployment =====
    function test_DeployAndTrade() public {
        _setup();
        vm.prank(u1); address addr = factory.createOption(_cfg());
        Option opt = Option(payable(addr));
        assertEq(uint256(opt.status()), uint256(Option.Status.TRADING));
        assertEq(opt.optionCount(), 3);
        assertEq(opt.minResolutions(), 2);
    }

    // ===== Multi-provider consensus =====
    function test_Consensus() public {
        _setup();
        vm.prank(u1); address addr = factory.createOption(_cfg());
        Option opt = Option(payable(addr));
        vm.warp(block.timestamp + 8 days); opt.startResolving();
        string memory q = opt.question();
        vm.prank(p1); opt.submitResolution(0, _sign(addr, q, 0, PK1));
        vm.prank(p2); opt.submitResolution(0, _sign(addr, q, 0, PK2));
        assertEq(uint256(opt.status()), uint256(Option.Status.RESOLVED));
        assertEq(opt.winningOption(), 0);
        assertEq(opt.reRound(), 0); // no re-resolution needed
    }

    // ===== Re-resolution on disagreement =====
    function test_ReResolution() public {
        _setup();
        vm.prank(u1); address addr = factory.createOption(_cfg());
        Option opt = Option(payable(addr));
        vm.warp(block.timestamp + 8 days); opt.startResolving();
        string memory q = opt.question();

        // Round 0: p1=YES, p2=NO → tie
        vm.prank(p1); opt.submitResolution(0, _sign(addr, q, 0, PK1));
        vm.prank(p2); opt.submitResolution(1, _sign(addr, q, 1, PK2));
        // Should trigger re-resolution
        assertEq(opt.reRound(), 1);
        assertEq(uint256(opt.status()), uint256(Option.Status.RESOLVING)); // not yet resolved

        // Round 1: p1=YES, p2=YES → consensus
        vm.prank(p1); opt.submitResolution(0, _sign(addr, q, 0, PK1));
        vm.prank(p2); opt.submitResolution(0, _sign(addr, q, 0, PK2));
        assertEq(uint256(opt.status()), uint256(Option.Status.RESOLVED));
        assertEq(opt.winningOption(), 0);
        assertEq(opt.reRound(), 1); // resolved after 1 re-round
    }

    // ===== Settlement =====
    function test_Settle() public {
        _setup();
        vm.prank(u1); address addr = factory.createOption(_cfg());
        Option opt = Option(payable(addr));
        vm.prank(u1); address(addr).call{value: 3 ether}("");
        vm.warp(block.timestamp + 8 days); opt.startResolving();
        string memory q = opt.question();
        vm.prank(p1); opt.submitResolution(0, _sign(addr, q, 0, PK1));
        vm.prank(p2); opt.submitResolution(0, _sign(addr, q, 0, PK2));

        address[] memory r = new address[](1); r[0] = u1;
        uint256[] memory a = new uint256[](1); a[0] = 3 ether;
        bytes32 h = keccak256(abi.encode(address(addr), uint256(0), r, a));
        (uint8 v, bytes32 rs, bytes32 s) = vm.sign(PK1, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", h)));
        opt.settle(r, a, abi.encodePacked(rs, s, v));
        assertTrue(opt.isSettled());
        uint256 bal = u1.balance; vm.prank(u1); opt.claimReward();
        assertEq(u1.balance, bal + 3 ether);
    }

    // ===== Slashing (via ProviderRegistry) =====
    function test_SlashNonResponder() public {
        _setup();
        vm.prank(u1); address addr = factory.createOption(_cfg());
        Option opt = Option(payable(addr));
        vm.prank(u1); address(addr).call{value: 1 ether}("");
        vm.warp(block.timestamp + 8 days); opt.startResolving();
        vm.warp(block.timestamp + 1 days); opt.forceResolve();
        uint256 s = prov.getProviderInfo(p3).stake;
        vm.prank(u2); prov.slashNonResponder(addr, p3); // p3 never submitted
        assertEq(prov.getProviderInfo(p3).stake, s - 0.001 ether / 10);
    }

    // ===== Renounce =====
    function test_Renounce() public {
        _setup();
        vm.prank(deployer); factory.renounceOwnership(); assertEq(factory.owner(), address(0));
        vm.prank(deployer); pre.renounceOwnership(); assertEq(pre.owner(), address(0));
        vm.prank(deployer); prov.renounceOwnership(); assertEq(prov.owner(), address(0));
    }

    // ===== Edge: can't submit twice in same round =====
    function test_CantResubmitSameRound() public {
        _setup();
        vm.prank(u1); address addr = factory.createOption(_cfg());
        Option opt = Option(payable(addr));
        vm.warp(block.timestamp + 8 days); opt.startResolving();
        string memory q = opt.question();
        vm.prank(p1); opt.submitResolution(0, _sign(addr, q, 0, PK1));
        vm.prank(p1);
        vm.expectRevert("Already submitted this round");
        opt.submitResolution(0, _sign(addr, q, 0, PK1));
    }
}
