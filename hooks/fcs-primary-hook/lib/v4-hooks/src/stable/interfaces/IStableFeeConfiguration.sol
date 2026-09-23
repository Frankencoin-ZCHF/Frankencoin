// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

// Per-pool fee configuration, provided by the caller and stored as-is. The log-space decay rate
// used by the > 4 blocks decay path is derived from k on the fly (see StableFeeCalculation.deriveLogK)
struct StableFeeConfig {
    uint24 k; // Decay factor per block in Q24 format: each block the excess fee retains a factor of k, so smaller k = faster decay (e.g., 0.99 in Q24 retains 99% per block)
    uint24 optimalFeeE6; // Fee rate defining optimal range width in PRICE space (not sqrt price), 1e6 precision
    uint8 targetMultiplier; // Multiplier for target fee: targetFee = farBoundaryFee - closeBoundaryFee * targetMultiplier / 100. Must be 0-100.
    uint160 referenceSqrtPriceX96; // Reference center point in sqrt Q96 format
}

// Fee state snapshot, only updated on the first swap in a new block
struct StableFeeState {
    uint40 decayingFeeE12; // Decaying fee in 1e12 precision, or UNDEFINED_DECAYING_FEE_E12 if inside optimal range
    uint160 sqrtAmmPriceX96; // AMM sqrt price at the start of the most recently swapped block; used as cached price for same-block swaps and cross-block price movement detection (0 when the pool is initialized or reset)
    uint40 blockNumber; // Block number of the most recent feeState write (first swap of a block, or pool init/config reset); used to detect same-block swaps and compute blocks elapsed for decay.
}

/// @notice Interface for the StableFeeConfiguration
interface IStableFeeConfiguration {
    /// @notice Error thrown when k is invalid (zero would mean instant decay)
    /// @param k The invalid k value
    error InvalidK(uint256 k);

    /// @notice Error thrown when optimal fee is invalid
    /// @param optimalFeeE6 The invalid optimal fee
    error InvalidOptimalFeeE6(uint256 optimalFeeE6);

    /// @notice Error thrown when reference sqrt price is invalid
    /// @param invalidSqrtPrice The invalid reference sqrt price
    error InvalidReferenceSqrtPriceX96(uint256 invalidSqrtPrice);

    /// @notice Error thrown when target multiplier is invalid (must be 0-100)
    /// @param targetMultiplier The invalid target multiplier
    error InvalidTargetMultiplier(uint256 targetMultiplier);

    /// @notice Error thrown when the poolIds and feeConfigs arrays have different lengths
    error LengthMismatch();

    /// @notice Event emitted when the fee config is updated
    /// @param poolId The ID of the pool
    /// @param feeConfig The new fee config
    event FeeConfigUpdated(PoolId indexed poolId, StableFeeConfig feeConfig);

    /// @notice Update the fee config for a pool
    /// @param poolId The ID of the pool
    /// @param feeConfig The new fee config
    function updateFeeConfig(PoolId poolId, StableFeeConfig calldata feeConfig) external;

    /// @notice Update the fee config for multiple pools in a single call
    /// @param poolIds The IDs of the pools to update
    /// @param feeConfigs The new fee configs for each pool, index-aligned with `poolIds`
    function batchUpdateFeeConfig(PoolId[] calldata poolIds, StableFeeConfig[] calldata feeConfigs) external;
}
