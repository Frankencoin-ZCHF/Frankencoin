// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StablePairTestBase} from "./base/StablePairTestBase.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StableFeeConfig} from "../../src/stable/interfaces/IStableFeeConfiguration.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {StableFeeCalculation} from "../../src/stable/libraries/StableFeeCalculation.sol";

/// @notice Fuzz invariants for StablePairHook driven through the mocked-price harness
/// forge-config: default.fuzz.runs = 2048
contract StablePairHookInvariantsTest is StablePairTestBase {
    using PoolIdLibrary for PoolKey;

    /// @notice The pool must be initialized once before tests run. Derive that one-time seed config from
    /// the generator itself (a zero seed) rather than hardcoding values — no magic literals, and every
    /// test immediately overwrites it via _setConfig with its own fuzzed config.
    function _initialConfig() internal view override returns (StableFeeConfig memory) {
        return _boundFeeConfig(ConfigSeed({kSeed: 0, optimalFeeSeed: 0, targetMultSeed: 0, refPriceSeed: 0}));
    }

    function _callBeforeSwap(bool zeroForOne) internal returns (uint24 fee) {
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        (,, fee) = hook.beforeSwap(address(this), testPoolKey, SwapParams(zeroForOne, 1000 * 1e18, limit), "");
        assertTrue(LPFeeLibrary.isOverride(fee));
        fee = LPFeeLibrary.removeOverrideFlag(fee);
    }

    /// @notice The core property the clamp bug violated: for ANY valid config and ANY reachable price
    /// path across blocks — including mid-path config resets — beforeSwap must never revert and must
    /// return a fee <= 100%. getFee is checked in lockstep: it must never revert either, and must
    /// quote exactly what the swap is then charged.
    /// forge-config: default.fuzz.runs = 5000
    function test_fuzz_beforeSwap_neverReverts(ConfigSeed memory cfgSeed, SwapStep[8] memory steps, uint8 resetMask)
        public
    {
        StableFeeConfig memory cfg = _boundFeeConfig(cfgSeed);
        _setConfig(cfg);

        for (uint256 i = 0; i < steps.length; i++) {
            // Occasionally swap in a fresh config mid-path: updateFeeConfig resets the fee state while
            // the pool price stays wherever the path left it — a combo no single-config run reaches.
            if ((resetMask >> i) & 1 == 1) {
                cfg = _boundFeeConfig(
                    ConfigSeed({
                        kSeed: uint24(steps[i].priceSeed),
                        optimalFeeSeed: uint24(steps[i].priceSeed >> 24),
                        targetMultSeed: uint8(steps[i].priceSeed >> 48),
                        refPriceSeed: steps[i].priceSeed
                    })
                );
                _setConfig(cfg);
            }

            // Most prices reference-relative (near the band, where decay dynamics live); every 4th is a
            // full-range absolute price so extremes are still covered.
            sqrtAmmPriceX96 = (i % 4 == 3)
                ? _boundSqrtPriceAbsolute(steps[i].priceSeed)
                : _boundSqrtPriceRelative(steps[i].priceSeed, cfg.referenceSqrtPriceX96);

            vm.roll(vm.getBlockNumber() + bound(uint256(steps[i].blockGap), 0, 10_000));

            (uint24 quoteZeroForOne, uint24 quoteOneForZero) = hook.getFee(testPoolKey);
            uint24 fee = _callBeforeSwap(steps[i].zeroForOne);
            assertEq(fee, steps[i].zeroForOne ? quoteZeroForOne : quoteOneForZero);
            // Strictly below 100%: at 1e6 exact-output swaps revert and exact-input swaps are
            // consumed entirely as fee, so no swap can move the price through active liquidity —
            // deadlocking a saturated pool whose recovery path holds any liquidity. The fee v4
            // charges is the hook's LP fee compounded with the directional protocol fee, rounded
            // UP to a whole pip — so the hook's fee must stay below 1e6 even against the max
            // protocol fee.
            assertLt(
                ProtocolFeeLibrary.calculateSwapFee(ProtocolFeeLibrary.MAX_PROTOCOL_FEE, fee),
                StableFeeCalculation.ONE_E6
            );
        }
    }

    /// @notice Every config produced by _boundFeeConfig must pass validation (updateFeeConfig succeeds)
    /// and be stored verbatim.
    function test_fuzz_boundFeeConfig_alwaysValidates(ConfigSeed memory s) public {
        StableFeeConfig memory cfg = _boundFeeConfig(s);
        _setConfig(cfg); // reverts if the bounder ever produces an invalid config
        (uint256 k, uint24 optimalFeeE6, uint8 targetMultiplier, uint160 ref) = hook.feeConfig(testPoolKey.toId());
        assertEq(k, cfg.k);
        assertEq(optimalFeeE6, cfg.optimalFeeE6);
        assertEq(targetMultiplier, cfg.targetMultiplier);
        assertEq(ref, cfg.referenceSqrtPriceX96);
    }

    /// @notice More elapsed blocks never move the stored decaying fee AWAY from its target — decay
    /// is monotone for ANY pair of gaps, including across the blocksPassed 4 -> 5 switch from exact
    /// k^n multiplication (fast path) to the approximate exp(-logK * n) formula (slow path); the
    /// deterministic regression test below pins the small-logK config the floor derivation used to
    /// break on.
    function test_fuzz_decayMonotonic(ConfigSeed memory cfgSeed, uint160 priceSeed, uint8 gapSeed, uint16 extraGap)
        public
    {
        StableFeeConfig memory cfg = _boundFeeConfig(cfgSeed);
        // targetMultiplier > 0 keeps target < farBoundary so there is a real gap to decay across.
        if (cfg.targetMultiplier == 0) cfg.targetMultiplier = 1;
        _setConfig(cfg);

        uint160 price = _boundSqrtPriceRelative(priceSeed, cfg.referenceSqrtPriceX96);

        // Establish outside-range decaying-fee state at this price (first outside-range swap of a block).
        sqrtAmmPriceX96 = price;
        vm.roll(vm.getBlockNumber() + 1);
        _callBeforeSwap(false);
        (uint256 startFee,,) = hook.feeState(testPoolKey.toId());
        // If we are inside the optimal range here, there is no decaying fee to reason about — skip.
        vm.assume(startFee != StableFeeCalculation.UNDEFINED_DECAYING_FEE_E12);

        // Short gap concentrated around the fast/slow path switch at 4 blocks; long gap anywhere beyond it.
        uint256 shortGap = bound(uint256(gapSeed), 1, 10);
        uint256 longGap = shortGap + bound(uint256(extraGap), 1, 5_000);

        uint256 snap = vm.snapshotState();
        vm.roll(vm.getBlockNumber() + shortGap);
        _callBeforeSwap(false);
        (uint256 feeShort,,) = hook.feeState(testPoolKey.toId());
        vm.revertToState(snap);

        vm.roll(vm.getBlockNumber() + longGap);
        _callBeforeSwap(false);
        (uint256 feeLong,,) = hook.feeState(testPoolKey.toId());

        // More blocks => fee is <= the shorter-gap fee (decays downward toward target; both start from
        // the same stored state, same price, so target is identical).
        assertLe(feeLong, feeShort);
    }

    /// @notice Finding #2 regression (logK quantization): decay must stay monotone across the
    /// blocksPassed 4 -> 5 switch from exact k^n multiplication (fast path) to the approximate
    /// exp(-logK * n) formula (slow path). k = 16_777_188 pins the historical worst case: under
    /// the old uint24 `>> 40` scheme its true exponent (≈ 1.52 units) floor-quantized to 1,
    /// making the 5-block slow-path factor exceed the exact 4-block factor and overcharge the
    /// restoring swap. The uint40 `>> 24` derivation keeps the same k in-range with negligible
    /// error; this test keeps guarding the path switch.
    function test_decayMonotonic_acrossFastSlowPathSwitch() public {
        StableFeeConfig memory cfg = _defaultConfig();
        cfg.k = 16_777_188;
        _setConfig(cfg);

        // Establish outside-range decaying-fee state (~1% below reference in price space).
        sqrtAmmPriceX96 = uint160(uint256(REFERENCE_SQRT_PRICE_X96) * 995 / 1000);
        vm.roll(vm.getBlockNumber() + 1);
        _callBeforeSwap(false);
        (uint256 startFee,,) = hook.feeState(testPoolKey.toId());
        assertTrue(startFee != StableFeeCalculation.UNDEFINED_DECAYING_FEE_E12);

        // Same stored state, same price => same target; only blocksPassed differs (4 fast, 5 slow).
        uint256 snap = vm.snapshotState();
        vm.roll(vm.getBlockNumber() + 4);
        _callBeforeSwap(false);
        (uint256 fee4,,) = hook.feeState(testPoolKey.toId());
        vm.revertToState(snap);

        vm.roll(vm.getBlockNumber() + 5);
        _callBeforeSwap(false);
        (uint256 fee5,,) = hook.feeState(testPoolKey.toId());

        assertLe(fee5, fee4);
    }

    /// @notice Outside the optimal range, the away-from-reference direction is charged 0 and the
    /// toward-reference direction is charged >= that (i.e. >= 0). Holds for any valid config.
    function test_fuzz_outsideRange_directionalAsymmetry(ConfigSeed memory cfgSeed, uint160 priceSeed) public {
        StableFeeConfig memory cfg = _boundFeeConfig(cfgSeed);
        _setConfig(cfg);

        sqrtAmmPriceX96 = _boundSqrtPriceRelative(priceSeed, cfg.referenceSqrtPriceX96);
        vm.roll(vm.getBlockNumber() + 1);

        uint256 snap = vm.snapshotState();
        uint24 feeZeroForOne = _callBeforeSwap(true);
        // _boundSqrtPriceRelative only targets 0.90x-1.10x of reference; the optimal band itself can be
        // as wide as ~[0.99x, 1.0101x] (MAX_OPTIMAL_FEE_E6 = 1%), so the sampled price can still land
        // inside the band for some configs. Only the outside-range branch sets a decaying fee; skip
        // (rather than weaken the assertion) when this draw landed inside the band.
        (uint256 decayingFeeE12,,) = hook.feeState(testPoolKey.toId());
        vm.assume(decayingFeeE12 != StableFeeCalculation.UNDEFINED_DECAYING_FEE_E12);
        vm.revertToState(snap);
        uint24 feeOneForZero = _callBeforeSwap(false);

        // One side is the "away" side (0 fee); the other is the "toward" side (>= 0). Their min is 0.
        assertEq(feeZeroForOne < feeOneForZero ? feeZeroForOne : feeOneForZero, 0);
    }

    /// @notice Exactly at the reference price both directions charge exactly the configured optimal
    /// fee, for any valid config (the inside-range formula collapses to optimalFee at ratio 1).
    function test_fuzz_insideRange_bothDirectionsChargeOptimalFee(ConfigSeed memory cfgSeed) public {
        StableFeeConfig memory cfg = _boundFeeConfig(cfgSeed);
        _setConfig(cfg);

        // Price exactly at reference is always inside the band.
        sqrtAmmPriceX96 = cfg.referenceSqrtPriceX96;
        vm.roll(vm.getBlockNumber() + 1);

        uint256 snap = vm.snapshotState();
        uint24 feeZeroForOne = _callBeforeSwap(true);
        vm.revertToState(snap);
        uint24 feeOneForZero = _callBeforeSwap(false);

        assertEq(feeZeroForOne, cfg.optimalFeeE6);
        assertEq(feeOneForZero, cfg.optimalFeeE6);
    }

    /// @notice Same-block fee caching holds for ANY valid config: the first swap of a block snapshots
    /// the AMM price, so moving the live price before a second same-block swap must change neither the
    /// charged fee nor the stored fee state. (Config-fuzzed generalization of the deterministic
    /// caching tests in StablePairHook.beforeSwap.t.sol.)
    function test_fuzz_sameBlock_feeAndStateCached(
        ConfigSeed memory cfgSeed,
        uint160 priceSeedA,
        uint160 priceSeedB,
        bool zeroForOne
    ) public {
        StableFeeConfig memory cfg = _boundFeeConfig(cfgSeed);
        _setConfig(cfg);

        sqrtAmmPriceX96 = _boundSqrtPriceRelative(priceSeedA, cfg.referenceSqrtPriceX96);
        vm.roll(vm.getBlockNumber() + 1);
        uint24 fee1 = _callBeforeSwap(zeroForOne);
        (uint256 storedFee1, uint160 storedPrice1, uint256 storedBlock1) = hook.feeState(testPoolKey.toId());

        // Intra-block price impact: the live price moves but the start-of-block snapshot governs.
        sqrtAmmPriceX96 = _boundSqrtPriceRelative(priceSeedB, cfg.referenceSqrtPriceX96);
        uint24 fee2 = _callBeforeSwap(zeroForOne);
        (uint256 storedFee2, uint160 storedPrice2, uint256 storedBlock2) = hook.feeState(testPoolKey.toId());

        assertEq(fee1, fee2);
        assertEq(storedFee1, storedFee2);
        assertEq(storedPrice1, storedPrice2);
        assertEq(storedBlock1, storedBlock2);
    }

    /// @notice With targetMultiplier = 0 the decay target IS the far-boundary fee, so for any valid
    /// config, after full decay the stored fee equals calculateFarBoundaryFee at the current price
    /// exactly. (Config-fuzzed generalization of the deterministic zero-multiplier test in
    /// StablePairHook.beforeSwap.t.sol.)
    function test_fuzz_zeroTargetMultiplier_decaysToFarBoundaryFee(ConfigSeed memory cfgSeed, uint160 priceSeed)
        public
    {
        StableFeeConfig memory cfg = _boundFeeConfig(cfgSeed);
        cfg.targetMultiplier = 0;
        _setConfig(cfg);

        // Establish an outside-range decaying-fee state at the fuzzed price.
        sqrtAmmPriceX96 = _boundSqrtPriceRelative(priceSeed, cfg.referenceSqrtPriceX96);
        vm.roll(vm.getBlockNumber() + 1);
        _callBeforeSwap(true);
        (uint256 established,,) = hook.feeState(testPoolKey.toId());
        vm.assume(established != StableFeeCalculation.UNDEFINED_DECAYING_FEE_E12);

        // Nudge one price unit further from reference so the price-movement path runs (equal prices
        // bypass adjustPreviousFeeForPriceMovement), guarding the v4 price limits.
        vm.assume(sqrtAmmPriceX96 > TickMath.MIN_SQRT_PRICE && sqrtAmmPriceX96 < TickMath.MAX_SQRT_PRICE - 1);
        sqrtAmmPriceX96 = sqrtAmmPriceX96 < cfg.referenceSqrtPriceX96 ? sqrtAmmPriceX96 - 1 : sqrtAmmPriceX96 + 1;

        // Enough blocks that the decay factor is exactly 0 even for the smallest valid logK (1),
        // so the stored fee lands exactly on the target with no residual gap.
        vm.roll(vm.getBlockNumber() + 100_000_000);
        _callBeforeSwap(true);
        (uint256 decayedFeeE12,,) = hook.feeState(testPoolKey.toId());

        uint256 priceRatioX96 = StableFeeCalculation.calculatePriceRatioX96(sqrtAmmPriceX96, cfg.referenceSqrtPriceX96);
        uint256 farBoundaryFeeE12 = StableFeeCalculation.calculateFarBoundaryFee(priceRatioX96, cfg.optimalFeeE6);
        assertEq(decayedFeeE12, farBoundaryFeeE12);
    }

    /// @notice For any valid config, a higher targetMultiplier yields a lower (or equal) decaying fee
    /// after decay — same k/optimalFee/reference/price, only the multiplier differs.
    function test_fuzz_beforeSwap_higherTargetMultiplier_lowerFeeAfterDecay(
        ConfigSeed memory cfgSeed,
        uint160 priceSeed,
        uint8 multiplierA,
        uint8 multiplierB
    ) public {
        StableFeeConfig memory base = _boundFeeConfig(cfgSeed);
        multiplierA = uint8(bound(multiplierA, 0, hook.MAX_TARGET_MULTIPLIER()));
        multiplierB = uint8(bound(multiplierB, 0, hook.MAX_TARGET_MULTIPLIER()));
        uint160 price = _boundSqrtPriceRelative(priceSeed, base.referenceSqrtPriceX96);

        uint8[2] memory multipliers = [multiplierA, multiplierB];
        uint256[2] memory fees;
        for (uint256 i = 0; i < 2; i++) {
            base.targetMultiplier = multipliers[i];
            _setConfig(base); // resets fee state

            // Establish an outside-range decaying-fee state at the fuzzed price.
            sqrtAmmPriceX96 = price;
            vm.roll(vm.getBlockNumber() + 1);
            _callBeforeSwap(true);
            (uint256 established,,) = hook.feeState(testPoolKey.toId());
            // Only meaningful when outside the optimal band (inside band has no decaying fee).
            vm.assume(established != StableFeeCalculation.UNDEFINED_DECAYING_FEE_E12);

            // Decay in place; higher multiplier => lower target => lower decayed fee.
            vm.roll(vm.getBlockNumber() + 750);
            _callBeforeSwap(true);
            (fees[i],,) = hook.feeState(testPoolKey.toId());
        }

        if (multiplierA > multiplierB) {
            assertLe(fees[0], fees[1]);
        } else if (multiplierA < multiplierB) {
            assertGe(fees[0], fees[1]);
        } else {
            assertEq(fees[0], fees[1]);
        }
    }
}
