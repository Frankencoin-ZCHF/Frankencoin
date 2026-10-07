// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Test-only router: pulls `amountIn` of tokenIn from msg.sender and pays out tokenOut at a
///      fixed price, mimicking the pull-then-send behaviour of real aggregator routers.
///      `price` is tokenIn (18 dec) per tokenOut base unit, scaled by 1e18, like Position.price().
contract MockSwapRouter {
    uint256 public price;

    constructor(uint256 _price) {
        price = _price;
    }

    function setPrice(uint256 _price) external {
        price = _price;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn) external {
        require(IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn), "pull");
        require(IERC20(tokenOut).transfer(msg.sender, (amountIn * 1e18) / price), "pay");
    }
}
