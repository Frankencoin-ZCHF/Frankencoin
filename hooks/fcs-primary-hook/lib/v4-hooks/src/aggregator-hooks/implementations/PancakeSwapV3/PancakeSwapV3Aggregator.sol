// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {UniswapV3Aggregator} from "../UniswapV3/UniswapV3Aggregator.sol";
import {IPancakeSwapV3Callback} from "./interfaces/IPancakeSwapV3Callback.sol";

/// @notice Same as UniswapV3Aggregator but implements PancakeSwap V3 swap callback ABI
contract PancakeSwapV3Aggregator is UniswapV3Aggregator, IPancakeSwapV3Callback {
    constructor(IPoolManager manager, address factory_, string memory hookVersion)
        UniswapV3Aggregator(manager, factory_, hookVersion)
    {}

    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        _processCallback(amount0Delta, amount1Delta, data);
    }
}
