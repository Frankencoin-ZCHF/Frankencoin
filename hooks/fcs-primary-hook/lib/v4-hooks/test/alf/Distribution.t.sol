// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {
    Distribution,
    LiquidityBucket,
    MAX_BUCKETS,
    TOTAL_WEIGHT_BPS,
    InvalidDistribution,
    InvalidTickRange,
    computeAllocations,
    activeLiquidity
} from "../../src/alf/types/Distribution.sol";

/// @notice Harness exposing the `Distribution` storage type's stateful surface ({set}/{get}). The
///         `Distribution` struct holds a `mapping`, so it cannot live in memory; the harness owns one
///         storage instance and forwards calls to the free functions attached via `using ... global`.
///         The pure allocation helpers ({computeAllocations}, {activeLiquidity}) take a
///         `LiquidityBucket[] memory` and are called directly from the tests, not through the harness.
contract DistributionHarness {
    Distribution internal _dist;

    /// @dev Validate and store `buckets` for `poolId`; reverts bubble up to the test verbatim.
    function set(PoolId poolId, LiquidityBucket[] calldata buckets, int24 tickSpacing) external {
        _dist.set(poolId, buckets, tickSpacing);
    }

    /// @dev Read back the stored buckets for `poolId`.
    function get(PoolId poolId) external view returns (LiquidityBucket[] memory) {
        return _dist.get(poolId);
    }
}

