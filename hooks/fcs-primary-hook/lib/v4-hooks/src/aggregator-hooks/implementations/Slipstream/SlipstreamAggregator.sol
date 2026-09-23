// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IUniswapV3Pool} from "../UniswapV3/interfaces/IUniswapV3Pool.sol";
import {UniswapV3Aggregator} from "../UniswapV3/UniswapV3Aggregator.sol";
import {ISlipstreamFactory} from "./interfaces/ISlipstreamFactory.sol";

/// @title SlipstreamAggregator
/// @notice Singleton hook aggregating Slipstream-style concentrated liquidity (tickSpacing-keyed factory lookup)
contract SlipstreamAggregator is UniswapV3Aggregator {
    /// @param manager PoolManager
    /// @param slipstreamFactory Slipstream pool factory (tickSpacing `getPool`)
    constructor(IPoolManager manager, address slipstreamFactory)
        UniswapV3Aggregator(manager, slipstreamFactory, "SlipstreamAggregator v1.0")
    {}

    /// @inheritdoc UniswapV3Aggregator
    /// @dev Slipstream pools are keyed by tickSpacing, not fee tier. Fee is dynamic and not a fixed pool property,
    ///      so key.fee must be LPFeeLibrary.DYNAMIC_FEE_FLAG to signal dynamic pricing and ensure a canonical PoolId.
    function _resolveExternalPool(address token0, address token1, PoolKey calldata key)
        internal
        view
        override
        returns (address pool)
    {
        if (key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG) revert ExternalPoolMismatch();
        pool = ISlipstreamFactory(factory).getPool(token0, token1, key.tickSpacing);
        if (pool == address(0)) revert ExternalPoolNotFound();
        if (IUniswapV3Pool(pool).tickSpacing() != key.tickSpacing) revert ExternalPoolMismatch();
    }
}
