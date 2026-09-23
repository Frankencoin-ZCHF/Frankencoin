// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPancakeV3Pool} from "@pancakeswap/v3-core/interfaces/IPancakeV3Pool.sol";
import {IPancakeV3MintCallback} from "@pancakeswap/v3-core/interfaces/callback/IPancakeV3MintCallback.sol";

/// @dev Pays mint callback; `payer` must approve this helper for both tokens.
contract PancakeV3MintHelper is IPancakeV3MintCallback {
    function mint(address pool, address recipient, int24 tickLower, int24 tickUpper, uint128 amount) external {
        IPancakeV3Pool(pool).mint(recipient, tickLower, tickUpper, amount, abi.encode(msg.sender));
    }

    function pancakeV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external override {
        address payer = abi.decode(data, (address));
        if (amount0Owed > 0) {
            address t0 = IPancakeV3Pool(msg.sender).token0();
            require(IERC20(t0).transferFrom(payer, msg.sender, amount0Owed), "t0");
        }
        if (amount1Owed > 0) {
            address t1 = IPancakeV3Pool(msg.sender).token1();
            require(IERC20(t1).transferFrom(payer, msg.sender, amount1Owed), "t1");
        }
    }
}
