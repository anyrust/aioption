// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {PrefixRegistry} from "../src/PrefixRegistry.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {BetFactory} from "../src/BetFactory.sol";
import {BetContract} from "../src/BetContract.sol";

contract AgentBetTest is Test {
    PrefixRegistry public prefixReg;
    ProviderRegistry public provReg;
    BetFactory public factory;

    address public deployer = address(0x100);
    address public developer = address(0x200);
    address public provider1; address public provider2; address public provider3;
    uint256 constant PK1 = 1; uint256 constant PK2 = 2; uint256 constant PK3 = 3;
    address public user1 = address(0x600);
    address public user2 = address(0x700);
    address public user3 = address(0x800);

    uint256 constant REG_FEE = 0.01 ether;
    uint256 constant MIN_STAKE = 0.1 ether;
    uint256 constant DEPLOY_FEE = 0;
    uint256 constant PLATFORM_FEE = 100;
    bytes32 constant FP1 = bytes32(uint256(0xdeadbeef01));

    function setUp() public {
        provider1 = vm.addr(PK1); provider2 = vm.addr(PK2); provider3 = vm.addr(PK3);
        vm.startPrank(deployer);
        prefixReg = new PrefixRegistry(REG_FEE);
        provReg = new ProviderRegistry(address(prefixReg), MIN_STAKE);
        factory = new BetFactory(address(provReg), DEPLOY_FEE, PLATFORM_FEE);
        vm.stopPrank();
        vm.deal(developer, 100 ether);
        vm.deal(provider1, 100 ether); vm.deal(provider2, 100 ether); vm.deal(provider3, 100 ether);
        vm.deal(user1, 100 ether); vm.deal(user2, 100 ether); vm.deal(user3, 100 ether);
    }

    function _setupJudge() internal {
        vm.startPrank(developer);
        prefixReg.register{value: REG_FEE}("v_t");
        provReg.registerImage("v_tjudge", FP1);
        vm.stopPrank();
    }
    function _regAll() internal {
        vm.prank(provider1); provReg.registerProvider{value: MIN_STAKE}("v_tjudge", 1, 0.01 ether);
        vm.prank(provider2); provReg.registerProvider{value: MIN_STAKE}("v_tjudge", 1, 0.01 ether);
        vm.prank(provider3); provReg.registerProvider{value: MIN_STAKE}("v_tjudge", 1, 0.01 ether);
    }

    function _opts(string memory a, string memory b) internal pure returns (string[] memory o) {
        o = new string[](2); o[0]=a; o[1]=b;
    }

    function _cfg() internal view returns (BetContract.BetConfig memory) {
        return BetContract.BetConfig({
            question: "Will ETH exceed $5000?",
            judgeAppId: "v_tjudge", judgeVersion: 1, judgeFingerprint: FP1,
            bettingStartTime: block.timestamp, bettingEndTime: block.timestamp + 7 days,
            resolveDeadline: block.timestamp + 8 days, minResolutions: 3,
            options: _opts("YES", "NO")
        });
    }

    function _sign(address bet, string memory q, uint256 r, uint256 pk) internal pure returns (bytes memory) {
        bytes32 h = keccak256(abi.encodePacked(bet, q, r));
        (uint8 v, bytes32 rs, bytes32 s) = vm.sign(pk, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", h)));
        return abi.encodePacked(rs, s, v);
    }

    // ================================================================
    function test_DeployAndLifecycle() public {
        _setupJudge(); _regAll();
        vm.prank(user1); address b = factory.createBet(_cfg());
        BetContract bet = BetContract(payable(b));
        assertEq(uint256(bet.status()), uint256(BetContract.BetStatus.BETTING));
        vm.prank(user1); bet.deposit{value: 1 ether}();
        vm.warp(block.timestamp + 8 days); bet.startResolving();
        string memory q = bet.question();
        vm.prank(provider1); bet.submitResolution(0, _sign(b, q, 0, PK1));
        vm.prank(provider2); bet.submitResolution(0, _sign(b, q, 0, PK2));
        vm.prank(provider3); bet.submitResolution(1, _sign(b, q, 1, PK3));
        assertEq(uint256(bet.status()), uint256(BetContract.BetStatus.RESOLVED));
        assertEq(bet.winningOption(), 0);
    }

    function test_TEESettlement() public {
        _setupJudge(); _regAll();
        vm.prank(user1); address b = factory.createBet(_cfg());
        BetContract bet = BetContract(payable(b));
        vm.prank(user1); address(b).call{value: 5 ether}("");
        vm.prank(user2); address(b).call{value: 3 ether}("");
        vm.warp(block.timestamp + 8 days); bet.startResolving();
        string memory q = bet.question();
        vm.prank(provider1); bet.submitResolution(0, _sign(b, q, 0, PK1));
        vm.prank(provider2); bet.submitResolution(0, _sign(b, q, 0, PK2));
        vm.prank(provider3); bet.submitResolution(1, _sign(b, q, 1, PK3));
        assertEq(uint256(bet.status()), uint256(BetContract.BetStatus.RESOLVED));

        address[] memory r = new address[](2); r[0]=user1; r[1]=user2;
        uint256[] memory a = new uint256[](2); a[0]=6 ether; a[1]=2 ether;
        bytes32 h = keccak256(abi.encode(address(b), uint256(0), r, a));
        (uint8 v, bytes32 rs, bytes32 s) = vm.sign(PK1, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", h)));
        bet.settle(r, a, abi.encodePacked(rs, s, v));
        assertTrue(bet.isSettled());
        uint256 bal1 = user1.balance; vm.prank(user1); bet.claimReward();
        assertEq(user1.balance, bal1 + 6 ether);
    }

    // ================================================================
    function test_Prefix() public { vm.prank(developer); prefixReg.register{value: REG_FEE}("abc"); assertEq(prefixReg.prefixOwner("abc"), developer); }
    function test_RegisterProvider() public { _setupJudge(); vm.prank(provider1); provReg.registerProvider{value: MIN_STAKE}("v_tjudge", 1, 0.01 ether); assertTrue(provReg.getProviderInfo(provider1).active); }
    function test_Revert_NotProvider() public {
        _setupJudge();
        vm.prank(provider1); provReg.registerProvider{value: MIN_STAKE}("v_tjudge", 1, 0.01 ether);
        vm.prank(user1); address b = factory.createBet(_cfg());
        vm.warp(block.timestamp + 8 days); BetContract(payable(b)).startResolving();
        // user3 is not a provider — submitResolution should revert
        bool reverted;
        vm.prank(user3);
        try BetContract(payable(b)).submitResolution(0, hex"dead") {
            reverted = false;
        } catch {
            reverted = true;
        }
        assertTrue(reverted);
    }

    function test_Revert_AlreadySettled() public { _setupJudge(); _regAll(); vm.prank(user1); address b = factory.createBet(_cfg()); BetContract bet = BetContract(payable(b)); vm.prank(user1); address(b).call{value: 1 ether}(""); vm.warp(block.timestamp + 8 days); bet.startResolving(); string memory q = bet.question(); vm.prank(provider1); bet.submitResolution(0, _sign(b, q, 0, PK1)); vm.prank(provider2); bet.submitResolution(0, _sign(b, q, 0, PK2)); vm.prank(provider3); bet.submitResolution(1, _sign(b, q, 1, PK3)); address[] memory r = new address[](1); r[0]=user1; uint256[] memory a = new uint256[](1); a[0]=1 ether; bytes32 h = keccak256(abi.encode(address(b), uint256(0), r, a)); (uint8 v, bytes32 rs, bytes32 s) = vm.sign(PK1, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", h))); bet.settle(r, a, abi.encodePacked(rs, s, v)); vm.expectRevert("Already settled"); bet.settle(r, a, abi.encodePacked(rs, s, v)); }

    // ================================================================
    // Unstoppable + Slashing
    // ================================================================
    function test_RenounceOwnership() public {
        _setupJudge(); _regAll();
        vm.prank(user1); factory.createBet(_cfg());
        assertEq(factory.owner(), deployer);
        vm.prank(deployer); factory.renounceOwnership();
        assertEq(factory.owner(), address(0));
        vm.prank(deployer); prefixReg.renounceOwnership();
        assertEq(prefixReg.owner(), address(0));
        vm.prank(deployer); provReg.renounceOwnership();
        assertEq(provReg.owner(), address(0));
    }

    function test_SlashNonResponder() public {
        _setupJudge();
        address p1 = vm.addr(PK1); address p2 = vm.addr(PK2);
        vm.prank(p1); provReg.registerProvider{value: MIN_STAKE}("v_tjudge", 1, 0.01 ether);
        vm.prank(p2); provReg.registerProvider{value: MIN_STAKE}("v_tjudge", 1, 0.01 ether);
        vm.prank(user1); address b = factory.createBet(_cfg());
        BetContract bet = BetContract(payable(b));
        vm.prank(user1); address(b).call{value: 1 ether}("");
        vm.warp(block.timestamp + 8 days); bet.startResolving();
        vm.warp(block.timestamp + 1 days); bet.forceResolve();
        uint256 s = provReg.getProviderInfo(p1).stake;
        vm.prank(user3); provReg.slashNonResponder(b, p1);
        assertEq(provReg.getProviderInfo(p1).stake, s - MIN_STAKE / 10);
    }

}
