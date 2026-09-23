// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @dev Lower bound on `PoolConfig.binsPerSide`. A book with zero bins per side cannot quote.
uint8 constant MIN_BINS_PER_SIDE = 1;

/// @dev Upper bound on `PoolConfig.binsPerSide`. Offsets are encoded as `int8` and tracked in a
///      256-bit seen-bitmap per side, and 32 bins per side keeps ladder replacement gas bounded.
uint8 constant MAX_BINS_PER_SIDE = 32;

/// @dev Upper bound on `PoolConfig.maxMakerBins`, matching the per-side offset ceiling.
uint8 constant MAX_MAKER_BINS = 32;

/// @dev Upper bound on `PoolConfig.maxRetirePerSwap`. Caps the opportunistic retirement work a
///      single swap can be charged for.
uint8 constant MAX_RETIRE_PER_SWAP = 16;

/// @dev A `PoolConfig` failed validation at pool initialization: non-positive or misaligned
///      `binSpacingTicks`, out-of-range bin counts, zero TTL, or zero minimum liquidity.
error InvalidPoolConfig();

/// @notice Pool-level parameters for canonical maker bins.
/// @param binSpacingTicks Width of each book bin. Must be positive and aligned to the pool tick spacing.
/// @param binsPerSide Number of canonical bid/ask bins available on each side.
/// @param maxMakerBins Maximum active bins a single maker can maintain per pool.
/// @param maxRetirePerSwap Maximum stale/crossed positions retired opportunistically per swap hook.
/// @param maxQuoteTtl Maximum ladder lifetime, in seconds.
/// @param minBinLiquidity Minimum v4 liquidity for a newly posted bin.
struct PoolConfig {
    int24 binSpacingTicks;
    uint8 binsPerSide;
    uint8 maxMakerBins;
    uint8 maxRetirePerSwap;
    uint40 maxQuoteTtl;
    uint128 minBinLiquidity;
}

/// @title BookConfig
/// @author Uniswap Labs
/// @notice Per-pool canonical book configuration for NativeBook hooks, as a type-driven value.
///         Set once at pool initialization via {set}, which validates the supplied `PoolConfig`
///         against the file-level bounds, and read on the swap and ladder paths via {get}.
/// @param _inner The per-pool configuration store.
/// @custom:security-contact security@uniswap.org
struct BookConfig {
    mapping(PoolId poolId => PoolConfig) _inner;
}

using {set, get} for BookConfig global;

/// @notice Validate and store `config` for `poolId`.
/// @dev Reverts {InvalidPoolConfig} unless every field is within bounds and `binSpacingTicks`
///      is a positive multiple of the pool's tick spacing.
/// @param self        BookConfig storage.
/// @param poolId      The pool to configure.
/// @param tickSpacing The pool's tick spacing, for bin alignment validation.
/// @param config      The configuration to store.
function set(BookConfig storage self, PoolId poolId, int24 tickSpacing, PoolConfig calldata config) {
    if (
        config.binSpacingTicks <= 0 || config.binSpacingTicks % tickSpacing != 0
            || config.binsPerSide < MIN_BINS_PER_SIDE || config.binsPerSide > MAX_BINS_PER_SIDE
            || config.maxMakerBins == 0 || config.maxMakerBins > MAX_MAKER_BINS
            || config.maxRetirePerSwap > MAX_RETIRE_PER_SWAP || config.maxQuoteTtl == 0 || config.minBinLiquidity == 0
    ) {
        revert InvalidPoolConfig();
    }
    self._inner[poolId] = config;
}

/// @notice Read the configuration stored for `poolId`.
/// @dev Returns a storage pointer; callers that need a snapshot copy to memory. A pool that was
///      never configured returns the zero config (`binSpacingTicks == 0`).
/// @param self   BookConfig storage.
/// @param poolId The pool to read.
/// @return The pool's configuration.
function get(BookConfig storage self, PoolId poolId) view returns (PoolConfig storage) {
    return self._inner[poolId];
}
