// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {StableFeeCalculation} from "../../../src/stable/libraries/StableFeeCalculation.sol";
import {StableFeeConfigurationImplementation} from "../base/StableFeeConfigurationImplementation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {StablePairTestBase} from "../base/StablePairTestBase.sol";

/// @notice Direct tests of the fee-math library
/// forge-config: default.fuzz.runs = 2048
contract StableFeeCalculationTest is StablePairTestBase {
    uint256 internal MAX_OPTIMAL_FEE_E6;
    uint256 internal MAX_TARGET_MULTIPLIER;

    uint256 internal constant TARGET_FEE_E12 = 100_000_000;
    uint256 internal constant PREVIOUS_FEE_E12 = 500_000_000;

    function setUp() public override {
        StableFeeConfigurationImplementation validator = new StableFeeConfigurationImplementation(address(this));
        MAX_OPTIMAL_FEE_E6 = validator.MAX_OPTIMAL_FEE_E6();
        MAX_TARGET_MULTIPLIER = validator.MAX_TARGET_MULTIPLIER();
    }

    function test_constants_logKMatchesLibraryDerivation() public pure {
        assertEq(StableFeeCalculation.deriveLogK(K), LOG_K);
    }

    /// @notice The library derivation must match the test base's independent mirror for every
    /// nonzero k (the invariant the contract used to enforce by storing the derived value).
    function test_fuzz_deriveLogK_matchesReference(uint24 k) public pure {
        k = uint24(bound(k, 1, type(uint24).max));
        assertEq(StableFeeCalculation.deriveLogK(k), deriveLogK(k));
    }

    /// @notice Regression for the uint40 logK widening: the old uint24 scheme
    /// (`ceil(-ln(k) / 2^40)`, runtime `logK << 40`) quantized the slow-path exponent so
    /// coarsely that in the worst bucket (k = uint24 max, the slowest representable decay)
    /// it derived logK = 1 — an exponent ~18x the true `-ln(k)` — so a 5-block gap decayed
    /// far below the exact `k^5`. The uint40 scheme (`ceil(-ln(k) / 2^24)`, runtime
    /// `logK << 24`) tracks the exact factor to within a couple of X24 ulps, erring on the
    /// fast side (ceil) by design.
    function test_logKQuantization_uint40SchemeTracksExactDecay_worstBucket() public pure {
        uint256 k = type(uint24).max;
        uint256 blocksPassed = 5; // first slow-path gap, right after the fast path ends at 4 blocks

        // Exact 5-block factor: fastPow is exact (up to Q24 truncation) for n <= 4, one more Q24 mul.
        uint256 exactFactorX24 = (StableFeeCalculation.fastPow(k, 4) * k) >> 24;

        int256 lnK = FixedPointMathLib.lnWad(int256((k * 1e18) >> 24));

        // OLD uint24 scheme: derives logK = 1 for this k and reconstructs the exponent << 40.
        uint256 oldLogK = (uint256(-lnK) + ((uint256(1) << 40) - 1)) >> 40;
        assertEq(oldLogK, 1);
        uint256 oldFactorX24 = (uint256(FixedPointMathLib.expWad(-int256((oldLogK << 40) * blocksPassed))) << 24) / 1e18;

        // NEW scheme, exactly as the slow path derives and reconstructs it at swap time. This is
        // the worst quantization bucket: -ln(k) / 2^24 ≈ 3552.7, ceil-derived to 3553, keeping
        // the error below ~1/3552 (the old scheme's logK = 1 was ~18x off).
        uint256 newLogK = StableFeeCalculation.deriveLogK(k);
        assertEq(newLogK, 3553);
        uint256 newFactorX24 = (uint256(FixedPointMathLib.expWad(-int256((newLogK << 24) * blocksPassed))) << 24) / 1e18;

        // Old: decay ran visibly faster than k implies (factor tens of X24 ulps below exact).
        assertGt(exactFactorX24, oldFactorX24);
        assertGt(exactFactorX24 - oldFactorX24, 20);

        // New: within a couple of X24 ulps of the exact factor.
        uint256 newError = newFactorX24 > exactFactorX24 ? newFactorX24 - exactFactorX24 : exactFactorX24 - newFactorX24;
        assertLe(newError, 3);
    }

    // =============================================================================
    // INVARIANT: the fee v4 actually charges is never 100%
    // At 1e6 exact-output swaps revert and exact-input swaps are consumed entirely as
    // fee, so no swap can move the price through active liquidity — leaving no way to
    // move a saturated pool back toward reference (see invariant 1b in the technical
    // doc). The charged fee is NOT the hook's LP fee alone: Pool.swap
    // compounds it with the directional protocol fee (protocol taken first, LP fee on
    // the remainder) and rounds the result UP to a whole pip. An LP fee of 999_999
    // therefore compounds to exactly 1e6 for ANY nonzero protocol fee, so toFeeE6 must
    // leave a pip of headroom: max return is 999_998, which compounds to at most 999_999.
    // =============================================================================

    function test_toFeeE6_clampsSaturatedFeeBelowMax() public pure {
        // The far-boundary fee saturates to exactly ONE_E12 when priceRatio < ~1e-12;
        // conversion must clamp to the largest chargeable fee.
        assertEq(StableFeeCalculation.toFeeE6(StableFeeCalculation.ONE_E12), 999_998);
        // 999_999 is reachable by plain truncation too (no saturation needed) and is just
        // as poisoned once the protocol fee compounds on top — it must also be clamped.
        assertEq(StableFeeCalculation.toFeeE6(999_999 * StableFeeCalculation.ONE_E6), 999_998);
        assertEq(StableFeeCalculation.toFeeE6(999_998 * StableFeeCalculation.ONE_E6), 999_998);
    }

    // =============================================================================
    // INVARIANT: converting E12 -> E6 never rounds a nonzero fee down to a lower pip
    // toFeeE6 rounds UP, so a decaying fee that converged below 1 pip (reachable with
    // targetMultiplier = 100 under extreme depeg, or optimalFeeE6 = 0 configs) charges
    // 1 pip instead of becoming an explicit 0-fee override in _beforeSwap.
    // A genuinely zero fee (the away-from-reference direction) still charges zero.
    // =============================================================================

    function test_toFeeE6_roundsUp() public pure {
        // Zero stays zero: the away-from-reference direction passes a literal 0
        assertEq(StableFeeCalculation.toFeeE6(0), 0);
        // Nonzero sub-pip fees charge 1 pip instead of truncating to 0
        assertEq(StableFeeCalculation.toFeeE6(1), 1);
        assertEq(StableFeeCalculation.toFeeE6(StableFeeCalculation.ONE_E6 - 1), 1);
        assertEq(StableFeeCalculation.toFeeE6(StableFeeCalculation.ONE_E6), 1);
        // Exact pip multiples are unchanged; fractional pips round up
        assertEq(StableFeeCalculation.toFeeE6(123 * StableFeeCalculation.ONE_E6), 123);
        assertEq(StableFeeCalculation.toFeeE6(123 * StableFeeCalculation.ONE_E6 + 1), 124);
    }

    function test_fuzz_toFeeE6_nonzeroFeeNeverRoundsToZero(uint256 feeE12) public pure {
        feeE12 = bound(feeE12, 1, StableFeeCalculation.ONE_E12);
        assertGe(StableFeeCalculation.toFeeE6(feeE12), 1);
    }

    function test_fuzz_toFeeE6_neverUndercharges_overshootsLessThanOnePip(uint256 feeE12) public pure {
        feeE12 = bound(feeE12, 0, StableFeeCalculation.ONE_E12);
        uint256 feeE6 = StableFeeCalculation.toFeeE6(feeE12);
        if (feeE6 < StableFeeCalculation.MAX_FEE_E6) {
            // Rounds up: the charged fee is at least the exact E12 fee...
            assertGe(feeE6 * StableFeeCalculation.ONE_E6, feeE12);
            // ...and overshoots it by strictly less than one pip
            assertLt(feeE6 * StableFeeCalculation.ONE_E6, feeE12 + StableFeeCalculation.ONE_E6);
        } else {
            // At MAX_FEE_E6 the result is pinned or clamped; only fees that round up to at least
            // MAX_FEE_E6 land here (the deliberate undercharge documented on MAX_FEE_E6)
            assertGt(feeE12, (StableFeeCalculation.MAX_FEE_E6 - 1) * StableFeeCalculation.ONE_E6);
        }
    }

    function test_fuzz_toFeeE6_combinedWithProtocolFee_alwaysBelowMax(uint256 feeE12, uint16 protocolFee) public pure {
        feeE12 = bound(feeE12, 0, StableFeeCalculation.ONE_E12);
        protocolFee = uint16(bound(protocolFee, 0, ProtocolFeeLibrary.MAX_PROTOCOL_FEE));

        uint24 lpFee = StableFeeCalculation.toFeeE6(feeE12);
        // Exactly what Pool.swap computes as the swap fee charged on the input
        uint24 swapFee = protocolFee == 0 ? lpFee : ProtocolFeeLibrary.calculateSwapFee(protocolFee, lpFee);

        assertLt(swapFee, SwapMath.MAX_SWAP_FEE);
    }

    // =============================================================================
    // INVARIANT: priceRatioX96 <= Q96 (always normalized to <= 1)
    // =============================================================================

    function test_calculatePriceRatioX96_left_succeeds() public pure {
        uint160 sqrtAmmPriceX96 = uint160(uint256(FixedPoint96.Q96) * 99 / 100); // sqrt ratio 0.99
        uint256 priceRatioX96 = StableFeeCalculation.calculatePriceRatioX96(sqrtAmmPriceX96, uint160(FixedPoint96.Q96));

        // Price ratio = 0.99^2 = 0.9801
        assertApproxEqRel(priceRatioX96, uint256(FixedPoint96.Q96) * 9801 / 10_000, 1e9);
        assertLe(priceRatioX96, FixedPoint96.Q96);
    }

    function test_calculatePriceRatioX96_right_succeeds() public pure {
        uint160 sqrtAmmPriceX96 = uint160(uint256(FixedPoint96.Q96) * 101 / 100); // sqrt ratio 1.01
        uint256 priceRatioX96 = StableFeeCalculation.calculatePriceRatioX96(sqrtAmmPriceX96, uint160(FixedPoint96.Q96));

        // Above the reference the ratio normalizes to (1/1.01)^2 = 10000/10201.
        assertApproxEqRel(priceRatioX96, uint256(FixedPoint96.Q96) * 10_000 / 10_201, 1e9);
        assertLe(priceRatioX96, FixedPoint96.Q96);
    }

    function test_fuzz_calculatePriceRatioX96(uint160 sqrtAmmPriceX96, uint160 sqrtReferencePriceX96) public pure {
        sqrtAmmPriceX96 = uint160(bound(sqrtAmmPriceX96, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));
        sqrtReferencePriceX96 = uint160(bound(sqrtReferencePriceX96, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));

        uint256 priceRatioX96 = StableFeeCalculation.calculatePriceRatioX96(sqrtAmmPriceX96, sqrtReferencePriceX96);

        assertLe(priceRatioX96, FixedPoint96.Q96);
    }

    // =============================================================================
    // INVARIANT: closeFee never reverts for valid inputs
    // closeFee <= 0 means inside optimal range, > 0 means outside
    // =============================================================================

    function test_calculateCloseBoundaryFee_succeeds_inside_optimal_range() public pure {
        uint256 priceRatioX96 = FixedPoint96.Q96; // exactly at reference
        int256 closeBoundaryFeeE12 = StableFeeCalculation.calculateCloseBoundaryFee(priceRatioX96, OPTIMAL_FEE_E6);
        assertLt(closeBoundaryFeeE12, 0); // should be negative since the price is inside the optimal range

        // just inside the boundary of the optimal range: ratio = 1 - (optimalFee - 1 ppm)
        priceRatioX96 = uint256(FixedPoint96.Q96) * (StableFeeCalculation.ONE_E6 - (OPTIMAL_FEE_E6 - 1))
            / StableFeeCalculation.ONE_E6;
        closeBoundaryFeeE12 = StableFeeCalculation.calculateCloseBoundaryFee(priceRatioX96, OPTIMAL_FEE_E6);
        assertLt(closeBoundaryFeeE12, 0);
    }

    function test_calculateCloseBoundaryFee_succeeds_outside_optimal_range() public pure {
        // at the boundary of the optimal range: ratio = 1 - optimalFee
        uint256 priceRatioX96 =
            uint256(FixedPoint96.Q96) * (StableFeeCalculation.ONE_E6 - OPTIMAL_FEE_E6) / StableFeeCalculation.ONE_E6;
        int256 closeBoundaryFeeE12 = StableFeeCalculation.calculateCloseBoundaryFee(priceRatioX96, OPTIMAL_FEE_E6);
        assertGt(closeBoundaryFeeE12, 0);
    }

    function test_fuzz_calculateCloseBoundaryFee_succeeds(uint256 priceRatioX96, uint24 optimalFeeE6) public pure {
        priceRatioX96 = bound(priceRatioX96, 0, FixedPoint96.Q96);
        optimalFeeE6 = uint24(bound(optimalFeeE6, 0, StableFeeCalculation.ONE_E6 - 1));
        StableFeeCalculation.calculateCloseBoundaryFee(priceRatioX96, optimalFeeE6); // should not revert
    }

    function test_fuzz_calculateInsideOptimalRangeFee_succeeds(
        uint256 priceRatioX96,
        uint24 optimalFeeE6,
        bool ammPriceBelowRP,
        bool userSellsZeroForOne
    ) public pure {
        optimalFeeE6 = uint24(bound(optimalFeeE6, 0, StableFeeCalculation.ONE_E6 - 1));

        // Calculate the minimum priceRatioX96 that's inside the optimal range
        uint256 minPriceRatio =
            (uint256(FixedPoint96.Q96) * (StableFeeCalculation.ONE_E6 - optimalFeeE6)) / StableFeeCalculation.ONE_E6;

        // Bound priceRatioX96 to be inside the optimal range
        priceRatioX96 = bound(priceRatioX96, minPriceRatio, FixedPoint96.Q96);

        uint256 lpFeeE12 = StableFeeCalculation.calculateInsideOptimalRangeFee(
            priceRatioX96, optimalFeeE6, ammPriceBelowRP, userSellsZeroForOne
        ); // should not revert

        assertLe(lpFeeE12, StableFeeCalculation.ONE_E12);
    }

    function test_fuzz_calculateFarBoundaryFee_succeeds(uint256 priceRatioX96, uint24 optimalFeeE6) public view {
        priceRatioX96 = bound(priceRatioX96, 0, FixedPoint96.Q96);
        optimalFeeE6 = uint24(bound(optimalFeeE6, 0, MAX_OPTIMAL_FEE_E6));
        uint256 farFeeE12 = StableFeeCalculation.calculateFarBoundaryFee(priceRatioX96, optimalFeeE6);
        uint256 optimalFeeE12 = uint256(optimalFeeE6) * StableFeeCalculation.ONE_E6;

        // Full domain: farFee is exactly optimalFee at the reference and grows as the price
        // moves away, so optimalFee <= farFee <= 100%.
        assertGe(farFeeE12, optimalFeeE12);
        assertLe(farFeeE12, StableFeeCalculation.ONE_E12);

        int256 closeBoundaryFeeE12 = StableFeeCalculation.calculateCloseBoundaryFee(priceRatioX96, optimalFeeE6);
        if (closeBoundaryFeeE12 > 0) {
            // Outside the optimal range: farFee is at least its band-edge value 2f - f^2
            // (NOT 2f exactly — the f^2 cross-term is real), and always covers closeFee, so any
            // targetMultiplier in [0, MAX] yields a positive target no greater than farFee.
            assertGe(farFeeE12 + 2, 2 * optimalFeeE12 - uint256(optimalFeeE6) * optimalFeeE6); // 2 units fp slack
            assertGe(farFeeE12, uint256(closeBoundaryFeeE12));
            uint256 targetFeeE12 =
                farFeeE12 - uint256(closeBoundaryFeeE12) * (MAX_TARGET_MULTIPLIER / 2) / MAX_TARGET_MULTIPLIER;
            assertLe(targetFeeE12, farFeeE12);
            assertGt(targetFeeE12, 0);
        }
    }

    // =============================================================================
    // INVARIANT: fastPow returns correct k^n for n <= 4
    // =============================================================================

    function test_fastPow_succeeds() public pure {
        uint256 k = K;

        uint256 z;
        uint40 blocksPassed;

        blocksPassed = 0;
        z = StableFeeCalculation.fastPow(k, blocksPassed);
        assertEq(z, 1 << 24);

        blocksPassed = 1;
        z = StableFeeCalculation.fastPow(k, blocksPassed);
        assertEq(z, k);

        blocksPassed = 2;
        z = StableFeeCalculation.fastPow(k, blocksPassed);
        assertEq(z, k * k >> 24);

        blocksPassed = 3;
        z = StableFeeCalculation.fastPow(k, blocksPassed);
        assertEq(z, k * k * k >> 48);

        blocksPassed = 4;
        z = StableFeeCalculation.fastPow(k, blocksPassed);
        assertEq(z, k * k * k * k >> 72);
    }

    function test_fuzz_adjustPreviousFeeForPriceMovement_succeeds(uint256 priceRatioX96, uint256 previousDecayingFeeE12)
        public
        pure
    {
        priceRatioX96 = bound(priceRatioX96, 0, FixedPoint96.Q96); // price impact
        previousDecayingFeeE12 = bound(previousDecayingFeeE12, 0, StableFeeCalculation.ONE_E12);
        uint256 adjustedFeeE12 =
            StableFeeCalculation.adjustPreviousFeeForPriceMovement(priceRatioX96, previousDecayingFeeE12);
        assertGe(adjustedFeeE12, previousDecayingFeeE12);
        assertLe(adjustedFeeE12, StableFeeCalculation.ONE_E12);
    }

    function test_fuzz_calculateDecayingFee_succeeds(
        uint256 targetFeeE12,
        uint256 previousDecayingFeeE12,
        uint24 k,
        uint40 blocksPassed
    ) public pure {
        targetFeeE12 = bound(targetFeeE12, 0, StableFeeCalculation.ONE_E12 - 1);
        previousDecayingFeeE12 = bound(previousDecayingFeeE12, targetFeeE12, StableFeeCalculation.ONE_E12);
        k = uint24(bound(k, 1, 2 ** 24 - 1));
        uint256 decayingFeeE12 =
            StableFeeCalculation.calculateDecayingFee(targetFeeE12, previousDecayingFeeE12, k, blocksPassed);
        assertGe(decayingFeeE12, targetFeeE12);
        assertLe(decayingFeeE12, StableFeeCalculation.ONE_E12);
    }

    /// @notice decayingFee == targetFee when previousFee == targetFee
    /// (no gap to decay means fee stays exactly at target regardless of k or blocks)
    function test_fuzz_calculateDecayingFee_eqTarget_whenPreviousEqTarget(
        uint256 targetFeeE12,
        uint24 k,
        uint40 blocksPassed
    ) public pure {
        targetFeeE12 = bound(targetFeeE12, 0, StableFeeCalculation.ONE_E12 - 1);
        k = uint24(bound(k, 1, 2 ** 24 - 1));

        uint256 decayingFeeE12 = StableFeeCalculation.calculateDecayingFee(targetFeeE12, targetFeeE12, k, blocksPassed);
        assertEq(decayingFeeE12, targetFeeE12);
    }

    /// @notice Decay must be monotone across the blocksPassed 4 -> 5 switch from exact k^n
    /// multiplication (fast path) to the approximate exp(-logK * n) formula (slow path) for
    /// every valid k. Floor-quantized logK understated the slow-path exponent, letting
    /// factor(5) exceed the exact factor(4) for small-logK configs (finding #2); the ceil
    /// rounding in deriveLogK keeps the slow-path factor <= the true k^n. k is sampled near
    /// Q24 (1.0) because that is where logK is small and the quantization error is largest.
    function test_fuzz_calculateDecayingFee_monotoneAcrossFastSlowPathSwitch(uint24 k) public pure {
        k = uint24(bound(k, (1 << 24) - 200, (1 << 24) - 1));

        // target 0 / previous 100% makes the result directly proportional to the decay factor.
        uint256 fee4 = StableFeeCalculation.calculateDecayingFee(0, StableFeeCalculation.ONE_E12, k, 4);
        uint256 fee5 = StableFeeCalculation.calculateDecayingFee(0, StableFeeCalculation.ONE_E12, k, 5);
        assertLe(fee5, fee4);
    }

    /// @notice With extreme blocksPassed the decay factor reaches 0 and the fee converges to
    /// exactly targetFee.
    function test_calculateDecayingFee_convergesWithLargeBlocksPassed() public pure {
        uint256 decayingFeeE12 =
            StableFeeCalculation.calculateDecayingFee(TARGET_FEE_E12, PREVIOUS_FEE_E12, K, 1_000_000);
        assertEq(decayingFeeE12, TARGET_FEE_E12);

        // Even with uint40 max blocks
        decayingFeeE12 =
            StableFeeCalculation.calculateDecayingFee(TARGET_FEE_E12, PREVIOUS_FEE_E12, K, type(uint40).max);
        assertEq(decayingFeeE12, TARGET_FEE_E12);
    }

    // =============================================================================
    // INVARIANT: adjustedFee >= newTargetFee after price moves further from reference
    // When price moves further from reference while outside optimal range:
    //   - The old fee (which may have decayed to old target) gets adjusted upward
    //     to preserve the same pre-impact price at the new AMM price
    //   - The new target is higher because price is further from reference
    //   - The adjusted fee must still be >= the new target for decay math to work
    // =============================================================================

    function test_fuzz_adjustedFee_geq_newTarget(
        uint256 oldPriceRatioX96,
        uint256 newPriceRatioX96,
        uint24 optimalFeeE6
    ) public view {
        optimalFeeE6 = uint24(bound(optimalFeeE6, 1, MAX_OPTIMAL_FEE_E6));
        // The hook computes target = farFee - closeFee * targetMultiplier / MAX; use the midpoint
        // multiplier here — the multiplier extremes are exercised by the hook-level tests (the
        // decay-start clamp exists precisely because m = MAX can violate this property on
        // toward-reference moves).
        uint256 midMultiplier = MAX_TARGET_MULTIPLIER / 2;

        // Old price must be outside optimal range: priceRatio < (1 - optimalFee)
        uint256 outsideBoundary =
            (FixedPoint96.Q96 * (StableFeeCalculation.ONE_E6 - optimalFeeE6)) / StableFeeCalculation.ONE_E6;
        oldPriceRatioX96 = bound(oldPriceRatioX96, FixedPoint96.Q96 / 2, outsideBoundary);

        // New price moved further from reference (smaller priceRatio)
        newPriceRatioX96 = bound(newPriceRatioX96, FixedPoint96.Q96 / 2, oldPriceRatioX96);

        // Compute old fees at old price
        int256 oldCloseFeeE12 = StableFeeCalculation.calculateCloseBoundaryFee(oldPriceRatioX96, optimalFeeE6);
        uint256 oldFarFeeE12 = StableFeeCalculation.calculateFarBoundaryFee(oldPriceRatioX96, optimalFeeE6);
        uint256 oldTargetFeeE12 = oldFarFeeE12 - uint256(oldCloseFeeE12) * midMultiplier / MAX_TARGET_MULTIPLIER;

        // Previous fee has fully decayed to old target
        uint256 previousDecayingFeeE12 = oldTargetFeeE12;

        // Price impact ratio between old and new position
        // priceImpactRatio = newPriceRatio / oldPriceRatio (how much price moved)
        // Since both are relative to reference, the impact ratio is newRatio/oldRatio
        // But adjustPreviousFeeForPriceMovement takes calculatePriceRatioX96(newAmm, oldAmm)
        // which equals newPriceRatioX96 * Q96 / oldPriceRatioX96 (scaled)
        // We can compute it directly: smaller/larger
        uint256 priceImpactX96 = (newPriceRatioX96 * FixedPoint96.Q96) / oldPriceRatioX96;

        uint256 adjustedFeeE12 =
            StableFeeCalculation.adjustPreviousFeeForPriceMovement(priceImpactX96, previousDecayingFeeE12);

        // Compute new target at new price
        int256 newCloseFeeE12 = StableFeeCalculation.calculateCloseBoundaryFee(newPriceRatioX96, optimalFeeE6);
        uint256 newFarFeeE12 = StableFeeCalculation.calculateFarBoundaryFee(newPriceRatioX96, optimalFeeE6);
        uint256 newTargetFeeE12 = newFarFeeE12 - uint256(newCloseFeeE12) * midMultiplier / MAX_TARGET_MULTIPLIER;

        assertGe(adjustedFeeE12, newTargetFeeE12);
    }
}