/// @title DistributionTest
/// @notice Isolated unit tests for the `Distribution` liquidity-distribution capability. The {set}
///         validation branches and the pure allocation math are otherwise only exercised in aggregate
///         through `DualPoolHook`'s fuzzing; here each rejection branch is asserted against its specific
///         selector, and the allocation helpers are unit-tested with structural assertions over price
///         positions relative to each bucket's range.
contract DistributionTest is Test {
    DistributionHarness internal h;

    PoolId internal poolA = PoolId.wrap(bytes32(uint256(0xA)));

    /// @dev tickSpacing used across set tests. 10 is the common 0.3%-pool spacing.
    int24 internal constant SPACING = 10;

    function setUp() public {
        h = new DistributionHarness();
    }

    // ══════════════════════════════════════════════════════════
    //  Helpers
    // ══════════════════════════════════════════════════════════

    /// @dev A single full-weight bucket spanning [tickLower, tickUpper].
    function _single(int24 tickLower, int24 tickUpper) internal pure returns (LiquidityBucket[] memory b) {
        b = new LiquidityBucket[](1);
        b[0] = LiquidityBucket({tickLower: tickLower, tickUpper: tickUpper, weightBps: uint16(TOTAL_WEIGHT_BPS)});
    }

    /// @dev A valid, well-formed default distribution: one full-weight bucket centered on the price.
    function _validSingle() internal pure returns (LiquidityBucket[] memory) {
        return _single(-SPACING, SPACING);
    }

    // ══════════════════════════════════════════════════════════
    //  set — rejection branches (each asserted with its SPECIFIC selector)
    // ══════════════════════════════════════════════════════════

    function test_set_revertsOnEmptyDistribution() public {
        LiquidityBucket[] memory empty = new LiquidityBucket[](0);
        vm.expectRevert(InvalidDistribution.selector);
        h.set(poolA, empty, SPACING);
    }

    function test_set_revertsWhenExceedsMaxBuckets() public {
        // MAX_BUCKETS + 1 entries: tripped before any weight/tick validation by the count guard.
        uint256 n = uint256(MAX_BUCKETS) + 1;
        LiquidityBucket[] memory tooMany = new LiquidityBucket[](n);
        for (uint256 i; i < n; ++i) {
            // Distinct, aligned, in-range ranges so only the count is wrong; weights are irrelevant
            // because the length guard fires first.
            int24 lo = int24(int256(i + 1)) * SPACING;
            tooMany[i] = LiquidityBucket({tickLower: lo, tickUpper: lo + SPACING, weightBps: 1});
        }
        vm.expectRevert(InvalidDistribution.selector);
        h.set(poolA, tooMany, SPACING);
    }

    function test_set_revertsWhenTickLowerNotBelowUpper() public {
        // Equal ticks: lower >= upper is the FIRST per-bucket check, so it reverts InvalidTickRange.
        LiquidityBucket[] memory b = _single(SPACING, SPACING);
        vm.expectRevert(InvalidTickRange.selector);
        h.set(poolA, b, SPACING);
    }

    function test_set_revertsWhenTicksOutOfTickMathRange() public {
        // tickSpacing = 1 makes every int tick aligned, so the alignment check cannot pre-empt the
        // out-of-range check. tickUpper > MAX_TICK must therefore revert via the bounds branch.
        LiquidityBucket[] memory hi = _single(0, TickMath.MAX_TICK + 1);
        vm.expectRevert(InvalidTickRange.selector);
        h.set(poolA, hi, 1);

        // Symmetric lower bound: tickLower < MIN_TICK, also aligned at spacing 1.
        LiquidityBucket[] memory lo = _single(TickMath.MIN_TICK - 1, 0);
        vm.expectRevert(InvalidTickRange.selector);
        h.set(poolA, lo, 1);
    }

    function test_set_revertsWhenTicksNotAlignedToSpacing() public {
        // In-range, lower < upper, but not divisible by SPACING (10): the alignment branch fires.
        LiquidityBucket[] memory b = _single(-5, 7);
        vm.expectRevert(InvalidTickRange.selector);
        h.set(poolA, b, SPACING);
    }

    function test_set_revertsOnZeroWeightBucket() public {
        // Two buckets whose weights would otherwise sum to TOTAL_WEIGHT_BPS, but one has zero weight.
        // The per-bucket zero-weight guard fires before the final sum check.
        LiquidityBucket[] memory b = new LiquidityBucket[](2);
        b[0] = LiquidityBucket({tickLower: -SPACING, tickUpper: SPACING, weightBps: uint16(TOTAL_WEIGHT_BPS)});
        b[1] = LiquidityBucket({tickLower: 2 * SPACING, tickUpper: 3 * SPACING, weightBps: 0});
        vm.expectRevert(InvalidDistribution.selector);
        h.set(poolA, b, SPACING);
    }

    function test_set_revertsWhenWeightsDoNotSumToTotal() public {
        // Single valid bucket but weight is one bps short of TOTAL_WEIGHT_BPS: only the final sum
        // check can catch this (the bucket itself is well-formed and non-zero).
        LiquidityBucket[] memory b = new LiquidityBucket[](1);
        b[0] = LiquidityBucket({tickLower: -SPACING, tickUpper: SPACING, weightBps: uint16(TOTAL_WEIGHT_BPS) - 1});
        vm.expectRevert(InvalidDistribution.selector);
        h.set(poolA, b, SPACING);
    }

    // ══════════════════════════════════════════════════════════
    //  set / get — happy path
    // ══════════════════════════════════════════════════════════

    function test_set_storesSingleBucket() public {
        h.set(poolA, _validSingle(), SPACING);

        LiquidityBucket[] memory stored = h.get(poolA);
        assertEq(stored.length, 1, "one bucket stored");
        assertEq(stored[0].tickLower, -SPACING);
        assertEq(stored[0].tickUpper, SPACING);
        assertEq(uint256(stored[0].weightBps), TOTAL_WEIGHT_BPS, "full weight");
    }

    function test_set_storesMultiBucketInOrder() public {
        LiquidityBucket[] memory b = new LiquidityBucket[](3);
        b[0] = LiquidityBucket({tickLower: -SPACING, tickUpper: SPACING, weightBps: 7_500});
        b[1] = LiquidityBucket({tickLower: -3 * SPACING, tickUpper: 3 * SPACING, weightBps: 1_500});
        b[2] = LiquidityBucket({tickLower: -6 * SPACING, tickUpper: 6 * SPACING, weightBps: 1_000});

        h.set(poolA, b, SPACING);

        LiquidityBucket[] memory stored = h.get(poolA);
        assertEq(stored.length, 3, "three buckets stored");

        uint256 sum;
        for (uint256 i; i < stored.length; ++i) {
            assertEq(stored[i].tickLower, b[i].tickLower, "tickLower preserved in order");
            assertEq(stored[i].tickUpper, b[i].tickUpper, "tickUpper preserved in order");
            assertEq(stored[i].weightBps, b[i].weightBps, "weightBps preserved in order");
            sum += stored[i].weightBps;
        }
        assertEq(sum, TOTAL_WEIGHT_BPS, "stored weights sum to total");
    }

    function test_set_overwritesPreviousDistribution() public {
        // First a 3-bucket distribution, then a 1-bucket one: `set` deletes before re-pushing, so
        // get() must reflect ONLY the latest write (no stale trailing buckets).
        LiquidityBucket[] memory three = new LiquidityBucket[](3);
        three[0] = LiquidityBucket({tickLower: -SPACING, tickUpper: SPACING, weightBps: 7_500});
        three[1] = LiquidityBucket({tickLower: -3 * SPACING, tickUpper: 3 * SPACING, weightBps: 1_500});
        three[2] = LiquidityBucket({tickLower: -6 * SPACING, tickUpper: 6 * SPACING, weightBps: 1_000});
        h.set(poolA, three, SPACING);
        assertEq(h.get(poolA).length, 3, "3 buckets before overwrite");

        h.set(poolA, _validSingle(), SPACING);
        LiquidityBucket[] memory stored = h.get(poolA);
        assertEq(stored.length, 1, "overwrite shrinks to 1 bucket, no stale tail");
        assertEq(stored[0].tickLower, -SPACING);
        assertEq(stored[0].tickUpper, SPACING);
    }

    function test_get_returnsEmptyForUnsetPool() public view {
        assertEq(h.get(poolA).length, 0, "unset pool yields empty distribution");
    }

    // ══════════════════════════════════════════════════════════
    //  computeAllocations — pure unit tests
    // ══════════════════════════════════════════════════════════

    /// @dev Sum the active part of the fixed `liqs` array up to `n` entries.
    function _sumLiqs(uint128[MAX_BUCKETS] memory liqs, uint256 n) internal pure returns (uint256 total) {
        for (uint256 i; i < n; ++i) {
            total += liqs[i];
        }
    }

    function test_computeAllocations_singleInRange_producesLiquidity() public pure {
        // Price at tick 0, symmetric range straddling it: both tokens are consumed and liquidity > 0.
        uint160 price = TickMath.getSqrtPriceAtTick(0);
        uint256 bal0 = 1_000e18;
        uint256 bal1 = 1_000e18;

        LiquidityBucket[] memory b = new LiquidityBucket[](1);
        b[0] = LiquidityBucket({tickLower: -SPACING, tickUpper: SPACING, weightBps: uint16(TOTAL_WEIGHT_BPS)});

        (uint128[MAX_BUCKETS] memory liqs, uint256 totalNeed0, uint256 totalNeed1) =
            computeAllocations(b, price, bal0, bal1);

        assertGt(liqs[0], 0, "in-range bucket deploys liquidity");
        // Straddling price: both sides are needed.
        assertGt(totalNeed0, 0, "in-range bucket consumes currency0");
        assertGt(totalNeed1, 0, "in-range bucket consumes currency1");
        // Consumption never exceeds the weighted budget (here full balance for one full-weight bucket).
        assertLe(totalNeed0, bal0, "need0 within budget");
        assertLe(totalNeed1, bal1, "need1 within budget");
    }

    function test_computeAllocations_multiBucket_sumsAndStaysWithinBudget() public pure {
        uint160 price = TickMath.getSqrtPriceAtTick(0);
        uint256 bal0 = 1_000e18;
        uint256 bal1 = 1_000e18;

        LiquidityBucket[] memory b = new LiquidityBucket[](3);
        b[0] = LiquidityBucket({tickLower: -SPACING, tickUpper: SPACING, weightBps: 7_500});
        b[1] = LiquidityBucket({tickLower: -3 * SPACING, tickUpper: 3 * SPACING, weightBps: 1_500});
        b[2] = LiquidityBucket({tickLower: -6 * SPACING, tickUpper: 6 * SPACING, weightBps: 1_000});

        (uint128[MAX_BUCKETS] memory liqs, uint256 totalNeed0, uint256 totalNeed1) =
            computeAllocations(b, price, bal0, bal1);

        // All three buckets straddle the price, so each contributes liquidity.
        assertGt(liqs[0], 0, "bucket 0 in range");
        assertGt(liqs[1], 0, "bucket 1 in range");
        assertGt(liqs[2], 0, "bucket 2 in range");
        // Entries beyond the bucket count stay zero (fixed-size array, untouched tail).
        assertEq(liqs[3], 0, "unused slot stays zero");

        // Per-bucket weighted pre-budgeting: total need across buckets cannot exceed total balance.
        // (Each bucket budgets bal * weight / TOTAL; the weights sum to TOTAL, so the union is <= bal.)
        assertLe(totalNeed0, bal0, "summed need0 within total budget");
        assertLe(totalNeed1, bal1, "summed need1 within total budget");
    }

    function test_computeAllocations_priceBelowAllRanges_onlyToken0Needed() public pure {
        // Current tick far below every bucket: price < sqrtLower for all, so getLiquidityForAmounts is
        // bounded by currency0, and only currency0 is consumed (no currency1 leg).
        uint160 price = TickMath.getSqrtPriceAtTick(-100 * SPACING);
        uint256 bal0 = 1_000e18;
        uint256 bal1 = 1_000e18;

        LiquidityBucket[] memory b = new LiquidityBucket[](2);
        b[0] = LiquidityBucket({tickLower: -SPACING, tickUpper: SPACING, weightBps: 6_000});
        b[1] = LiquidityBucket({tickLower: 2 * SPACING, tickUpper: 4 * SPACING, weightBps: 4_000});

        (uint128[MAX_BUCKETS] memory liqs, uint256 totalNeed0, uint256 totalNeed1) =
            computeAllocations(b, price, bal0, bal1);

        assertGt(_sumLiqs(liqs, b.length), 0, "below-range buckets still size off currency0");
        assertGt(totalNeed0, 0, "currency0 consumed when price is below all ranges");
        assertEq(totalNeed1, 0, "no currency1 consumed below all ranges");
        assertLe(totalNeed0, bal0, "need0 within budget");
    }

    function test_computeAllocations_priceAboveAllRanges_onlyToken1Needed() public pure {
        // Current price far above every bucket: price > sqrtUpper for all, bounded by currency1, only
        // currency1 is consumed (no currency0 leg).
        uint160 price = TickMath.getSqrtPriceAtTick(100 * SPACING);
        uint256 bal0 = 1_000e18;
        uint256 bal1 = 1_000e18;

        LiquidityBucket[] memory b = new LiquidityBucket[](2);
        b[0] = LiquidityBucket({tickLower: -SPACING, tickUpper: SPACING, weightBps: 6_000});
        b[1] = LiquidityBucket({tickLower: -4 * SPACING, tickUpper: -2 * SPACING, weightBps: 4_000});

        (uint128[MAX_BUCKETS] memory liqs, uint256 totalNeed0, uint256 totalNeed1) =
            computeAllocations(b, price, bal0, bal1);

        assertGt(_sumLiqs(liqs, b.length), 0, "above-range buckets still size off currency1");
        assertEq(totalNeed0, 0, "no currency0 consumed above all ranges");
        assertGt(totalNeed1, 0, "currency1 consumed when price is above all ranges");
        assertLe(totalNeed1, bal1, "need1 within budget");
    }

    function test_computeAllocations_zeroBalances_yieldZeroLiquidity() public pure {
        // Empty deployable balance: getLiquidityForAmounts returns 0, and nothing is consumed.
        uint160 price = TickMath.getSqrtPriceAtTick(0);

        LiquidityBucket[] memory b = new LiquidityBucket[](1);
        b[0] = LiquidityBucket({tickLower: -SPACING, tickUpper: SPACING, weightBps: uint16(TOTAL_WEIGHT_BPS)});

        (uint128[MAX_BUCKETS] memory liqs, uint256 totalNeed0, uint256 totalNeed1) = computeAllocations(b, price, 0, 0);

        assertEq(liqs[0], 0, "no balance => no liquidity");
        assertEq(totalNeed0, 0, "no balance => no currency0 need");
        assertEq(totalNeed1, 0, "no balance => no currency1 need");
    }

    // ══════════════════════════════════════════════════════════
    //  activeLiquidity — pure unit tests
    // ══════════════════════════════════════════════════════════

    function test_activeLiquidity_singleInRange_isPositive() public pure {
        int24 tick = 0;
        uint160 price = TickMath.getSqrtPriceAtTick(tick);

        LiquidityBucket[] memory b = new LiquidityBucket[](1);
        b[0] = LiquidityBucket({tickLower: -SPACING, tickUpper: SPACING, weightBps: uint16(TOTAL_WEIGHT_BPS)});

        uint128 liq = activeLiquidity(b, price, tick, 1_000e18, 1_000e18);
        assertGt(liq, 0, "tick within [lower, upper) => active liquidity");
    }

    function test_activeLiquidity_multiBucket_sumsOnlyInRange() public pure {
        int24 tick = 0;
        uint160 price = TickMath.getSqrtPriceAtTick(tick);
        uint256 bal0 = 1_000e18;
        uint256 bal1 = 1_000e18;

        // Bucket 0 and 1 straddle tick 0 (active); bucket 2 is entirely above the tick (inactive).
        LiquidityBucket[] memory full = new LiquidityBucket[](3);
        full[0] = LiquidityBucket({tickLower: -SPACING, tickUpper: SPACING, weightBps: 5_000});
        full[1] = LiquidityBucket({tickLower: -3 * SPACING, tickUpper: 3 * SPACING, weightBps: 3_000});
        full[2] = LiquidityBucket({tickLower: 5 * SPACING, tickUpper: 7 * SPACING, weightBps: 2_000});

        uint128 liqFull = activeLiquidity(full, price, tick, bal0, bal1);

        // Same first two buckets in isolation: must equal the multi-bucket result, since the
        // out-of-range third bucket contributes nothing. Each in-range bucket sizes off its OWN
        // weighted slice of the balance, so dropping an inactive bucket leaves the active sum intact.
        LiquidityBucket[] memory active = new LiquidityBucket[](2);
        active[0] = full[0];
        active[1] = full[1];
        uint128 liqActiveOnly = activeLiquidity(active, price, tick, bal0, bal1);

        assertGt(liqFull, 0, "in-range buckets contribute liquidity");
        assertEq(liqFull, liqActiveOnly, "out-of-range bucket contributes zero to the sum");
    }

    function test_activeLiquidity_priceBelowAllRanges_isZero() public pure {
        // Tick below every bucket's lower bound: none are active.
        int24 tick = -100 * SPACING;
        uint160 price = TickMath.getSqrtPriceAtTick(tick);

        LiquidityBucket[] memory b = new LiquidityBucket[](2);
        b[0] = LiquidityBucket({tickLower: -SPACING, tickUpper: SPACING, weightBps: 6_000});
        b[1] = LiquidityBucket({tickLower: 2 * SPACING, tickUpper: 4 * SPACING, weightBps: 4_000});

        uint128 liq = activeLiquidity(b, price, tick, 1_000e18, 1_000e18);
        assertEq(liq, 0, "tick below all ranges => no active liquidity");
    }

    function test_activeLiquidity_priceAboveAllRanges_isZero() public pure {
        // Tick at or above every bucket's upper bound: the range is [lower, upper), so a tick equal to
        // the highest upper is out of range too.
        int24 tick = 100 * SPACING;
        uint160 price = TickMath.getSqrtPriceAtTick(tick);

        LiquidityBucket[] memory b = new LiquidityBucket[](2);
        b[0] = LiquidityBucket({tickLower: -SPACING, tickUpper: SPACING, weightBps: 6_000});
        b[1] = LiquidityBucket({tickLower: -4 * SPACING, tickUpper: -2 * SPACING, weightBps: 4_000});

        uint128 liq = activeLiquidity(b, price, tick, 1_000e18, 1_000e18);
        assertEq(liq, 0, "tick above all ranges => no active liquidity");
    }

    function test_activeLiquidity_upperBoundIsExclusive() public pure {
        // The in-range predicate is `tick >= lower && tick < upper`: a tick exactly at `upper` is NOT
        // active. Lock that exclusivity in.
        int24 tick = SPACING;
        uint160 price = TickMath.getSqrtPriceAtTick(tick);

        LiquidityBucket[] memory b = new LiquidityBucket[](1);
        b[0] = LiquidityBucket({tickLower: -SPACING, tickUpper: SPACING, weightBps: uint16(TOTAL_WEIGHT_BPS)});

        uint128 liq = activeLiquidity(b, price, tick, 1_000e18, 1_000e18);
        assertEq(liq, 0, "tick == upper is exclusive => no active liquidity");
    }

    function test_activeLiquidity_zeroBalances_isZero() public pure {
        int24 tick = 0;
        uint160 price = TickMath.getSqrtPriceAtTick(tick);

        LiquidityBucket[] memory b = new LiquidityBucket[](1);
        b[0] = LiquidityBucket({tickLower: -SPACING, tickUpper: SPACING, weightBps: uint16(TOTAL_WEIGHT_BPS)});

        uint128 liq = activeLiquidity(b, price, tick, 0, 0);
        assertEq(liq, 0, "in range but no balance => zero liquidity");
    }
}
