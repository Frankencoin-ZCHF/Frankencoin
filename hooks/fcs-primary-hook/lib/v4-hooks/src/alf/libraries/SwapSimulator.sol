// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {FeeLib} from "./FeeLib.sol";

/// @title SwapSimulator
/// @author Uniswap Labs
/// @notice View-only library that replicates Pool.sol's tick-walking swap loop using
///         external state reads via StateLibrary.extsload(). Produces indicative quotes
///         that closely match actual swap execution for the current pool fee.
/// @custom:security-contact security@uniswap.org
library SwapSimulator {
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    /// @dev `lpFeePips` exceeds `SwapMath.MAX_SWAP_FEE` (1e6). Forwarding such a value into
    ///      `SwapMath.computeSwapStep`'s unchecked body would underflow `MAX_SWAP_FEE - fee`
    ///      and produce either an empty revert at `FullMath.mulDiv`'s overflow guard
    ///      (exact-input path with large amounts) or a numerically meaningless quote
    ///      equivalent to a 0% fee swap (smaller amounts, exact-output path). Reverting
    ///      cleanly here gives callers an unambiguous diagnostic.
    /// @param supplied The invalid fee value the caller passed.
    error InvalidLpFeePips(uint24 supplied);

    /// @dev Hard cap on `_walkTicks` iterations. Bounds the worst-case gas for pathological
    ///      scenarios (unseeded pool, oversized swap walking past LP into empty tick space,
    ///      sparse-bitmap walks) regardless of whether the caller honors `BaseALFHook.maxGas`.
    ///      The loop exits early on `amountRemaining == 0` or hitting the price limit; this
    ///      cap only fires for runaway walks.
    ///
    ///      4_096 covers every legitimate use of the library:
    ///        - SpreadQuoter single-band: <10 steps
    ///        - DualPoolHook 8-bucket distributions at typical spacings: <100 steps
    ///        - Extreme wide-bucket configs spanning many bitmap words: still well under
    ///      while still bounding the worst case to ~20M gas at ~5K gas/iter (well under one
    ///      block, so an on-chain caller without a `{gas:}` envelope OOGs the call, not the
    ///      block). Hitting the cap returns the partial output computed so far; for a quote
    ///      consumer this surfaces as a smaller-than-expected output, which the caller can
    ///      detect via slippage bounds.
    uint256 internal constant MAX_WALK_STEPS = 4_096;

    struct SwapState {
        uint160 sqrtPriceX96;
        int24 tick;
        uint128 liquidity;
        int256 amountRemaining;
        int256 amountCalc;
        uint160 sqrtPriceLimitX96;
        bool completed;
    }

    /// @notice Virtual change to one initialized tick used during adjusted simulation.
    /// @param tick Tick whose liquidity should be adjusted.
    /// @param liquidityNetDelta Signed change to the tick's liquidity net.
    /// @param liquidityGrossRemoved Gross liquidity removed from the tick.
    struct TickAdjustment {
        int24 tick;
        int128 liquidityNetDelta;
        uint128 liquidityGrossRemoved;
    }

    /// @notice Parameters for adjusted swap simulation.
    /// @param manager PoolManager contract.
    /// @param poolId Pool to simulate.
    /// @param zeroForOne Swap direction.
    /// @param amountSpecified Negative for exact input, positive for exact output.
    /// @param lpFeePips LP fee to apply in pips.
    /// @param tickSpacing Pool tick spacing.
    /// @param sqrtPriceLimitX96 Target sqrt price limit in Q64.96.
    /// @param activeLiquidityDelta Signed virtual change to current in-range liquidity.
    /// @param tickAdjustments Virtual tick-level liquidity removals.
    /// @param tickAdjustmentCount Number of entries in `tickAdjustments` to use.
    /// @param maxTickSteps Maximum initialized-tick steps to simulate. Zero means unbounded.
    struct SimulationParams {
        IPoolManager manager;
        PoolId poolId;
        bool zeroForOne;
        int256 amountSpecified;
        uint24 lpFeePips;
        int24 tickSpacing;
        uint160 sqrtPriceLimitX96;
        int128 activeLiquidityDelta;
        TickAdjustment[] tickAdjustments;
        uint256 tickAdjustmentCount;
        uint256 maxTickSteps;
    }

    /// @notice Internal tick-walk parameters.
    /// @param manager PoolManager contract.
    /// @param poolId Pool to simulate.
    /// @param zeroForOne Swap direction.
    /// @param feePips Effective swap fee in pips.
    /// @param tickSpacing Pool tick spacing.
    /// @param exactInput True when `amountSpecified` is exact input.
    /// @param tickAdjustments Virtual tick-level liquidity removals.
    /// @param tickAdjustmentCount Number of entries in `tickAdjustments` to use.
    /// @param maxTickSteps Maximum initialized-tick steps to simulate. Zero means unbounded.
    struct WalkParams {
        IPoolManager manager;
        PoolId poolId;
        bool zeroForOne;
        uint24 feePips;
        int24 tickSpacing;
        bool exactInput;
        TickAdjustment[] tickAdjustments;
        uint256 tickAdjustmentCount;
        uint256 maxTickSteps;
    }

    /// @notice Simulate a swap against a v4 pool's current state.
    /// @param manager The PoolManager contract.
    /// @param poolId The pool to simulate against.
    /// @param zeroForOne The swap direction.
    /// @param amountSpecified Negative for exact input, positive for exact output.
    /// @param lpFeePips The LP fee to apply (same as the hook's fee override).
    /// @param tickSpacing The pool's tick spacing.
    /// @return result For exact input: total output amount. For exact output: total input required.
    function simulateSwap(
        IPoolManager manager,
        PoolId poolId,
        bool zeroForOne,
        int256 amountSpecified,
        uint24 lpFeePips,
        int24 tickSpacing
    ) internal view returns (uint256 result) {
        uint160 sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        (uint256 amountIn, uint256 amountOut) =
            simulateSwapToPrice(manager, poolId, zeroForOne, amountSpecified, lpFeePips, tickSpacing, sqrtPriceLimitX96);
        result = amountSpecified < 0 ? amountOut : amountIn;
    }

    /// @notice Simulate a swap up to a target price, returning both amounts.
    /// @dev Walks ticks until the price limit is reached or the specified amount is exhausted.
    ///      Mirrors Pool.sol's swap loop with protocol fee handling.
    ///
    ///      Soft-fail contract: returns `(0, 0)` (never reverts) for every input shape
    ///      `Pool.swap` would reject with `PriceLimitAlreadyExceeded` or `PriceLimitOutOfBounds`.
    ///      Routers and aggregators that take the output at face value can rely on the
    ///      invariant `(amountIn, amountOut) == (0, 0)` ⇔ "untradable at these parameters".
    ///      Pre-loop rejection cases:
    ///        - uninitialized pool (`slot0.sqrtPriceX96 == 0`)
    ///        - `amountSpecified == 0`
    ///        - `sqrtPriceLimitX96` on the wrong side of the current price for the chosen
    ///          direction (no swap can move price toward the limit)
    ///        - `sqrtPriceLimitX96` at or past `MIN_SQRT_PRICE` / `MAX_SQRT_PRICE`
    ///          (`Pool.swap` rejects the boundary value strictly)
    ///      Post-loop rejection case:
    ///        - cumulative `amountCalc` or `(amountSpecified - amountRemaining)` exceeds
    ///          `int128` range. Mirrors `Pool.swap`'s final `toInt128()` cast which would
    ///          `SafeCastOverflow()`: triggerable with fees near `MAX_LP_FEE`, an aggressive
    ///          correct-side limit, and the price already adjacent to the limit.
    /// @param manager The PoolManager contract.
    /// @param poolId The pool to simulate against.
    /// @param zeroForOne The swap direction.
    /// @param amountSpecified Negative for exact input, positive for exact output.
    /// @param lpFeePips The LP fee to apply (same as the hook's fee override).
    /// @param tickSpacing The pool's tick spacing.
    /// @param sqrtPriceLimitX96 The target price. Swap terminates when this price is reached
    ///        or the specified amount is exhausted, whichever comes first.
    /// @dev `amountIn` is GROSS of the protocol fee: it mirrors `Pool.swap`'s swapper frame, which
    ///      charges the LP fee plus the protocol fee, not the LP-fee-only portion. Consumers that
    ///      need the LP-only input must net out the protocol fee themselves.
    /// @return amountIn Total input consumed (gross of LP and protocol fees).
    /// @return amountOut Total output received.
    function simulateSwapToPrice(
        IPoolManager manager,
        PoolId poolId,
        bool zeroForOne,
        int256 amountSpecified,
        uint24 lpFeePips,
        int24 tickSpacing,
        uint160 sqrtPriceLimitX96
    ) internal view returns (uint256 amountIn, uint256 amountOut) {
        TickAdjustment[] memory tickAdjustments;
        return simulateSwapToPriceWithAdjustments(
            SimulationParams({
                manager: manager,
                poolId: poolId,
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                lpFeePips: lpFeePips,
                tickSpacing: tickSpacing,
                sqrtPriceLimitX96: sqrtPriceLimitX96,
                activeLiquidityDelta: 0,
                tickAdjustments: tickAdjustments,
                tickAdjustmentCount: 0,
                maxTickSteps: 0
            })
        );
    }

    /// @notice Simulate a swap with virtual liquidity adjustments applied before the first step.
    /// @dev Used by hooks that perform bounded pre-swap cleanup in `beforeSwap` and need the
    ///      indicative quote to reflect the same liquidity that execution will see.
    ///
    ///      Shares `simulateSwapToPrice`'s soft-fail contract, with one addition: when
    ///      `params.maxTickSteps` is non-zero and the walk exhausts that budget before the
    ///      amount or the price limit, the simulation is incomplete and returns `(0, 0)`
    ///      rather than pricing a partial fill as if it were the whole swap.
    /// @param params Adjusted simulation parameters.
    /// @return amountIn Total input consumed, including fees.
    /// @return amountOut Total output received.
    function simulateSwapToPriceWithAdjustments(SimulationParams memory params)
        internal
        view
        returns (uint256 amountIn, uint256 amountOut)
    {
        SwapState memory s;
        {
            int24 tick;
            uint24 protocolFee;
            uint24 storedLpFee;
            (s.sqrtPriceX96, tick, protocolFee, storedLpFee) = params.manager.getSlot0(params.poolId);
            s.tick = tick;
            s.sqrtPriceLimitX96 = params.sqrtPriceLimitX96;
            if (s.sqrtPriceX96 == 0 || params.amountSpecified == 0) return (0, 0);
            if (_invalidPriceLimit(params.zeroForOne, s.sqrtPriceX96, s.sqrtPriceLimitX96)) return (0, 0);

            params.lpFeePips = _resolveLpFee(params.lpFeePips, storedLpFee);

            // Combine protocol fee with LP fee override, mirroring Pool.sol's fee calculation.
            params.lpFeePips = FeeLib.effectiveSwapFee(params.lpFeePips, protocolFee, params.zeroForOne);
            // Mirror `Pool.swap`'s `InvalidFeeForExactOut` as a soft-fail: a 100% swap fee
            // cannot price an exact-output swap (the gross input is unbounded).
            if (params.amountSpecified > 0 && params.lpFeePips >= SwapMath.MAX_SWAP_FEE) return (0, 0);
        }
        s.liquidity = _addLiquidityDelta(params.manager.getLiquidity(params.poolId), params.activeLiquidityDelta);

        s.amountRemaining = params.amountSpecified;
        s.completed = true;

        _walkTicks(
            s,
            WalkParams({
                manager: params.manager,
                poolId: params.poolId,
                zeroForOne: params.zeroForOne,
                feePips: params.lpFeePips,
                tickSpacing: params.tickSpacing,
                exactInput: params.amountSpecified < 0,
                tickAdjustments: params.tickAdjustments,
                tickAdjustmentCount: params.tickAdjustmentCount,
                maxTickSteps: params.maxTickSteps
            })
        );
        if (!s.completed) return (0, 0);

        // Mirror `Pool.swap`'s final `toInt128()` cast on both `amountCalculated` and
        // `(amountSpecified - amountSpecifiedRemaining)` (see `Pool.sol` line 455/459).
        // If either cumulative exceeds `int128` range, the real swap reverts with
        // `SafeCastOverflow()`; soft-fail to `(0, 0)` here so the simulator stays in
        // parity. Triggerable in pathological combos (fees near `MAX_LP_FEE`, an aggressive
        // correct-side limit, price already adjacent to the limit) where a single step
        // pushes cumulative magnitude past `int128.max`.
        int256 specifiedFilled = params.amountSpecified - s.amountRemaining;
        if (s.amountCalc < type(int128).min || s.amountCalc > type(int128).max) return (0, 0);
        if (specifiedFilled < type(int128).min || specifiedFilled > type(int128).max) return (0, 0);

        if (params.amountSpecified < 0) {
            amountIn = uint256(-specifiedFilled);
            amountOut = uint256(s.amountCalc);
        } else {
            amountIn = uint256(-s.amountCalc);
            amountOut = uint256(specifiedFilled);
        }
    }

    /// @dev Core tick-walking loop; mirrors Pool.sol. Modifies `s` in place.
    ///      Extracted from the main function to stay within stack depth limits.
    ///
    ///      Gas hotspots by impact:
    ///      - Highest: per-iteration next-tick lookup and bitmap masking.
    ///      - Medium: step accumulation and tick-cross liquidity updates.
    ///      - Lower: per-iteration bounds checks and branch bookkeeping.
    function _walkTicks(SwapState memory s, WalkParams memory p) private view {
        uint256 steps;
        while (s.amountRemaining != 0 && s.sqrtPriceX96 != s.sqrtPriceLimitX96) {
            // Caller-declared step budget: hitting it marks the simulation incomplete so
            // the consumer sees `(0, 0)` rather than a partial fill priced as complete.
            if (p.maxTickSteps != 0 && steps == p.maxTickSteps) {
                s.completed = false;
                return;
            }
            // Defense against pathological bitmap walks (empty pools, oversized swaps past
            // LP, sparse bitmaps); see `MAX_WALK_STEPS` for rationale. Hitting the cap is a
            // graceful exit: the caller receives the partial output accumulated so far.
            if (steps == MAX_WALK_STEPS) break;
            unchecked {
                ++steps;
            }

            (int24 tickNext, bool initialized) = _nextInitializedTick(
                p.manager, p.poolId, s.tick, p.tickSpacing, p.zeroForOne, p.tickAdjustments, p.tickAdjustmentCount
            );

            // Clamp tickNext to valid range (MIN_TICK, MAX_TICK)
            assembly ("memory-safe") {
                tickNext := signextend(2, tickNext)
                // 887272 == TickMath.MAX_TICK (assembly cannot reference the Solidity constant)
                if slt(tickNext, sub(0, 887272)) { tickNext := sub(0, 887272) }
                if sgt(tickNext, 887272) { tickNext := 887272 }
            }

            // Cache tick→price: avoids computing getSqrtPriceAtTick(tickNext) twice
            // per step (swap target + boundary check). ~600-1200 gas saved per tick step.
            uint160 sqrtPriceNextX96 = TickMath.getSqrtPriceAtTick(tickNext);

            // Execute step + handle the non-boundary tick update inside a scoped block so
            // that sqrtPriceStartX96 dies before the tick crossing code below, keeping the
            // stack within the 16-slot limit for the getTickLiquidity call.
            {
                uint160 sqrtPriceStartX96 = _stepAndAccumulate(
                    s,
                    SwapMath.getSqrtPriceTarget(p.zeroForOne, sqrtPriceNextX96, s.sqrtPriceLimitX96),
                    p.feePips,
                    p.exactInput
                );

                // Price moved mid-tick (didn't reach boundary): recompute tick
                if (s.sqrtPriceX96 != sqrtPriceNextX96 && s.sqrtPriceX96 != sqrtPriceStartX96) {
                    s.tick = TickMath.getTickAtSqrtPrice(s.sqrtPriceX96);
                }
            }
            // sqrtPriceStartX96 is now dead; stack freed for tick crossing

            // Cross tick boundary; uses cached sqrtPriceNextX96
            if (s.sqrtPriceX96 == sqrtPriceNextX96) {
                if (initialized) {
                    (, int128 liquidityNet) = _getAdjustedTickLiquidity(
                        p.manager, p.poolId, tickNext, p.tickAdjustments, p.tickAdjustmentCount
                    );
                    unchecked {
                        if (p.zeroForOne) liquidityNet = -liquidityNet;
                    }
                    s.liquidity = _addLiquidityDelta(s.liquidity, liquidityNet);
                }
                unchecked {
                    s.tick = p.zeroForOne ? tickNext - 1 : tickNext;
                }
            }
        }
    }

    /// @dev Execute one swap step: compute amounts via SwapMath and accumulate into state.
    ///      Separated from the main loop to stay within stack depth limits while allowing
    ///      the caller to cache sqrtPriceNextX96.
    /// @return sqrtPriceStartX96 The price before the step (for boundary detection).
    function _stepAndAccumulate(SwapState memory s, uint160 sqrtPriceTargetX96, uint24 feePips, bool exactInput)
        private
        pure
        returns (uint160 sqrtPriceStartX96)
    {
        sqrtPriceStartX96 = s.sqrtPriceX96;

        (uint160 sqrtPriceAfter, uint256 amountIn, uint256 amountOut, uint256 feeAmount) =
            SwapMath.computeSwapStep(sqrtPriceStartX96, sqrtPriceTargetX96, s.liquidity, s.amountRemaining, feePips);

        // Assembly accumulation: swap amounts are bounded by pool liquidity (< 2^128),
        // well within int256 range, so SafeCast.toInt256() checks are redundant.
        // Saves ~80 gas per step by skipping 3-4 SafeCast calls.
        assembly ("memory-safe") {
            // Offsets track SwapState field order: sqrtPriceX96 @ slot 0 (s), amountRemaining @
            // slot 3 (add(s, 0x60)), amountCalc @ slot 4 (add(s, 0x80)). Keep in sync with the
            // struct layout above if fields are reordered.
            let sAmountRemaining := add(s, 0x60)
            let sAmountCalc := add(s, 0x80)
            mstore(s, sqrtPriceAfter)
            let rem := mload(sAmountRemaining)
            let calc := mload(sAmountCalc)
            let inputPlusFee := add(amountIn, feeAmount)
            switch exactInput
            case 1 {
                mstore(sAmountRemaining, add(rem, inputPlusFee))
                mstore(sAmountCalc, add(calc, amountOut))
            }
            default {
                mstore(sAmountRemaining, sub(rem, amountOut))
                mstore(sAmountCalc, sub(calc, inputPlusFee))
            }
        }
    }

    /// @dev Equivalent overflow semantics to v4-core LiquidityMath.addDelta.
    function _addLiquidityDelta(uint128 x, int128 y) private pure returns (uint128 z) {
        assembly ("memory-safe") {
            z := add(and(x, 0xffffffffffffffffffffffffffffffff), signextend(15, y))
            if shr(128, z) {
                mstore(0, 0x93dafdf1) // SafeCastOverflow()
                revert(0x1c, 0x04)
            }
        }
    }

    /// @dev Resolve the requested LP fee to the fee the simulation should charge, mirroring
    ///      Pool.sol's resolution order: an override-flagged fee is used with the flag
    ///      stripped, the dynamic-fee sentinel resolves to the pool's stored LP fee, and a
    ///      plain value is used as-is. Any resolved value above `SwapMath.MAX_SWAP_FEE`
    ///      reverts {InvalidLpFeePips}: `SwapMath.computeSwapStep` assumes a bounded fee
    ///      (its body is `unchecked`), so forwarding an out-of-range value would corrupt
    ///      the simulation or surface as an opaque downstream `FullMath` revert.
    function _resolveLpFee(uint24 requestedLpFee, uint24 storedLpFee) private pure returns (uint24 lpFee) {
        if (requestedLpFee.isOverride()) lpFee = requestedLpFee.removeOverrideFlag();
        else if (requestedLpFee.isDynamicFee()) lpFee = storedLpFee;
        else lpFee = requestedLpFee;
        if (lpFee > SwapMath.MAX_SWAP_FEE) revert InvalidLpFeePips(lpFee);
    }

    /// @dev Mirror `Pool.swap`'s `sqrtPriceLimitX96` guards; callers soft-fail to `(0, 0)`
    ///      instead of reverting. Without these, three regimes silently diverge from
    ///      execution:
    ///        - Wrong-side limit: `SwapMath.computeSwapStep` re-derives direction from the
    ///          price ordering, so the loop computes a single opposite-direction step from
    ///          `current` to `limit` and returns a numerically valid but fictional non-zero
    ///          tuple whenever current-tick liquidity > 0. Pool.swap reverts.
    ///        - Limit at MIN/MAX_SQRT_PRICE: simulator walks the entire bitmap to the
    ///          boundary; Pool.swap reverts strictly at equality.
    ///        - Limit past boundary: walk's exit conditions (`amountRemaining == 0` or
    ///          `sqrtPriceX96 == sqrtPriceLimitX96`) can never fire (previously infinite,
    ///          now bounded by `MAX_WALK_STEPS`) but still yields a non-zero tuple.
    function _invalidPriceLimit(bool zeroForOne, uint160 sqrtPriceX96, uint160 sqrtPriceLimitX96)
        private
        pure
        returns (bool)
    {
        if (zeroForOne) return sqrtPriceLimitX96 >= sqrtPriceX96 || sqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE;
        return sqrtPriceLimitX96 <= sqrtPriceX96 || sqrtPriceLimitX96 >= TickMath.MAX_SQRT_PRICE;
    }

    /// @dev Find the next initialized tick using external bitmap reads.
    function _nextInitializedTick(
        IPoolManager manager,
        PoolId poolId,
        int24 tick,
        int24 tickSpacing,
        bool lte,
        TickAdjustment[] memory tickAdjustments,
        uint256 tickAdjustmentCount
    ) private view returns (int24 next, bool initialized) {
        unchecked {
            int24 compressed;
            assembly ("memory-safe") {
                tick := signextend(2, tick)
                tickSpacing := signextend(2, tickSpacing)
                compressed := sub(sdiv(tick, tickSpacing), slt(smod(tick, tickSpacing), 0))
            }

            if (lte) {
                int16 wordPos;
                uint8 bitPos;
                assembly ("memory-safe") {
                    compressed := signextend(2, compressed)
                    wordPos := sar(8, compressed)
                    bitPos := and(compressed, 0xff)
                }
                uint256 masked = _getAdjustedTickBitmap(
                    manager, poolId, wordPos, tickSpacing, tickAdjustments, tickAdjustmentCount
                ) & (type(uint256).max >> (uint256(type(uint8).max) - bitPos));

                initialized = masked != 0;
                next = initialized
                    ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * tickSpacing
                    : (compressed - int24(uint24(bitPos))) * tickSpacing;
            } else {
                ++compressed;
                int16 wordPos;
                uint8 bitPos;
                assembly ("memory-safe") {
                    compressed := signextend(2, compressed)
                    wordPos := sar(8, compressed)
                    bitPos := and(compressed, 0xff)
                }
                uint256 masked = _getAdjustedTickBitmap(
                    manager, poolId, wordPos, tickSpacing, tickAdjustments, tickAdjustmentCount
                ) & ~((1 << bitPos) - 1);

                initialized = masked != 0;
                next = initialized
                    ? (compressed + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * tickSpacing
                    : (compressed + int24(uint24(type(uint8).max - bitPos))) * tickSpacing;
            }
        }
    }

    function _getAdjustedTickBitmap(
        IPoolManager manager,
        PoolId poolId,
        int16 wordPos,
        int24 tickSpacing,
        TickAdjustment[] memory tickAdjustments,
        uint256 tickAdjustmentCount
    ) private view returns (uint256 bitmap) {
        bitmap = manager.getTickBitmap(poolId, wordPos);
        for (uint256 i; i < tickAdjustmentCount;) {
            int24 adjustedTick = tickAdjustments[i].tick;
            int24 compressed = _compress(adjustedTick, tickSpacing);
            int16 adjustedWord;
            uint8 bitPos;
            assembly ("memory-safe") {
                compressed := signextend(2, compressed)
                adjustedWord := sar(8, compressed)
                bitPos := and(compressed, 0xff)
            }
            if (
                adjustedWord == wordPos
                    && _adjustedLiquidityGross(manager, poolId, adjustedTick, tickAdjustments, tickAdjustmentCount) == 0
            ) {
                bitmap &= ~(uint256(1) << bitPos);
            }
            unchecked {
                ++i;
            }
        }
    }

    function _getAdjustedTickLiquidity(
        IPoolManager manager,
        PoolId poolId,
        int24 tick,
        TickAdjustment[] memory tickAdjustments,
        uint256 tickAdjustmentCount
    ) private view returns (uint128 liquidityGross, int128 liquidityNet) {
        (liquidityGross, liquidityNet) = manager.getTickLiquidity(poolId, tick);
        for (uint256 i; i < tickAdjustmentCount;) {
            TickAdjustment memory adjustment = tickAdjustments[i];
            if (adjustment.tick == tick) {
                liquidityGross = adjustment.liquidityGrossRemoved >= liquidityGross
                    ? 0
                    : liquidityGross - adjustment.liquidityGrossRemoved;
                liquidityNet += adjustment.liquidityNetDelta;
            }
            unchecked {
                ++i;
            }
        }
        if (liquidityGross == 0) liquidityNet = 0;
    }

    function _adjustedLiquidityGross(
        IPoolManager manager,
        PoolId poolId,
        int24 tick,
        TickAdjustment[] memory tickAdjustments,
        uint256 tickAdjustmentCount
    ) private view returns (uint128 liquidityGross) {
        (liquidityGross,) = manager.getTickLiquidity(poolId, tick);
        for (uint256 i; i < tickAdjustmentCount;) {
            TickAdjustment memory adjustment = tickAdjustments[i];
            if (adjustment.tick == tick) {
                liquidityGross = adjustment.liquidityGrossRemoved >= liquidityGross
                    ? 0
                    : liquidityGross - adjustment.liquidityGrossRemoved;
            }
            unchecked {
                ++i;
            }
        }
    }

    function _compress(int24 tick, int24 tickSpacing) private pure returns (int24 compressed) {
        assembly ("memory-safe") {
            tick := signextend(2, tick)
            tickSpacing := signextend(2, tickSpacing)
            compressed := sub(sdiv(tick, tickSpacing), slt(smod(tick, tickSpacing), 0))
        }
    }
}
