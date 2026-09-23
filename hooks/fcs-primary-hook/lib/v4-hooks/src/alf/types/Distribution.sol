// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

/// @dev Maximum buckets per pool. Bounds the JIT cycle's gas: each bucket costs one
///      `modifyLiquidity` to deploy and one to remove, so cost scales linearly with the count.
uint8 constant MAX_BUCKETS = 8;

/// @dev Basis-points denominator for distribution weights. Every pool's `weightBps` values sum to
///      this, and it is the divisor when pro-budgeting each bucket's slice of the pool balance.
uint256 constant TOTAL_WEIGHT_BPS = 10_000;

/// @dev Distribution is invalid: empty, exceeds `MAX_BUCKETS`, weights do not sum to
///      `TOTAL_WEIGHT_BPS`, or a bucket has zero weight.
error InvalidDistribution();
/// @dev A bucket's tick range is malformed: lower >= upper, outside the `TickMath` range, or not
///      aligned to the pool's tickSpacing.
error InvalidTickRange();

/// @notice A tick range with a weight for liquidity distribution.
/// @param tickLower Lower tick boundary (aligned to the pool's tickSpacing).
/// @param tickUpper Upper tick boundary (aligned to the pool's tickSpacing).
/// @param weightBps Fraction of total capital allocated to this range, in basis points. All
///                  weights across a pool's distribution sum to `TOTAL_WEIGHT_BPS`.
struct LiquidityBucket {
    int24 tickLower;
    int24 tickUpper;
    uint16 weightBps;
}

/// @title Distribution
/// @author Uniswap Labs
/// @notice Per-pool JIT liquidity distribution as a type-driven value: the bucket set plus its
///         validation. A hook holds a `Distribution` storage field, configures it via {set}, and
///         reads the buckets via {get}. The pure allocation math ({computeAllocations},
///         {activeLiquidity}) is provided as free functions over a `LiquidityBucket[] memory`, so
///         the hook fetches the buckets once and runs both the sizing math and its own
///         `modifyLiquidity` deploy/remove loop against the same array.
/// @param _inner The bucket list per pool.
/// @custom:security-contact security@uniswap.org
struct Distribution {
    mapping(PoolId poolId => LiquidityBucket[]) _inner;
}

using {set, get} for Distribution global;

/// @notice Validate and store a liquidity distribution for `poolId`. Enforces 1 to `MAX_BUCKETS`
///         entries, tickSpacing-aligned ranges within the `TickMath` range, no zero-weight bucket,
///         and weights summing to exactly `TOTAL_WEIGHT_BPS`.
/// @param self        Distribution storage.
/// @param poolId      The pool to configure.
/// @param buckets     The distribution buckets to validate and store.
/// @param tickSpacing The pool's tick spacing, for alignment validation.
function set(Distribution storage self, PoolId poolId, LiquidityBucket[] calldata buckets, int24 tickSpacing) {
    uint256 n = buckets.length;
    if (n == 0 || n > MAX_BUCKETS) revert InvalidDistribution();

    uint256 totalWeight;
    for (uint256 i; i < n; ++i) {
        if (buckets[i].tickLower >= buckets[i].tickUpper) revert InvalidTickRange();
        // Reject ticks outside the v4 representable range; `TickMath.getSqrtPriceAtTick` would
        // otherwise revert later from inside allocation or quote paths, bricking quotes and swaps
        // for any pool with a misconfigured distribution.
        if (buckets[i].tickLower < TickMath.MIN_TICK || buckets[i].tickUpper > TickMath.MAX_TICK) {
            revert InvalidTickRange();
        }
        if (buckets[i].tickLower % tickSpacing != 0 || buckets[i].tickUpper % tickSpacing != 0) {
            revert InvalidTickRange();
        }
        if (buckets[i].weightBps == 0) revert InvalidDistribution();
        totalWeight += buckets[i].weightBps;
    }
    if (totalWeight != TOTAL_WEIGHT_BPS) revert InvalidDistribution();

    delete self._inner[poolId];

    for (uint256 i; i < n; ++i) {
        self._inner[poolId].push(buckets[i]);
    }
}

