// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "../contracts/test/Strings.sol";
import "../contracts/test/TestToken.sol";
import "../contracts/Equity.sol";
import "../contracts/StablecoinBridge.sol";
import "../contracts/Equity.sol";
import "../contracts/Frankencoin.sol";
import "../contracts/utils/FPSwrapper.sol";

contract FPSWrapperTest is Test {
    
    Frankencoin zchf;
    Equity fps;
    StablecoinBridge swap;
    TestToken xchf;
    FPSWrapper wfps;

    error General(uint256 val);

    constructor() {
        zchf = new Frankencoin(0, address(0), address(0));
        fps = Equity(address(zchf.reserve()));
        wfps = new FPSWrapper(fps);
        xchf = new TestToken("Base Franc", "BCHF", uint8(18));
        swap = new StablecoinBridge(address(xchf), address(zchf), 100000 ether);
        zchf.initialize(address(swap), "");
        xchf.mint(address(this), 100000 ether);
        xchf.approve(address(swap), 100000 ether);
        swap.mint(100000 ether);
        fps.invest(100000 ether, 0);
    }

    function testWrapper() public {
        fps.approve(address(wfps), 500 ether);
        wfps.wrap(500 ether);
        vm.expectRevert();
        wfps.wrap(1);
        require(wfps.balanceOf(address(this)) == 500 ether);
        vm.warp(block.timestamp + 5);
        uint256 votesBefore = fps.votes(address(wfps));
        uint256 tot = fps.totalVotes();
        wfps.halveHoldingDuration(new address[](0));
        uint256 votesAfter = fps.votes(address(wfps));
        require(votesAfter == votesBefore / 2);
        require(fps.totalVotes() == tot + votesAfter - votesBefore);
        vm.expectRevert();
        wfps.unwrapAndSell(10 ether);
        wfps.unwrap(10 ether);
        require(fps.balanceOf(address(this)) == 510 ether);
        vm.warp(block.timestamp + 90*24*3600);
        wfps.unwrapAndSell(10 ether);
        require(fps.totalSupply() == 990 ether);
        fps.redeem(address(this), 510 ether);
        vm.expectRevert();
        wfps.halveHoldingDuration(new address[](0));
    }

    function testDepositAndWithdraw() public {
        fps.approve(address(wfps), 10 ether);
        wfps.depositFor(address(0x1), 1 ether);
        require(wfps.balanceOf(address(0x1)) == 1 ether);
        vm.expectRevert();
        wfps.withdrawTo(address(0x1), 1 ether);
        wfps.wrap(1 ether);
        wfps.withdrawTo(address(0x2), 1 ether);
        require(wfps.underlying().balanceOf(address(0x2)) == 1 ether);
    }
}