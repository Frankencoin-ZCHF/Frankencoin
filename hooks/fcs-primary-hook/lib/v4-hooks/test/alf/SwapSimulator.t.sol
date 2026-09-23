// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SwapSimulator} from "../../src/alf/libraries/SwapSimulator.sol";

/// @dev Concrete consumer for the internal library functions so the suite drives the simulator
///      directly rather than through a quoter hook. Mirrors how SpreadQuoterBase and the
///      multiplexer's tier-2 path invoke it.
contract SwapSimulatorDirectHarness {
    function simulate(
        IPoolManager manager,
        PoolId poolId,
        bool zeroForOne,
        int256 amountSpecified,
        uint24 lpFeePips,
        int24 tickSpacing
    ) external view returns (uint256) {
        return SwapSimulator.simulateSwap(manager, poolId, zeroForOne, amountSpecified, lpFeePips, tickSpacing);
    }

    function simulateToPrice(
        IPoolManager manager,
        PoolId poolId,
        bool zeroForOne,
        int256 amountSpecified,
        uint24 lpFeePips,
        int24 tickSpacing,
        uint160 sqrtPriceLimitX96
    ) external view returns (uint256 amountIn, uint256 amountOut) {
        return SwapSimulator.simulateSwapToPrice(
            manager, poolId, zeroForOne, amountSpecified, lpFeePips, tickSpacing, sqrtPriceLimitX96
        );
    }
}

