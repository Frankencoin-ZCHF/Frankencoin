// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {StablePairTestBase} from "./base/StablePairTestBase.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IStablePairHook} from "../../src/stable/interfaces/IStablePairHook.sol";
import {IDynamicFeeHook} from "../../src/interfaces/IDynamicFeeHook.sol";
import {StableFeeConfig, IStableFeeConfiguration} from "../../src/stable/interfaces/IStableFeeConfiguration.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {StableFeeCalculation} from "../../src/stable/libraries/StableFeeCalculation.sol";

/// forge-config: default.fuzz.runs = 2048
contract StablePairHookBeforeSwapTest is StablePairTestBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    event PoolInitialized(PoolKey indexed poolKey, uint160 sqrtPriceX96, StableFeeConfig feeConfig);

    function callBeforeSwap(bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        internal
        returns (uint24)
    {
        // getFee parity: quoted before the swap (beforeSwap writes feeState), compared after.
        // getFee must return exactly the fee this swap is charged, in the direction being swapped.
        uint24 quotedFee;
        {
            (uint24 quotedZeroForOne, uint24 quotedOneForZero) = hook.getFee(testPoolKey);
            quotedFee = zeroForOne ? quotedZeroForOne : quotedOneForZero;
        }
        uint256[4] memory configBefore = _feeConfigSnapshot();
        SwapParams memory swapParams = SwapParams(zeroForOne, amountSpecified, sqrtPriceLimitX96);
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) =
            hook.beforeSwap(address(this), testPoolKey, swapParams, Constants.ZERO_BYTES);

        _assertFeeConfigUnchanged(configBefore);

        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), BeforeSwapDelta.unwrap(BeforeSwapDeltaLibrary.ZERO_DELTA));

        assert(LPFeeLibrary.isOverride(fee));
        fee = LPFeeLibrary.removeOverrideFlag(fee);

        assertEq(fee, quotedFee);

        return fee;
    }

    /// @dev All feeConfig fields as one memory array — a single stack slot in the caller — so
    ///      callBeforeSwap can snapshot the config without going stack-too-deep.
    function _feeConfigSnapshot() internal view returns (uint256[4] memory s) {
        (uint256 k, uint24 optimalFeeE6, uint8 targetMultiplier, uint160 referenceSqrtPriceX96) =
            hook.feeConfig(testPoolKey.toId());
        s = [k, uint256(optimalFeeE6), uint256(targetMultiplier), uint256(referenceSqrtPriceX96)];
    }

    /// @dev Assert the fee config is untouched by a swap, field by field.
    function _assertFeeConfigUnchanged(uint256[4] memory before_) internal view {
        uint256[4] memory after_ = _feeConfigSnapshot();
        assertEq(before_[0], after_[0]);
        assertEq(before_[1], after_[1]);
        assertEq(before_[2], after_[2]);
        assertEq(before_[3], after_[3]);
    }

    function test_beforeSwap_insideOptimalRange_exactReferencePrice() public {
        // Set AMM price exactly at reference price
        sqrtAmmPriceX96 = REFERENCE_SQRT_PRICE_X96;
        uint24 fee;

        // Sell token0 at reference price - should charge optimal fee
        fee = callBeforeSwap(true, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 99) / 100);
        assertEq(fee, OPTIMAL_FEE_E6);

        // Buy token0 at reference price - should charge optimal fee
        fee = callBeforeSwap(false, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 101) / 100);
        assertEq(fee, OPTIMAL_FEE_E6);
    }

    function test_beforeSwap_insideOptimalRange_lowerBoundary() public {
        // Lower boundary (price space) = RP * (1 - optimalFee); park one fee-unit inside it.
        sqrtAmmPriceX96 = _sqrtPriceFromBps(1_000_000 - (OPTIMAL_FEE_E6 - 1));

        // Sell token0 (pushing price down, away from boundary) - should have minimal fee
        uint24 sellFee = callBeforeSwap(true, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 99) / 100);
        assertLt(sellFee, OPTIMAL_FEE_E6);

        // Buy token0 (pushing price up, toward reference) - should charge higher fee to reach buy price
        uint24 buyFee = callBeforeSwap(false, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 101) / 100);
        assertGt(buyFee, OPTIMAL_FEE_E6);
    }

    function test_beforeSwap_insideOptimalRange_upperBoundary() public {
        // Upper boundary (price space) = RP / (1 - optimalFee); flooring the bps lands just inside it.
        sqrtAmmPriceX96 = _sqrtPriceFromBps(1e12 / (1_000_000 - OPTIMAL_FEE_E6));

        // Buy token0 (pushing price up, away from boundary) - should have minimal fee
        uint24 buyFee = callBeforeSwap(false, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 101) / 100);
        assertLt(buyFee, OPTIMAL_FEE_E6);

        // Sell token0 (pushing price down, toward reference) - should charge higher fee to reach sell price
        uint24 sellFee = callBeforeSwap(true, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 99) / 100);
        assertGt(sellFee, OPTIMAL_FEE_E6);
    }

    /// @notice Anywhere strictly inside the optimal range, the fee places every swapper's pre-impact
    /// price exactly at the corresponding band boundary. This also pins sellFee <= optimalFee <= buyFee
    /// left of reference (and mirrored on the right).
    function test_fuzz_beforeSwap_insideOptimalRange_consistentEffectivePrices(uint24 priceBps) public {
        // Bound to strictly inside the optimal range; both edges derived from the configured fee:
        // (1 - optimalFee) .. 1/(1 - optimalFee) of the reference price.
        priceBps = uint24(bound(priceBps, 1_000_000 - OPTIMAL_FEE_E6 + 1, 1e12 / (1_000_000 - OPTIMAL_FEE_E6)));

        // Calculate AMM price
        uint256 ammPriceX192 = (uint256(REFERENCE_SQRT_PRICE_X96) * REFERENCE_SQRT_PRICE_X96 * priceBps) / 1_000_000;
        sqrtAmmPriceX96 = uint160(FixedPointMathLib.sqrt(ammPriceX192));

        uint24 sellFee = callBeforeSwap(true, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 99) / 100);
        uint24 buyFee = callBeforeSwap(false, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 101) / 100);

        // Calculate pre-impact prices
        // Sell: ammPrice * (1 - fee)
        // Buy: ammPrice / (1 - fee)
        uint256 effectiveSellPrice = (ammPriceX192 * (1_000_000 - sellFee)) / 1_000_000;
        uint256 effectiveBuyPrice = (ammPriceX192 * 1_000_000) / (1_000_000 - buyFee);

        // Target prices (from optimal range boundaries)
        // Sell boundary: RP * (1 - optimalFee)
        uint256 targetSellPrice =
            (uint256(REFERENCE_SQRT_PRICE_X96) * REFERENCE_SQRT_PRICE_X96 * (1_000_000 - OPTIMAL_FEE_E6)) / 1_000_000;
        // Buy boundary: RP / (1 - optimalFee)
        uint256 targetBuyPrice =
            (uint256(REFERENCE_SQRT_PRICE_X96) * REFERENCE_SQRT_PRICE_X96 * 1_000_000) / (1_000_000 - OPTIMAL_FEE_E6);

        // Pre-impact prices should be close to boundary prices within 0.0001% tolerance
        assertApproxEqRel(effectiveSellPrice, targetSellPrice, 0.000001e18);
        assertApproxEqRel(effectiveBuyPrice, targetBuyPrice, 0.000001e18);
    }

    /// @notice When the price moves further from reference (outside the optimal band), previousFee is
    /// adjusted upward via adjustPreviousFeeForPriceMovement() to preserve the same pre-impact price,
    /// then decays toward targetFee over time. Run symmetrically above and below the reference price.
    ///
    /// NOTE: Do not set previousSqrtAmmPriceX96 = sqrtAmmPriceX96 (equal prices). In reality,
    /// swaps always move the price. Equal prices bypass adjustPreviousFeeForPriceMovement(),
    /// causing the test to use a stale fee that doesn't reflect actual price movement.
    function test_beforeSwap_priceMovesFurtherFromReference_adjustsThenDecays_aboveReference() public {
        _runPriceMovesFurtherScenario(true);
    }

    function test_beforeSwap_priceMovesFurtherFromReference_adjustsThenDecays_belowReference() public {
        _runPriceMovesFurtherScenario(false);
    }

    /// @dev Starts 130 ppm outside the band, then moves a further 10 ppm. Each fee is asserted twice:
    /// against the library-derived expectation (a failure there means the hook's wiring diverged from
    /// the library) and against a pinned literal (sanity anchor; a failure there with the derived check
    /// passing means the library math itself moved — cross-check the CSV spreadsheet oracle).
    function _runPriceMovesFurtherScenario(bool aboveReference) internal {
        sqrtAmmPriceX96 = _sqrtPriceFromBps(aboveReference ? 1_000_130 : 999_870);
        vm.roll(vm.getBlockNumber() + 750);

        // The away-from-reference direction is free; this swap stores the decaying fee state.
        bool awayDirection = !aboveReference; // above ref: oneForZero moves away; below ref: zeroForOne
        assertEq(_swapDirection(awayDirection), 0);

        // Advance a block and move a further 10 ppm from reference.
        vm.roll(vm.getBlockNumber() + 1);
        (uint256 storedFeeE12, uint160 storedPriceX96,) = hook.feeState(testPoolKey.toId());
        sqrtAmmPriceX96 = _sqrtPriceFromBps(aboveReference ? 1_000_140 : 999_860);

        // With 1 block passed: fee is adjusted upward to preserve the pre-impact price, negligible decay.
        uint24 fee = _swapDirection(!awayDirection);
        assertEq(fee, _expectedAdjustedDecayedFee(storedFeeE12, storedPriceX96, 1));
        assertEq(fee, 210); // pinned sanity anchor

        // With 750 blocks passed: the adjusted fee decays toward targetFee.
        (storedFeeE12, storedPriceX96,) = hook.feeState(testPoolKey.toId());
        vm.roll(vm.getBlockNumber() + 750);
        fee = _swapDirection(!awayDirection);
        assertEq(fee, _expectedAdjustedDecayedFee(storedFeeE12, storedPriceX96, 750));
        assertEq(fee, 205); // pinned sanity anchor
    }

    /// @dev The toward-reference fee _calculateDecayingFee charges when the price has NOT moved toward
    /// reference since the stored state: adjust the stored fee up for the movement, clamp to target,
    /// decay over the elapsed blocks. Mirrors the hook's outside-range path using only library calls.
    function _expectedAdjustedDecayedFee(uint256 previousFeeE12, uint160 previousPriceX96, uint40 blocksPassed)
        internal
        view
        returns (uint24)
    {
        (uint256 k, uint24 optimalFeeE6, uint8 targetMultiplier,) = hook.feeConfig(testPoolKey.toId());
        uint256 targetFeeE12;
        {
            uint256 priceRatioX96 =
                StableFeeCalculation.calculatePriceRatioX96(sqrtAmmPriceX96, REFERENCE_SQRT_PRICE_X96);
            uint256 farFeeE12 = StableFeeCalculation.calculateFarBoundaryFee(priceRatioX96, optimalFeeE6);
            int256 closeFeeE12 = StableFeeCalculation.calculateCloseBoundaryFee(priceRatioX96, optimalFeeE6);
            targetFeeE12 = farFeeE12 - uint256(closeFeeE12) * targetMultiplier / hook.MAX_TARGET_MULTIPLIER();
        }
        uint256 decayStartE12 = StableFeeCalculation.adjustPreviousFeeForPriceMovement(
            StableFeeCalculation.calculatePriceRatioX96(sqrtAmmPriceX96, previousPriceX96), previousFeeE12
        );
        if (decayStartE12 < targetFeeE12) decayStartE12 = targetFeeE12;
        return StableFeeCalculation.toFeeE6(
            StableFeeCalculation.calculateDecayingFee(targetFeeE12, decayStartE12, k, blocksPassed)
        );
    }

    /// @dev callBeforeSwap with the standard size and a direction-appropriate price limit.
    function _swapDirection(bool zeroForOne) internal returns (uint24) {
        uint160 limit = zeroForOne ? (Constants.SQRT_PRICE_1_1 * 99) / 100 : (Constants.SQRT_PRICE_1_1 * 101) / 100;
        return callBeforeSwap(zeroForOne, 50_000 * 1e18, limit);
    }

    /// @notice Regression: at targetMultiplier=100 the decay target rises as price returns toward
    /// reference (m=1 > (1 - optimalFee)^2). A fee that decayed toward the earlier, lower target can
    /// then sit below the new, higher target. Without the decay-start clamp, `previous - target`
    /// underflows in calculateDecayingFee and bricks the price-restoring swap. The clamp must keep it
    /// working. Uses fast decay (k≈0.01) so the stored fee collapses to its target within a few blocks.
    function test_beforeSwap_targetMultiplier100_decayThenTowardReference_noUnderflow() public {
        uint24 fastK = 167772; // ~0.01 in Q24: ~99% decay per block
        StableFeeConfig memory cfg = StableFeeConfig({
            k: fastK,
            optimalFeeE6: OPTIMAL_FEE_E6,
            targetMultiplier: 100,
            referenceSqrtPriceX96: REFERENCE_SQRT_PRICE_X96
        });
        vm.prank(configManager);
        hook.updateFeeConfig(testPoolKey.toId(), cfg);

        // Block 1: price well below reference (outside the optimal band). Stores the decaying fee.
        sqrtAmmPriceX96 = _sqrtPriceFromBps(990_000); // 0.99 * reference
        vm.roll(vm.getBlockNumber() + 1);
        callBeforeSwap(false, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 101) / 100);

        // Block 2 (much later, same price): the stored fee decays down to ~target(0.99).
        vm.roll(vm.getBlockNumber() + 50);
        callBeforeSwap(false, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 101) / 100);

        // Block 3: price moves toward reference (still outside). target(0.999) now exceeds the decayed
        // stored fee — the exact condition that underflowed pre-clamp.
        sqrtAmmPriceX96 = _sqrtPriceFromBps(999_000); // 0.999 * reference
        vm.roll(vm.getBlockNumber() + 1);
        uint24 fee = callBeforeSwap(false, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 101) / 100);

        // A toward-reference buy is charged the (clamped) decaying fee, not zero.
        assertGt(fee, 0);
    }

    /// @notice With targetMultiplier=100 under extreme depeg, targetFee is
    /// nonzero but below 1 pip (here ~0.9 ppm), and the decaying fee converges to it. The
    /// toward-reference swap must charge 1 pip — rounded up — not an explicit 0-fee override.
    /// The away-from-reference direction still charges exactly zero.
    function test_beforeSwap_targetMultiplier100_subPipDecayedFee_chargesOnePipNotZero() public {
        uint24 fastK = 167772; // ~0.01 in Q24: ~99% decay per block
        StableFeeConfig memory cfg = StableFeeConfig({
            k: fastK,
            optimalFeeE6: OPTIMAL_FEE_E6,
            targetMultiplier: 100,
            referenceSqrtPriceX96: REFERENCE_SQRT_PRICE_X96
        });
        vm.prank(configManager);
        hook.updateFeeConfig(testPoolKey.toId(), cfg);

        // Extreme depeg: 0.005x reference. At m=100 the target is farFee - closeFee ≈ 2 * r * optimalFee
        // ≈ 2 * 0.005 * 90 ppm ≈ 0.9 ppm — nonzero but below 1 pip.
        sqrtAmmPriceX96 = _sqrtPriceFromBps(5_000);
        vm.roll(vm.getBlockNumber() + 1);
        // Below reference, zeroForOne moves away: charged exactly zero (a true zero is not rounded up).
        assertEq(_swapDirection(true), 0);

        // Decay the stored fee down to the sub-pip target.
        vm.roll(vm.getBlockNumber() + 50);
        uint24 fee = _swapDirection(false);
        assertEq(fee, 1); // pre-fix this truncated to an explicit 0-fee override
    }

    /// @notice Helper: AMM sqrtPriceX96 for `bps`/1e6 of the reference price (e.g. 990_000 = 0.99x).
    function _sqrtPriceFromBps(uint256 bps) internal pure returns (uint160) {
        uint256 ammPriceX192 = (uint256(REFERENCE_SQRT_PRICE_X96) * REFERENCE_SQRT_PRICE_X96 * bps) / 1_000_000;
        return uint160(FixedPointMathLib.sqrt(ammPriceX192));
    }

    function test_beforeSwap_newBlock_insideOptimalRange_gas() public {
        sqrtAmmPriceX96 = REFERENCE_SQRT_PRICE_X96;

        // construct swap params, and call beforeSwap
        SwapParams memory swapParams = SwapParams(true, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 99) / 100);
        hook.beforeSwap(address(this), testPoolKey, swapParams, Constants.ZERO_BYTES);
        vm.snapshotGasLastCall("beforeSwap_newBlock_insideOptimalRange");
    }

    /// @notice Decay via fastPow: blocksPassed = 4 is the largest gap computed as exact k^n
    /// multiplication. Gas is flat for all gaps 1-4 up to a few gas of fastPow multiplications.
    function test_beforeSwap_newBlock_outsideOptimalRange_fastPowDecay_gas() public {
        sqrtAmmPriceX96 = _sqrtPriceFromBps(1_000_130);
        vm.roll(vm.getBlockNumber() + 4);

        SwapParams memory swapParams = SwapParams(true, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 99) / 100);
        hook.beforeSwap(address(this), testPoolKey, swapParams, Constants.ZERO_BYTES);
        vm.snapshotGasLastCall("beforeSwap_newBlock_outsideOptimalRange_fastPowDecay");
    }

    /// @notice Decay via expWad: blocksPassed = 5 is the smallest gap computed as exp(-logK * n),
    /// with logK derived from k on the fly (lnWad). Gas is flat for ALL gaps > 4 (expWad is
    /// constant-cost in the gap), so the delta vs the fastPow snapshot is the full cost of
    /// crossing the 4 -> 5 switch: deriveLogK + expWad, minus fastPow.
    function test_beforeSwap_newBlock_outsideOptimalRange_expWadDecay_gas() public {
        sqrtAmmPriceX96 = _sqrtPriceFromBps(1_000_130);
        vm.roll(vm.getBlockNumber() + 5);

        SwapParams memory swapParams = SwapParams(true, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 99) / 100);
        hook.beforeSwap(address(this), testPoolKey, swapParams, Constants.ZERO_BYTES);
        vm.snapshotGasLastCall("beforeSwap_newBlock_outsideOptimalRange_expWadDecay");
    }

    function test_beforeSwap_sameBlock_outsideOptimalRange_gas() public {
        sqrtAmmPriceX96 = _sqrtPriceFromBps(1_000_130);
        vm.roll(vm.getBlockNumber() + 750);

        // First swap (new block, full calculation)
        SwapParams memory swapParams = SwapParams(true, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 99) / 100);
        hook.beforeSwap(address(this), testPoolKey, swapParams, Constants.ZERO_BYTES);

        // Second swap (same block, should short-circuit _calculateDecayingFee)
        hook.beforeSwap(address(this), testPoolKey, swapParams, Constants.ZERO_BYTES);
        vm.snapshotGasLastCall("beforeSwap_sameBlock_outsideOptimalRange");
    }

    // FEE CACHING: same-block swaps use the start-of-block price for fee calculation

    /// @notice Same-block swaps use the cached start-of-block price, not the live AMM price.
    /// Changing the AMM price between swaps in the same block should not change the fee.
    function test_beforeSwap_sameBlock_feeIsCached() public {
        // Set price slightly below reference (inside optimal range)
        sqrtAmmPriceX96 = _sqrtPriceFromBps(999_950);

        vm.roll(vm.getBlockNumber() + 1);

        // First swap of block: fee is computed from current AMM price
        uint24 fee1 = callBeforeSwap(true, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 99) / 100);

        // Simulate price impact: AMM price moves to reference
        sqrtAmmPriceX96 = REFERENCE_SQRT_PRICE_X96;

        // Second swap of same block: fee should be identical (uses cached price)
        uint24 fee2 = callBeforeSwap(true, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 99) / 100);

        assertEq(fee1, fee2); // same-block swaps should have identical fees
    }

    /// @notice A new block reads the fresh AMM price, not the previous block's cached price.
    function test_beforeSwap_newBlock_usesFreshPrice() public {
        sqrtAmmPriceX96 = _sqrtPriceFromBps(999_950);

        vm.roll(vm.getBlockNumber() + 1);
        uint24 fee1 = callBeforeSwap(true, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 99) / 100);

        // Move price to reference and advance to new block
        sqrtAmmPriceX96 = REFERENCE_SQRT_PRICE_X96;
        vm.roll(vm.getBlockNumber() + 1);

        uint24 fee2 = callBeforeSwap(true, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 99) / 100);

        // Fees should differ because each block uses its own fresh price
        assertTrue(fee1 != fee2); // new block should use fresh price
    }

    /// @notice feeState should only be written on the first swap of a new block.
    function test_beforeSwap_sameBlock_feeStateNotUpdated() public {
        sqrtAmmPriceX96 = REFERENCE_SQRT_PRICE_X96;
        vm.roll(vm.getBlockNumber() + 1);

        // First swap sets feeState
        callBeforeSwap(true, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 99) / 100);

        // Record feeState after first swap
        PoolId poolId = testPoolKey.toId();
        (uint40 decayingFee1, uint160 storedPrice1, uint40 blockNum1) = hook.feeState(poolId);

        // Change AMM price and do second swap in same block
        sqrtAmmPriceX96 = _sqrtPriceFromBps(999_950);

        callBeforeSwap(true, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 99) / 100);

        // feeState should be unchanged
        (uint40 decayingFee2, uint160 storedPrice2, uint40 blockNum2) = hook.feeState(poolId);
        assertEq(decayingFee1, decayingFee2);
        assertEq(storedPrice1, storedPrice2);
        assertEq(blockNum1, blockNum2);
    }

    function test_beforeSwap_sameBlock_insideOptimalRange_gas() public {
        sqrtAmmPriceX96 = REFERENCE_SQRT_PRICE_X96;
        vm.roll(vm.getBlockNumber() + 1);

        // First swap (new block, writes feeState)
        SwapParams memory swapParams = SwapParams(true, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 99) / 100);
        hook.beforeSwap(address(this), testPoolKey, swapParams, Constants.ZERO_BYTES);

        // Second swap (same block, skips feeState writes)
        hook.beforeSwap(address(this), testPoolKey, swapParams, Constants.ZERO_BYTES);
        vm.snapshotGasLastCall("beforeSwap_sameBlock_insideOptimalRange");
    }

    /// @notice After a fee config reset, the first swap reads the fresh AMM price, not a stale cached price.
    /// Regression: if _resetFeeState didn't zero sqrtAmmPriceX96, same-block swaps after reset
    /// would use the pre-reset cached price with potentially different fee config parameters.
    function test_beforeSwap_feeConfigReset_usesFreshPrice() public {
        // First swap caches the reference price in feeState
        sqrtAmmPriceX96 = REFERENCE_SQRT_PRICE_X96;
        uint24 fee1 = callBeforeSwap(true, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 99) / 100);

        assertEq(fee1, OPTIMAL_FEE_E6);

        // Reset fee config in the same block
        vm.prank(configManager);
        hook.updateFeeConfig(testPoolKey.toId(), _defaultConfig());

        // Move AMM price away from reference
        sqrtAmmPriceX96 = _sqrtPriceFromBps(999_950);

        // Swap after reset: should use the new price, not the stale cached reference price
        uint24 fee2 = callBeforeSwap(true, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 99) / 100);

        // At the new price (below reference), selling token0 pushes further from reference → fee < optimalFee.
        // If using stale cached reference price, fee would be exactly optimalFee.
        assertLt(fee2, OPTIMAL_FEE_E6);
    }

    // =============================================================================
    // INVARIANT: beforeSwap never reverts for any valid price, direction, and block gap
    // Exercises all state transitions in _calculateDecayingFee:
    //   - Inside/outside optimal range
    //   - Price moving toward/away from reference
    //   - Price crossing reference
    //   - Fee state reset, adjustment, cap, and pass-through
    //   - Decay over varying block gaps
    //   - Reference price at any valid position in the v4 range
    // =============================================================================

    // Never-reverts invariant lives in StablePairHook.invariants.t.sol (full-config + reference-relative).

    /// @notice A non-monotonic block-number source must not brick a pool. If _getBlockNumberish() ever
    /// reads lower than the block stored in feeState (a chain that resets or re-bases block height, a
    /// buggy precompile, or a future chain-specific BlockNumberish branch), the elapsed-blocks subtraction
    /// feeding the decay must not underflow-revert. Covers both regression paths: a normal stored state
    /// (guarded by the strict `>` new-block check) and the post-reset sentinel state (guarded by the
    /// elapsed-blocks clamp). beforeSwap and the getFee view (same decay path) must stay live either way.
    function test_beforeSwap_blockNumberRegression_doesNotRevert() public {
        SwapParams memory swapParams = SwapParams(true, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 99) / 100);
        sqrtAmmPriceX96 = _sqrtPriceFromBps(1_000_130); // above the optimal band

        // Path 1 — normal stored state: a swap caches an outside-range price at a high block.
        vm.roll(1000);
        hook.beforeSwap(address(this), testPoolKey, swapParams, Constants.ZERO_BYTES); // stores blockNumber = 1000
        vm.roll(999); // block-number source regresses below the stored block
        hook.beforeSwap(address(this), testPoolKey, swapParams, Constants.ZERO_BYTES);
        hook.getFee(testPoolKey); // shares the same decay path

        // Path 2 — post-reset sentinel: updateFeeConfig resets feeState (sqrtAmmPriceX96 = 0) at a high
        // block, so isNewBlock is forced true even after a regression and the subtraction still runs.
        vm.roll(2000);
        vm.prank(configManager);
        hook.updateFeeConfig(testPoolKey.toId(), _defaultConfig()); // blockNumber = 2000, sqrtAmmPriceX96 = 0
        vm.roll(1999);
        hook.beforeSwap(address(this), testPoolKey, swapParams, Constants.ZERO_BYTES);
        hook.getFee(testPoolKey);
    }

    /// @notice With targetMultiplier=0, the target fee equals farBoundaryFee.
    /// After full decay the fee should equal farBoundaryFee computed from the library.
    function test_beforeSwap_zeroTargetMultiplier_feeEqualsFarBoundaryFee() public {
        StableFeeConfig memory newConfig = StableFeeConfig({
            k: K, optimalFeeE6: OPTIMAL_FEE_E6, targetMultiplier: 0, referenceSqrtPriceX96: REFERENCE_SQRT_PRICE_X96
        });
        vm.prank(configManager);
        hook.updateFeeConfig(testPoolKey.toId(), newConfig);

        // Move AMM price outside optimal range
        sqrtAmmPriceX96 = _sqrtPriceFromBps(1_000_130);

        // Establish fee state
        vm.roll(vm.getBlockNumber() + 1);
        callBeforeSwap(true, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 99) / 100);

        // Slightly move price further from reference to avoid equal-price edge case
        sqrtAmmPriceX96 = _sqrtPriceFromBps(1_000_131);

        vm.roll(vm.getBlockNumber() + 750);

        uint24 fee1 = callBeforeSwap(true, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 99) / 100);

        // Compute expected farBoundaryFee at current price
        uint256 priceRatioX96 = StableFeeCalculation.calculatePriceRatioX96(sqrtAmmPriceX96, REFERENCE_SQRT_PRICE_X96);
        uint256 farBoundaryFeeE12 = StableFeeCalculation.calculateFarBoundaryFee(priceRatioX96, OPTIMAL_FEE_E6);
        uint24 expectedFee = StableFeeCalculation.toFeeE6(farBoundaryFeeE12);

        // With targetMultiplier=0: targetFee = farBoundaryFee, so after full decay fee equals farBoundaryFee
        assertEq(fee1, expectedFee);

        // Large price shock: jump to 2000ppm above reference with only 1 block elapsed
        vm.roll(vm.getBlockNumber() + 1);
        sqrtAmmPriceX96 = _sqrtPriceFromBps(1_002_000);

        uint24 fee2 = callBeforeSwap(true, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 99) / 100);

        // Fee should immediately equal farBoundaryFee at the new price — no transient spike
        priceRatioX96 = StableFeeCalculation.calculatePriceRatioX96(sqrtAmmPriceX96, REFERENCE_SQRT_PRICE_X96);
        farBoundaryFeeE12 = StableFeeCalculation.calculateFarBoundaryFee(priceRatioX96, OPTIMAL_FEE_E6);
        assertEq(fee2, StableFeeCalculation.toFeeE6(farBoundaryFeeE12));

        // Fee should be higher at the new price (further from reference)
        assertGt(fee2, fee1);
    }

    /// @notice When targetMultiplier=100 (full subtraction) and k is very small, the spread closes quickly
    /// Setup: optimalFee=0.1bps, move AMM price 10bps from reference, wait 2 blocks.
    /// Then make two tiny swaps in opposite directions and verify the spread is tight (~2*optimalFee).
    function test_beforeSwap_spreadClosesQuickly_withFullTargetMultiplier() public {
        // Use a very small k (0.01 in Q24 ≈ 1% retention per block → 99% decay per block)
        uint24 testK = 167_772; // floor(0.01 * 2^24)
        uint24 testOptimalFeeE6 = 10; // 0.1 bps

        StableFeeConfig memory newConfig = StableFeeConfig({
            k: testK,
            optimalFeeE6: testOptimalFeeE6,
            targetMultiplier: 100,
            referenceSqrtPriceX96: REFERENCE_SQRT_PRICE_X96
        });
        vm.prank(configManager);
        hook.updateFeeConfig(testPoolKey.toId(), newConfig);

        // Move AMM price 10bps above reference: price = 1.0001
        sqrtAmmPriceX96 = _sqrtPriceFromBps(1_000_100);

        // First swap at this price: establishes fee state (first time outside optimal range)
        vm.roll(vm.getBlockNumber() + 1);
        callBeforeSwap(true, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 99) / 100);

        // Slightly adjust price so it's not exactly equal to previous (avoid equal-price edge case)
        sqrtAmmPriceX96 = _sqrtPriceFromBps(1_000_099);

        // Advance 2 blocks: with k=0.01, decay factor = 0.01^2 = 0.0001 → fee ≈ target
        vm.roll(vm.getBlockNumber() + 2);

        // Two tiny swaps in opposite directions to measure the spread
        // Sell token0 (toward reference when price > ref): charged the decaying fee
        uint24 sellFee = callBeforeSwap(true, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 99) / 100);
        // Buy token0 (away from reference when price > ref): 0 fee
        uint24 buyFee = callBeforeSwap(false, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 101) / 100);

        // Buy fee should be 0 (pushing further from reference)
        assertEq(buyFee, 0);

        // With targetMultiplier=100: targetFee = farBoundaryFee - closeBoundaryFee ≈ 2 * optimalFee
        // After 2 blocks with k=0.01: fee ≈ target ≈ 2 * optimalFee = 0.2bps = 20 in E6
        assertLe(sellFee, 21);
        assertGe(sellFee, 19);
    }

    // =============================================================================
    // getFee: the view must return exactly the fee a real swap would be charged by
    // beforeSwap. Scenario-level parity is asserted on EVERY callBeforeSwap above;
    // the tests below cover what that per-swap check can't: the interface cast, the
    // uninitialized-pool revert, and both-directions-from-identical-state parity
    // fuzzed across the config/price/block-gap space.
    // =============================================================================

    /// @notice The fee beforeSwap charges for a given direction (override flag stripped).
    function _swapFee(bool zeroForOne) internal returns (uint24) {
        SwapParams memory p = SwapParams(zeroForOne, 50_000 * 1e18, 0);
        (,, uint24 fee) = hook.beforeSwap(address(this), testPoolKey, p, Constants.ZERO_BYTES);
        return LPFeeLibrary.removeOverrideFlag(fee);
    }

    /// @notice Assert getFee(key) equals what the first swap of this block would be charged,
    /// per direction. Each direction is measured from the same start-of-block state.
    function _assertGetFeeMatchesSwap() internal {
        (uint24 feeZeroForOne, uint24 feeOneForZero) = hook.getFee(testPoolKey);

        uint256 snap = vm.snapshotState();
        uint24 swapFeeZeroForOne = _swapFee(true);
        vm.revertToState(snap);

        snap = vm.snapshotState();
        uint24 swapFeeOneForZero = _swapFee(false);
        vm.revertToState(snap);

        assertEq(feeZeroForOne, swapFeeZeroForOne);
        assertEq(feeOneForZero, swapFeeOneForZero);
    }

    function test_getFee_interfaceConformance() public view {
        (uint24 feeZeroForOne, uint24 feeOneForZero) = IDynamicFeeHook(address(hook)).getFee(testPoolKey);
        assertEq(feeZeroForOne, OPTIMAL_FEE_E6);
        assertEq(feeOneForZero, OPTIMAL_FEE_E6);
    }

    function test_getFee_revertsForUninitializedPool() public {
        PoolKey memory uninit = PoolKey({
            currency0: Currency.wrap(address(2)),
            currency1: Currency.wrap(address(3)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        vm.expectRevert(abi.encodeWithSelector(IDynamicFeeHook.PoolNotInitialized.selector, uninit.toId()));
        hook.getFee(uninit);
    }

    /// @notice The anti-drift guarantee across the full price range: for any state — fresh config,
    /// stored decaying-fee state from a prior swap, or mid-block with a cached price — getFee equals
    /// the fee an actual swap receives, in both directions, from the same start-of-block state.
    function test_fuzz_getFee_matchesBeforeSwap(
        ConfigSeed memory cfgSeed,
        uint160 priceSeed,
        uint160 primePriceSeed,
        uint256 blockGap,
        bool primeFeeState
    ) public {
        StableFeeConfig memory cfg = _boundFeeConfig(cfgSeed);
        vm.prank(configManager);
        hook.updateFeeConfig(testPoolKey.toId(), cfg);

        if (primeFeeState) {
            // Store a decaying-fee state so the adjustment/decay path is exercised, not just fresh state.
            sqrtAmmPriceX96 = _boundSqrtPriceRelative(primePriceSeed, cfg.referenceSqrtPriceX96);
            vm.roll(vm.getBlockNumber() + 1);
            _swapFee(true);
        }

        // With a primed swap this block, gap 0 exercises the same-block cached-price path.
        blockGap = bound(blockGap, primeFeeState ? 0 : 1, 10_000);
        sqrtAmmPriceX96 = _boundSqrtPriceRelative(priceSeed, cfg.referenceSqrtPriceX96);
        vm.roll(vm.getBlockNumber() + blockGap);

        _assertGetFeeMatchesSwap();
    }
}
