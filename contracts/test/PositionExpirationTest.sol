// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Strings.sol";
import "./TestToken.sol";
import "../equity/Equity.sol";
import "../utils/Ownable.sol";
import "../minting/Position.sol";
import "../minting/MintingHub.sol";
import "../stablecoin/StablecoinBridge.sol";
import "../minting/IPosition.sol";
import "../stablecoin/IFrankencoin.sol";
import "../erc20/IERC20.sol";

contract PositionExpirationTest {

    MintingHub hub;
    TestToken col;
    IFrankencoin zchf;

    constructor(address hub_) {
        hub = MintingHub(hub_);
        col = new TestToken("Some Collateral", "COL", uint8(0));
        zchf = hub.zchf();
    }

    function openPositionFor(address owner) public returns (address) {
        col.mint(address(this), 100);
        col.approve(address(hub), 100);
        address pos = hub.openPosition(address(col), 10, 100 /* collateral */, 1000000 * 10**18, 7 days, 30 days, 10 hours, 50000, 1000 * 10**36 /* price */, 200000);
        Position(pos).transferOwnership(owner);
        return pos;
    }

    function forceBuy(address pos, uint256 amount) public {
        uint256 price = hub.expiredPurchasePrice(Position(pos));
        uint256 balanceBefore = zchf.balanceOf(address(this));
        uint256 colBalBefore = col.balanceOf(address(this));
        hub.buyExpiredCollateral(Position(pos), amount);
        uint256 balanceAfter = zchf.balanceOf(address(this));
        uint256 colBalAfter = col.balanceOf(address(this));
        require(colBalAfter - colBalBefore == amount, "collateral amount");
        require((balanceBefore - balanceAfter) == amount * price / 10**18, "price paid");
    }

}