/// @notice Direct branch-coverage suite for `SwapSimulator`'s soft-fail contract: every input
///         shape `Pool.swap` would reject must return `(0, 0)` (never revert), plus the
///         `InvalidLpFeePips` boundary check and the `MAX_WALK_STEPS` runaway-walk cap.
contract SwapSimulatorTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    SwapSimulatorDirectHarness internal harness;

    PoolKey internal vanillaKey; // fee 3000, spacing 60, seeded liquidity
    PoolId internal vanillaId;

    uint24 internal constant FEE = 3000;
    int24 internal constant SPACING = 60;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        harness = new SwapSimulatorDirectHarness();

        vanillaKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(0))
        });
        vanillaId = vanillaKey.toId();
        manager.initialize(vanillaKey, Constants.SQRT_PRICE_1_1);

        modifyLiquidityRouter.modifyLiquidity(
            vanillaKey, ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1_000e18, salt: 0}), ""
        );
    }

    // ══════════════════════════════════════════════════════════
    //  Happy path sanity (both swap types through the harness)
    // ══════════════════════════════════════════════════════════

    function test_simulate_exactIn_returnsOutput() public view {
        uint256 out = harness.simulate(manager, vanillaId, true, -1e18, FEE, SPACING);
        assertGt(out, 0, "exact-in output");
        assertLt(out, 1e18, "output below input for a fee'd 1:1 pool");
    }

    function test_simulate_exactOut_returnsInput() public view {
        uint256 inAmt = harness.simulate(manager, vanillaId, true, int256(1e18), FEE, SPACING);
        assertGt(inAmt, 1e18, "exact-out input exceeds output for a fee'd 1:1 pool");
    }

    // ══════════════════════════════════════════════════════════
    //  Pre-loop soft-fail regimes: (0, 0), never a revert
    // ══════════════════════════════════════════════════════════

    function test_simulate_uninitializedPool_returnsZero() public view {
        PoolKey memory ghost =
            PoolKey({currency0: currency0, currency1: currency1, fee: 500, tickSpacing: 10, hooks: IHooks(address(0))});
        (uint256 amountIn, uint256 amountOut) =
            harness.simulateToPrice(manager, ghost.toId(), true, -1e18, 500, 10, TickMath.MIN_SQRT_PRICE + 1);
        assertEq(amountIn, 0, "uninitialized pool: no input");
        assertEq(amountOut, 0, "uninitialized pool: no output");
    }

    function test_simulate_zeroAmount_returnsZero() public view {
        (uint256 amountIn, uint256 amountOut) =
            harness.simulateToPrice(manager, vanillaId, true, 0, FEE, SPACING, TickMath.MIN_SQRT_PRICE + 1);
        assertEq(amountIn, 0);
        assertEq(amountOut, 0);
    }

    function test_simulate_wrongSideLimit_returnsZero() public view {
        (uint160 current,,,) = _slot0();

        // zeroForOne moves price down; a limit at/above current can never be approached.
        (uint256 in0, uint256 out0) = harness.simulateToPrice(manager, vanillaId, true, -1e18, FEE, SPACING, current);
        assertEq(in0, 0, "zeroForOne limit >= current soft-fails");
        assertEq(out0, 0);

        // oneForZero moves price up; a limit at/below current can never be approached.
        (uint256 in1, uint256 out1) = harness.simulateToPrice(manager, vanillaId, false, -1e18, FEE, SPACING, current);
        assertEq(in1, 0, "oneForZero limit <= current soft-fails");
        assertEq(out1, 0);
    }

    function test_simulate_limitAtBoundary_returnsZero() public view {
        // Pool.swap rejects the exact MIN/MAX boundary values strictly; the simulator mirrors
        // that as a (0, 0) soft-fail instead of walking the whole bitmap.
        (uint256 in0, uint256 out0) =
            harness.simulateToPrice(manager, vanillaId, true, -1e18, FEE, SPACING, TickMath.MIN_SQRT_PRICE);
        assertEq(in0, 0, "limit == MIN_SQRT_PRICE soft-fails");
        assertEq(out0, 0);

        (uint256 in1, uint256 out1) =
            harness.simulateToPrice(manager, vanillaId, false, -1e18, FEE, SPACING, TickMath.MAX_SQRT_PRICE);
        assertEq(in1, 0, "limit == MAX_SQRT_PRICE soft-fails");
        assertEq(out1, 0);
    }

    // ══════════════════════════════════════════════════════════
    //  Fee boundary
    // ══════════════════════════════════════════════════════════

    function test_simulate_feeAboveMaxSwapFee_reverts() public {
        uint24 bad = uint24(SwapMath.MAX_SWAP_FEE) + 1;
        vm.expectRevert(abi.encodeWithSelector(SwapSimulator.InvalidLpFeePips.selector, bad));
        harness.simulate(manager, vanillaId, true, -1e18, bad, SPACING);
    }

    // ══════════════════════════════════════════════════════════
    //  MAX_WALK_STEPS runaway-walk cap
    // ══════════════════════════════════════════════════════════

    /// @dev A tickSpacing-1 pool initialized near MAX_TICK with zero liquidity: a zeroForOne
    ///      walk toward MIN crosses ~6.9k bitmap words with nothing to consume, so neither
    ///      exit condition (`amountRemaining == 0`, `price == limit`) fires before the
    ///      `MAX_WALK_STEPS` cap. The cap must exit gracefully with the partial (here zero)
    ///      result instead of reverting or walking the full range.
    ///
    ///      The cap is proven by a gas RATIO against a reference walk that terminates
    ///      naturally below the cap (~3.5k words, from tick 0 to MIN). Capped, the
    ///      pathological walk costs ~4096/3466 = ~1.18x the reference; uncapped it would
    ///      cost ~2x. A ratio bound stays valid under coverage instrumentation, which
    ///      inflates both walks proportionally (an absolute gas bound does not).
    function test_simulate_walkCap_boundsPathologicalEmptyWalk() public {
        // Reference: ~3.5k-word empty walk that finishes before the cap.
        PoolKey memory refKey =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, tickSpacing: 1, hooks: IHooks(address(0))});
        manager.initialize(refKey, Constants.SQRT_PRICE_1_1);

        uint256 gasBefore = gasleft();
        harness.simulateToPrice(manager, refKey.toId(), true, -1e30, 100, 1, TickMath.MIN_SQRT_PRICE + 1);
        uint256 gasReference = gasBefore - gasleft();

        // Pathological: ~6.9k-word walk that only the cap can bound.
        PoolKey memory sparse =
            PoolKey({currency0: currency0, currency1: currency1, fee: 200, tickSpacing: 1, hooks: IHooks(address(0))});
        manager.initialize(sparse, TickMath.getSqrtPriceAtTick(887_200));

        gasBefore = gasleft();
        (uint256 amountIn, uint256 amountOut) =
            harness.simulateToPrice(manager, sparse.toId(), true, -1e30, 200, 1, TickMath.MIN_SQRT_PRICE + 1);
        uint256 gasCapped = gasBefore - gasleft();

        assertEq(amountIn, 0, "empty pool consumes nothing");
        assertEq(amountOut, 0, "empty pool outputs nothing");
        // Capped/reference ratio ≈ 1.18; uncapped/reference ≈ 2.0. 1.6 splits the regimes.
        assertLt(gasCapped, (gasReference * 16) / 10, "walk bounded by MAX_WALK_STEPS");
    }

    // ══════════════════════════════════════════════════════════
    //  int128 cumulative-overflow soft-fail (Pool.swap toInt128 parity)
    // ══════════════════════════════════════════════════════════

    /// @dev Mirrors `Pool.swap`'s final `toInt128()` cast on the specified leg. At a fee of
    ///      999_999 pips (~100%), gross input is inflated ~1e6x over the net curve cost, so a
    ///      full-range position of modest liquidity can absorb a gross input beyond
    ///      `int128.max`. The real swap would revert `SafeCastOverflow`; the simulator must
    ///      soft-fail to `(0, 0)` to stay in parity.
    function test_simulate_int128OverflowOnSpecifiedLeg_softFails() public {
        PoolKey memory deep = PoolKey({
            currency0: currency0, currency1: currency1, fee: 100, tickSpacing: SPACING, hooks: IHooks(address(0))
        });
        // Distinct pool: same currencies, different fee. Full-range position, modest liquidity.
        manager.initialize(deep, Constants.SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            deep, ModifyLiquidityParams({tickLower: -887_220, tickUpper: 887_220, liquidityDelta: 1e15, salt: 0}), ""
        );

        // |amountSpecified| = 3e38 > int128.max (~1.7e38). With fee 999_999 the pool's gross
        // input capacity toward MIN far exceeds it, so the walk exhausts the specified amount
        // and the cumulative `specifiedFilled` overflows int128.
        (uint256 amountIn, uint256 amountOut) =
            harness.simulateToPrice(manager, deep.toId(), true, -3e38, 999_999, SPACING, TickMath.MIN_SQRT_PRICE + 1);

        assertEq(amountIn, 0, "int128 overflow on gross input soft-fails");
        assertEq(amountOut, 0);
    }

    // ══════════════════════════════════════════════════════════
    //  Helpers
    // ══════════════════════════════════════════════════════════

    function _slot0() internal view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) {
        return StateLibrary.getSlot0(manager, vanillaId);
    }
}