/// @notice The configured buckets for `poolId`.
/// @param self   Distribution storage.
/// @param poolId The pool to read.
/// @return The pool's bucket list (tick ranges and weights).
function get(Distribution storage self, PoolId poolId) view returns (LiquidityBucket[] memory) {
    return self._inner[poolId];
}

/// @notice Compute the weighted liquidity to deploy per bucket and the total token amounts the
///         deployment needs, at the current price.
/// @dev Each bucket is pre-budgeted against its weighted share of the balance, so the summed
///      liquidity matches what the pool can actually deploy (passing the full balance to
///      `getLiquidityForAmounts` and post-scaling would over-count across in-range buckets). The
///      result array is indexed by bucket position, matching the caller's deploy/remove order.
/// @param buckets      The pool's buckets (caller fetches via {get}).
/// @param sqrtPriceX96 The current pool sqrt price (Q64.96).
/// @param bal0         The deployable currency0 balance.
/// @param bal1         The deployable currency1 balance.
/// @return liqs       Per-bucket liquidity to deploy, indexed by position.
/// @return totalNeed0 Total currency0 the deployment consumes.
/// @return totalNeed1 Total currency1 the deployment consumes.
function computeAllocations(LiquidityBucket[] memory buckets, uint160 sqrtPriceX96, uint256 bal0, uint256 bal1)
    pure
    returns (uint128[MAX_BUCKETS] memory liqs, uint256 totalNeed0, uint256 totalNeed1)
{
    uint256 n = buckets.length;
    for (uint256 i; i < n; ++i) {
        LiquidityBucket memory bucket = buckets[i];
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(bucket.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(bucket.tickUpper);

        uint256 weightBps = bucket.weightBps;
        uint256 weightedBal0 = bal0 * weightBps / TOTAL_WEIGHT_BPS;
        uint256 weightedBal1 = bal1 * weightBps / TOTAL_WEIGHT_BPS;
        uint128 liq =
            LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtLower, sqrtUpper, weightedBal0, weightedBal1);
        liqs[i] = liq;

        if (liq > 0) {
            if (sqrtPriceX96 < sqrtUpper) {
                uint160 upper = sqrtPriceX96 < sqrtLower ? sqrtLower : sqrtPriceX96;
                totalNeed0 += SqrtPriceMath.getAmount0Delta(upper, sqrtUpper, liq, true);
            }
            if (sqrtPriceX96 > sqrtLower) {
                uint160 lower = sqrtPriceX96 > sqrtUpper ? sqrtUpper : sqrtPriceX96;
                totalNeed1 += SqrtPriceMath.getAmount1Delta(sqrtLower, lower, liq, true);
            }
        }
    }
}

/// @notice Sum the in-range liquidity the buckets would deploy at the current tick, for an
///         indicative quote. Uses the same per-bucket weighted-balance pre-budgeting as
///         {computeAllocations} so the indicative tracks what the JIT cycle actually deploys.
/// @param buckets      The pool's buckets (caller fetches via {get}).
/// @param sqrtPriceX96 The current pool sqrt price (Q64.96).
/// @param currentTick  The current pool tick.
/// @param bal0         The deployable currency0 balance.
/// @param bal1         The deployable currency1 balance.
/// @return liquidity The total active (in-range) liquidity.
function activeLiquidity(
    LiquidityBucket[] memory buckets,
    uint160 sqrtPriceX96,
    int24 currentTick,
    uint256 bal0,
    uint256 bal1
) pure returns (uint128 liquidity) {
    uint256 n = buckets.length;
    for (uint256 i; i < n; ++i) {
        LiquidityBucket memory bucket = buckets[i];
        if (currentTick >= bucket.tickLower && currentTick < bucket.tickUpper) {
            uint256 weightBps = bucket.weightBps;
            uint256 weightedBal0 = bal0 * weightBps / TOTAL_WEIGHT_BPS;
            uint256 weightedBal1 = bal1 * weightBps / TOTAL_WEIGHT_BPS;
            liquidity += LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(bucket.tickLower),
                TickMath.getSqrtPriceAtTick(bucket.tickUpper),
                weightedBal0,
                weightedBal1
            );
        }
    }
}
