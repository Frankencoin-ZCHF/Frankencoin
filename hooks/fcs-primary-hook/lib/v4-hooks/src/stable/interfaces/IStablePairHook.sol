// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {StableFeeConfig} from "../interfaces/IStableFeeConfiguration.sol";
import {IDynamicFeeHook} from "../../interfaces/IDynamicFeeHook.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Interface for the StablePairHook
interface IStablePairHook is IDynamicFeeHook {
    /// @notice Error thrown when the pool trying to be initialized is not using a dynamic fee
    /// @param lpFee The LP fee that was used to try to initialize the pool
    error MustUseDynamicFee(uint24 lpFee);

    /// @notice Error thrown when the hook address is not address(this)
    /// @param hookAddress The invalid hook address
    error InvalidHookAddress(address hookAddress);

    /// @notice Event emitted when a pool is initialized
    /// @param poolKey The PoolKey of the pool
    /// @param sqrtPriceX96 The initial starting price of the pool, expressed as a sqrtPriceX96
    /// @param feeConfig The stored fee config for the pool
    event PoolInitialized(PoolKey indexed poolKey, uint160 sqrtPriceX96, StableFeeConfig feeConfig);

    /// @notice Initialize a Uniswap v4 pool
    /// @param poolKey The PoolKey of the pool to initialize
    /// @param sqrtPriceX96 The initial starting price of the pool, expressed as a sqrtPriceX96
    /// @param feeConfig The fee config for the pool
    /// @return tick The current tick of the pool
    function initializePool(PoolKey calldata poolKey, uint160 sqrtPriceX96, StableFeeConfig calldata feeConfig)
        external
        returns (int24 tick);
}
