// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StablePairHook} from "../../src/stable/StablePairHook.sol";
import {BaseDynamicFeeHook} from "../../src/base/BaseDynamicFeeHook.sol";
import {StablePairTestBase} from "./base/StablePairTestBase.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {StableFeeConfig} from "../../src/stable/interfaces/IStableFeeConfiguration.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
// Referenced only by name in `deployCodeTo`; imported so forge includes its artifact in the build.
import {ERC1967Proxy as _ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// forge-config: default.fuzz.runs = 2048
contract StablePairHookSwapTest is StablePairTestBase, Deployers {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    PoolKey public poolKey;

    function setUp() public override {
        // Deploy manager and all test routers (swapRouter, modifyLiquidityRouter, etc.)
        deployFreshManagerAndRouters();

        // Deploy two real ERC20 tokens, mint, and approve all routers
        deployMintAndApprove2Currencies();

        StablePairHook impl = new StablePairHook(manager);

        // The proxy is the registered v4 hook, so its address must encode the permission flags.
        hook = StablePairHook(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | HOOK_FLAGS)));
        // poolInitializer controls pool init, configManager controls fee config.
        deployCodeTo(
            "ERC1967Proxy.sol:ERC1967Proxy",
            abi.encode(
                address(impl), abi.encodeCall(BaseDynamicFeeHook.initialize, (owner, poolInitializer, configManager))
            ),
            address(hook)
        );

        // Build pool key with real tokens and dynamic fee; the registered hook is the proxy.
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        // Initialize pool at 1:1 price via the implementation (NOT manager.initialize)
        vm.prank(poolInitializer);
        hook.initializePool(poolKey, Constants.SQRT_PRICE_1_1, _defaultConfig());

        // Add deep liquidity across a wide range so swaps have minimal price impact
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 100e18, salt: 0}),
            ZERO_BYTES
        );
    }

    /// @notice A swap through the pool manager actually charges a fee (output < input for 1:1 pool)
    function test_swap_feeReducesOutput_zeroForOne() public {
        int256 amountIn = -1e15; // small exact-input to minimize price impact

        BalanceDelta delta = swap(poolKey, true, amountIn, ZERO_BYTES);

        int128 spent = delta.amount0(); // negative (tokens spent)
        int128 received = delta.amount1(); // positive (tokens received)

        // At 1:1 price, output should be less than input due to fee
        assertLt(received, -spent);

        // The fee is ~0.9 bps = 90/1e6, so output ~= input * (1 - 90/1e6)
        // Allow 1% tolerance for price impact
        uint256 expectedOutput = uint256(-amountIn) * (1e6 - OPTIMAL_FEE_E6) / 1e6;
        assertApproxEqRel(uint256(uint128(received)), expectedOutput, 0.01e18);
    }

    /// @notice Same test in the other direction
    function test_swap_feeReducesOutput_oneForZero() public {
        int256 amountIn = -1e15;

        BalanceDelta delta = swap(poolKey, false, amountIn, ZERO_BYTES);

        int128 spent = delta.amount1(); // negative
        int128 received = delta.amount0(); // positive

        assertLt(received, -spent);

        uint256 expectedOutput = uint256(-amountIn) * (1e6 - OPTIMAL_FEE_E6) / 1e6;
        assertApproxEqRel(uint256(uint128(received)), expectedOutput, 0.01e18);
    }

    /// @notice Outside optimal range: 0 fee for swaps moving away from reference, nonzero fee for swaps moving toward.
    /// Uses vm.snapshot/revertTo to test both directions from the same AMM state, then normalizes
    /// outputs by the AMM price so we can compare fee impact across directions.
    function test_swap_outsideOptimalRange_directionalFeeAsymmetry() public {
        // Move the AMM price below reference
        swap(poolKey, true, -10e18, ZERO_BYTES);
        vm.roll(vm.getBlockNumber() + 1);

        // Read the current AMM price to normalize cross-direction comparison
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolKey.toId());
        uint256 priceX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);

        // Snapshot to test both directions from the same state
        uint256 snapId = vm.snapshotState();

        // Away: zeroForOne (further below reference), expected ~0 fee
        BalanceDelta deltaAway = swap(poolKey, true, -1e15, ZERO_BYTES);
        uint256 outputAway = uint256(uint128(deltaAway.amount1()));
        // No-fee expected output for zeroForOne: input * price
        uint256 expectedAway = (1e15 * priceX192) >> 192;

        vm.revertToState(snapId);

        // Toward: oneForZero (back toward reference), expected nonzero fee
        BalanceDelta deltaToward = swap(poolKey, false, -1e15, ZERO_BYTES);
        uint256 outputToward = uint256(uint128(deltaToward.amount0()));
        // No-fee expected output for oneForZero: input / price
        uint256 expectedToward = (1e15 << 192) / priceX192;

        // Both outputs are slightly less than expected due to price impact.
        // But the toward swap loses MORE because it also pays a fee.
        // Normalize: awayRatio = outputAway/expectedAway, towardRatio = outputToward/expectedToward
        // awayRatio > towardRatio  <=>  outputAway * expectedToward > outputToward * expectedAway
        assertGt(outputAway * expectedToward, outputToward * expectedAway);
    }

    // =====================================================================
    // FEE CORRECTNESS: compare fee configs
    // =====================================================================

    /// @notice Higher optimalFeeE6 -> less output for the same swap
    function test_swap_higherFee_lessOutput() public {
        // Snapshot initial state (pool at 1:1 with default fee config)
        uint256 snapId = vm.snapshotState();

        // Swap with default fee config (90 = 0.9 bps)
        BalanceDelta delta1 = swap(poolKey, true, -1e15, ZERO_BYTES);
        int128 output1 = delta1.amount1();

        vm.revertToState(snapId);

        // Update fee config to higher fee (500 = 5 bps)
        StableFeeConfig memory higherFeeConfig = StableFeeConfig({
            k: K, optimalFeeE6: 500, targetMultiplier: 50, referenceSqrtPriceX96: REFERENCE_SQRT_PRICE_X96
        });
        vm.prank(configManager);
        hook.updateFeeConfig(poolKey.toId(), higherFeeConfig);

        // Same swap with higher fee config
        BalanceDelta delta2 = swap(poolKey, true, -1e15, ZERO_BYTES);
        int128 output2 = delta2.amount1();

        // Higher fee should produce less output
        assertGt(output1, output2, "higher fee should produce less output");
    }

    // =====================================================================
    // FUZZ: e2e swaps never revert across arbitrary sequences
    // =====================================================================

    /// @notice Fuzz: large swap followed by small swap in opposite direction never reverts.
    /// Exercises the price-movement + fee-decay path through the real pool manager.
    function test_fuzz_swap_largeThenSmall_neverRevert(
        ConfigSeed memory cfgSeed,
        bool firstDirection,
        uint256 largeAmount,
        uint256 smallAmount,
        uint256 blockGap
    ) public {
        StableFeeConfig memory cfg = _boundFeeConfig(cfgSeed);
        cfg.referenceSqrtPriceX96 = REFERENCE_SQRT_PRICE_X96;
        vm.prank(configManager);
        hook.updateFeeConfig(poolKey.toId(), cfg);

        largeAmount = bound(largeAmount, 1e18, 50e18);
        smallAmount = bound(smallAmount, 1e12, 1e16);
        blockGap = bound(blockGap, 0, 10_000);

        // Large swap moves price
        swap(poolKey, firstDirection, -int256(largeAmount), ZERO_BYTES);

        vm.roll(vm.getBlockNumber() + blockGap);

        // Small swap in opposite direction (toward reference) — exercises decaying fee path
        swap(poolKey, !firstDirection, -int256(smallAmount), ZERO_BYTES);
    }

    /// @notice e2e: for any valid config, a random sequence of real swaps never reverts.
    /// Complements the mocked invariant with real swap mechanics through the proxy.
    function test_fuzz_e2e_swap_neverReverts(
        ConfigSeed memory cfgSeed,
        uint256 directions,
        uint256 amounts,
        uint256 blockGaps
    ) public {
        // Reference price must stay 1:1 so the seeded 1:1 pool matches the config's reference.
        StableFeeConfig memory cfg = _boundFeeConfig(cfgSeed);
        cfg.referenceSqrtPriceX96 = REFERENCE_SQRT_PRICE_X96;
        vm.prank(configManager);
        hook.updateFeeConfig(poolKey.toId(), cfg);

        for (uint256 i = 0; i < 6; i++) {
            bool zeroForOne = (directions >> i) & 1 == 1;
            uint256 amount = bound(uint256(keccak256(abi.encode(amounts, i))), 1e12, 1e18);
            bool exactOutput = (directions >> (i + 128)) & 1 == 1;
            swap(poolKey, zeroForOne, exactOutput ? int256(amount) : -int256(amount), ZERO_BYTES);
            uint256 gap = bound((blockGaps >> (i * 16)) & 0xFFFF, 0, 10_000);
            vm.roll(vm.getBlockNumber() + gap);
        }
    }

    /// @notice Saturation-and-recovery, end to end: encodes why the fee is clamped to 999_998
    /// rather than capped lower, and what the clamp actually buys.
    /// With targetMultiplier = 0 the saturated far-boundary fee is a fixed point of the decay,
    /// so the toward-reference fee pins at the clamp until the price recovers. Recovery itself
    /// is fee-independent: the stranded price sits in empty tick space, and zero-liquidity swap
    /// steps advance the price without consuming input at ANY fee (SwapMath.computeSwapStep's
    /// max-fee branch: `amountIn` is 0 through empty ticks). What the clamp specifically fixes
    /// is the swap's economics at the boundary: at exactly 1e6 the entire input is taken as fee
    /// and the swapper receives NOTHING (and exact-output swaps revert); at the clamp a nonzero
    /// remainder reaches the curve, so quotes stay honest and the recovering swapper is paid.
    function test_saturatedPool_recoversWithDustSwap() public {
        StableFeeConfig memory cfg = _defaultConfig();
        cfg.targetMultiplier = 0;
        vm.prank(configManager);
        hook.updateFeeConfig(poolKey.toId(), cfg);

        // Push the price away from reference to the bottom of the tick range: the away direction
        // is charged 0 fee and the ticks below the liquid range are empty, so this is cheap.
        swap(poolKey, true, -100e18, ZERO_BYTES);
        (, int24 tickAfterPush,,) = manager.getSlot0(poolKey.toId());
        assertLt(tickAfterPush, -800_000, "push should strand the price near MIN_TICK");

        // New block: the toward-reference fee recomputes from the stranded price and saturates
        // to the clamp (unclamped it would quote exactly 1e6).
        vm.roll(vm.getBlockNumber() + 1);
        (uint24 feeZeroForOne, uint24 feeOneForZero) = hook.getFee(poolKey);
        assertEq(feeZeroForOne, 0, "away direction stays free");
        assertEq(feeOneForZero, 999_998, "toward-reference fee saturates to the clamp");

        // Recovery: a dust exact-input swap toward reference. 1e-6 of the input survives the fee,
        // and any nonzero remainder snaps the price across the empty tick range back to the edge
        // of the liquid range.
        BalanceDelta recoveryDelta = swap(poolKey, false, -1e7, ZERO_BYTES);
        (, int24 tickAfterRecovery,,) = manager.getSlot0(poolKey.toId());
        assertGt(tickAfterRecovery, -6060, "dust swap must snap the price back to the liquid range");
        // The clamp-specific guarantee: the swapper is paid for recovering the pool. At an
        // unclamped 1e6 fee the price recovery still happens, but the output here is zero.
        assertGt(recoveryDelta.amount0(), 0, "recovering swapper must receive nonzero output");

        // Next block: the fee recomputes from the recovered price and de-saturates (~45% at the
        // -6000 range edge: 1 - 1.0001^-6000 * (1 - optimalFee)).
        vm.roll(vm.getBlockNumber() + 1);
        (, uint24 feeTowardAfter) = hook.getFee(poolKey);
        assertGt(feeTowardAfter, 400_000, "fee should reflect the ~45% discount at the range edge");
        assertLt(feeTowardAfter, 500_000, "fee must de-saturate once price is back at liquidity");
    }

    /// @notice Adversarial variant: dust liquidity seeded in the recovery path. At a fee of
    /// exactly 1e6 the free traversal only works through PERFECTLY empty tick space -- any
    /// liquidity in the path (even dust, nearly free to place single-sided) needs amountIn >= 1
    /// while the net-of-fee input is 0, so the price stops at the dust range and the pool is
    /// genuinely deadlocked (the fee re-saturates every block). The clamp fixes this robustly:
    /// the nonzero remainder crosses dust liquidity with dust input.
    function test_saturatedPool_dustLiquidityInPath_stillRecovers() public {
        StableFeeConfig memory cfg = _defaultConfig();
        cfg.targetMultiplier = 0;
        vm.prank(configManager);
        hook.updateFeeConfig(poolKey.toId(), cfg);

        // Attacker seeds dust liquidity far below the liquid range, in the future recovery path.
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -887_220, tickUpper: -800_040, liquidityDelta: 1e3, salt: 0}),
            ZERO_BYTES
        );

        // Push the price down into the dust range (away = 0 fee). The push strands INSIDE the
        // dust liquidity: pushing all the way through it toward MIN_TICK would cost enormous
        // raw token0 amounts (1/sqrtP explodes near the bottom), so this is where a real
        // griefing push ends up — and for the deadlock question it is the worst case, since
        // the price sits directly in liquidity where a 1e6 fee leaves zero net input to move.
        swap(poolKey, true, -100e18, ZERO_BYTES);
        (, int24 tickAfterPush,,) = manager.getSlot0(poolKey.toId());
        assertLt(tickAfterPush, -800_000, "push should strand the price inside the dust range");

        vm.roll(vm.getBlockNumber() + 1);
        (, uint24 feeToward) = hook.getFee(poolKey);
        assertEq(feeToward, 999_998, "toward-reference fee saturates to the clamp");

        // Recovery must cross the dust range: at the clamp the 1e-6 remainder is enough; at an
        // unclamped 1e6 fee the price would stop at the dust range's lower tick forever.
        swap(poolKey, false, -1e7, ZERO_BYTES);
        (, int24 tickAfterRecovery,,) = manager.getSlot0(poolKey.toId());
        assertGt(tickAfterRecovery, -6060, "dust swap must cross dust liquidity back to the liquid range");

        vm.roll(vm.getBlockNumber() + 1);
        (, uint24 feeTowardAfter) = hook.getFee(poolKey);
        assertLt(feeTowardAfter, 500_000, "fee must de-saturate after recovery");
    }

    /// @notice Protocol-fee variant of the saturation test: the fee v4 charges is NOT the hook's
    /// LP fee alone. Pool.swap compounds it with the directional protocol fee (protocol taken
    /// first, LP fee on the remainder) and rounds the combined fee UP to a whole pip. A clamp of
    /// 999_999 therefore compounds to exactly 1e6 for ANY nonzero protocol fee — recreating the
    /// 100%-fee state: exact-output swaps revert and the recovering swapper pays the full input
    /// for zero output. The clamp must leave headroom for the max protocol fee.
    function test_saturatedPool_withMaxProtocolFee_recoverySwapperStillPaid() public {
        vm.prank(feeController);
        manager.setProtocolFee(
            poolKey, uint24(ProtocolFeeLibrary.MAX_PROTOCOL_FEE) << 12 | uint24(ProtocolFeeLibrary.MAX_PROTOCOL_FEE)
        );

        StableFeeConfig memory cfg = _defaultConfig();
        cfg.targetMultiplier = 0;
        vm.prank(configManager);
        hook.updateFeeConfig(poolKey.toId(), cfg);

        // Same saturation path as test_saturatedPool_recoversWithDustSwap: strand the price in
        // empty tick space far below the liquid range, then let the toward-reference fee saturate.
        swap(poolKey, true, -100e18, ZERO_BYTES);
        (, int24 tickAfterPush,,) = manager.getSlot0(poolKey.toId());
        assertLt(tickAfterPush, -800_000, "push should strand the price near MIN_TICK");

        vm.roll(vm.getBlockNumber() + 1);
        (, uint24 feeToward) = hook.getFee(poolKey);
        // Combined with the max protocol fee, the charged fee must still be below 100%.
        assertLt(
            ProtocolFeeLibrary.calculateSwapFee(ProtocolFeeLibrary.MAX_PROTOCOL_FEE, feeToward),
            SwapMath.MAX_SWAP_FEE,
            "saturated LP fee + max protocol fee must stay below 100%"
        );

        // The clamp-specific guarantee, now under protocol fees: a nonzero remainder reaches the
        // curve, so the recovering swapper is paid. At a combined fee of exactly 1e6 this output
        // is zero (the entire input is consumed as fee).
        BalanceDelta recoveryDelta = swap(poolKey, false, -1e7, ZERO_BYTES);
        (, int24 tickAfterRecovery,,) = manager.getSlot0(poolKey.toId());
        assertGt(tickAfterRecovery, -6060, "dust swap must snap the price back to the liquid range");
        assertGt(recoveryDelta.amount0(), 0, "recovering swapper must receive nonzero output despite protocol fee");
    }

    /// @notice Pins the exact shape of the clamp's guarantee, which is deliberately narrow:
    /// (1) exact-output swaps stay available at the saturated fee (at a combined fee of 1e6 v4
    ///     reverts with InvalidFeeForExactOut), and
    /// (2) an exact-input swap only moves the price through ACTIVE liquidity if its post-fee
    ///     remainder is nonzero. At the worst-case combined fee of 999_999 only 1/1e6 of the
    ///     input survives, so inputs below 1e6 raw units truncate to a zero remainder: the price
    ///     still coasts across empty tick ranges (zero-liquidity steps consume no input — true
    ///     even at a 1e6 fee) but the swapper receives nothing. The clamp does NOT promise that
    ///     every swap moves the price — only that recovery is possible for large-enough inputs.
    function test_saturatedPool_withMaxProtocolFee_guaranteeShape() public {
        vm.prank(feeController);
        manager.setProtocolFee(
            poolKey, uint24(ProtocolFeeLibrary.MAX_PROTOCOL_FEE) << 12 | uint24(ProtocolFeeLibrary.MAX_PROTOCOL_FEE)
        );

        StableFeeConfig memory cfg = _defaultConfig();
        cfg.targetMultiplier = 0;
        vm.prank(configManager);
        hook.updateFeeConfig(poolKey.toId(), cfg);

        // Strand the price in empty tick space and let the toward-reference fee saturate.
        swap(poolKey, true, -100e18, ZERO_BYTES);
        vm.roll(vm.getBlockNumber() + 1);

        // (2) Sub-threshold exact-input: the post-fee remainder is zero, so the price coasts
        // through the EMPTY tick range up to the edge of active liquidity but no further, and
        // the swapper is paid nothing. Same-block quotes pin to start-of-block state, so the
        // saturated fee still applies to the swaps below.
        BalanceDelta subThresholdDelta = swap(poolKey, false, -(1e6 - 1), ZERO_BYTES);
        assertEq(subThresholdDelta.amount0(), 0, "sub-threshold input rounds to zero remainder: no output");
        (, int24 tickAfterCoast,,) = manager.getSlot0(poolKey.toId());
        assertGt(tickAfterCoast, -6060, "price still coasts across empty ticks to the liquid range edge");

        // (1) Exact-output at the saturated fee must NOT revert and must deliver the requested
        // output through active liquidity (the input charged is ~1e6x the output).
        BalanceDelta exactOutDelta = swap(poolKey, false, 1e3, ZERO_BYTES);
        assertEq(exactOutDelta.amount0(), 1e3, "exact-output must remain available at the saturated fee");
    }
}
