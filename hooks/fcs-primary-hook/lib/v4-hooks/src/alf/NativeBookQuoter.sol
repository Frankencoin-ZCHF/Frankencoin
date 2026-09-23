// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapSimulator} from "./libraries/SwapSimulator.sol";
import {INativeBookQuoterSource} from "./interfaces/INativeBookQuoterSource.sol";
import {PositionInfo, isRetirable} from "./types/BookPositions.sol";

/// @title NativeBookQuoter
/// @author Uniswap Labs
/// @notice View-only ALF quote helper for NativeBookHook.
/// @dev Kept out of the hook runtime so full native v4 tick-walking quotes do not push the
///      hook over EIP-170. Quotes mirror NativeBookHook's bounded pre-swap retirement by
///      applying equivalent virtual liquidity removals before simulation; retirability is
///      decided by the same `isRetirable` predicate execution uses, so the quote-side scan
///      cannot drift from the swap-side scan.
/// @custom:security-contact security@uniswap.org
contract NativeBookQuoter {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice Maximum initialized-tick steps walked for an ALF quote before returning zero.
    uint16 public constant MAX_QUOTE_TICK_STEPS = 512;

    IPoolManager public immutable poolManager;

    /// @notice Deploy the native-book quote helper.
    /// @param _poolManager The Uniswap v4 PoolManager read by the simulator.
    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    /// @notice Return an indicative ALF quote for a native-book pool.
    /// @dev Returns output for exact-input swaps and required input for exact-output swaps.
    /// @param source Hook contract exposing native-book position state.
    /// @param key Pool key being quoted.
    /// @param zeroForOne Swap direction.
    /// @param amountSpecified Negative for exact input, positive for exact output.
    /// @return outputAmount Indicative output amount for exact input, or required input for exact output.
    function getIndicativeQuote(
        INativeBookQuoterSource source,
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified
    ) external view returns (uint256 outputAmount) {
        uint160 sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        (uint256 amountIn, uint256 amountOut) =
            _simulateSwapToPrice(source, key, zeroForOne, amountSpecified, sqrtPriceLimitX96);
        if (amountSpecified > 0 && amountOut != uint256(amountSpecified)) return 0;
        outputAmount = amountSpecified < 0 ? amountOut : amountIn;
    }

    /// @notice Simulate a swap until amount exhaustion or a target price.
    /// @param source Hook contract exposing native-book position state.
    /// @param key Pool key being quoted.
    /// @param zeroForOne Swap direction.
    /// @param amountSpecified Negative for exact input, positive for exact output.
    /// @param sqrtPriceLimitX96 Target sqrt price limit in Q64.96.
    /// @return amountIn Total input consumed, including fees.
    /// @return amountOut Total output received.
    function swapToPrice(
        INativeBookQuoterSource source,
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96
    ) external view returns (uint256 amountIn, uint256 amountOut) {
        return _simulateSwapToPrice(source, key, zeroForOne, amountSpecified, sqrtPriceLimitX96);
    }

    function _simulateSwapToPrice(
        INativeBookQuoterSource source,
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96
    ) internal view returns (uint256 amountIn, uint256 amountOut) {
        PoolId poolId = key.toId();
        if (!source.livePools(poolId)) return (0, 0);

        (
            int128 activeLiquidityDelta,
            SwapSimulator.TickAdjustment[] memory tickAdjustments,
            uint256 tickAdjustmentCount
        ) = _quoteRetirementAdjustments(source, key);

        return SwapSimulator.simulateSwapToPriceWithAdjustments(
            SwapSimulator.SimulationParams({
                manager: poolManager,
                poolId: poolId,
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                lpFeePips: key.fee,
                tickSpacing: key.tickSpacing,
                sqrtPriceLimitX96: sqrtPriceLimitX96,
                activeLiquidityDelta: activeLiquidityDelta,
                tickAdjustments: tickAdjustments,
                tickAdjustmentCount: tickAdjustmentCount,
                maxTickSteps: MAX_QUOTE_TICK_STEPS
            })
        );
    }

    /// @dev Replays the hook's bounded `_retireSome` scan virtually: walks the pool's active
    ///      position index from the stored cursor, marks retirable bins as removed (mirroring
    ///      the index's swap-remove semantics through the override list), and accumulates the
    ///      equivalent active-liquidity and tick-level adjustments for the simulator.
    function _quoteRetirementAdjustments(INativeBookQuoterSource source, PoolKey calldata key)
        internal
        view
        returns (
            int128 activeLiquidityDelta,
            SwapSimulator.TickAdjustment[] memory tickAdjustments,
            uint256 tickAdjustmentCount
        )
    {
        PoolId poolId = key.toId();
        uint8 maxRemovals = source.poolConfigs(poolId).maxRetirePerSwap;
        uint256 length = source.activePositionCount(poolId);
        tickAdjustments = new SwapSimulator.TickAdjustment[](uint256(maxRemovals) * 2);
        if (maxRemovals == 0 || length == 0) return (0, tickAdjustments, 0);

        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        uint256 checked = 0;
        uint256 removed = 0;
        uint256 cursor = source.retireCursor(poolId) % length;
        uint256[] memory overrideIndexes = new uint256[](maxRemovals);
        bytes32[] memory overrideIds = new bytes32[](maxRemovals);
        uint256 overrideCount = 0;

        while (length != 0 && checked < maxRemovals && removed < maxRemovals) {
            if (cursor >= length) cursor = 0;
            bytes32 positionId =
                _virtualActivePositionAt(source, poolId, cursor, overrideIndexes, overrideIds, overrideCount);
            unchecked {
                ++checked;
            }

            PositionInfo memory p = source.positions(positionId);
            if (isRetirable(p, poolId, currentTick)) {
                int128 liquidityDelta = int128(p.liquidity);
                if (currentTick >= p.tickLower && currentTick < p.tickUpper) {
                    activeLiquidityDelta -= liquidityDelta;
                }
                tickAdjustmentCount = _accumulateQuoteAdjustment(
                    tickAdjustments, tickAdjustmentCount, p.tickLower, -liquidityDelta, p.liquidity
                );
                tickAdjustmentCount = _accumulateQuoteAdjustment(
                    tickAdjustments, tickAdjustmentCount, p.tickUpper, liquidityDelta, p.liquidity
                );

                unchecked {
                    ++removed;
                }
                uint256 lastIndex = length - 1;
                if (cursor != lastIndex) {
                    bytes32 lastId = _virtualActivePositionAt(
                        source, poolId, lastIndex, overrideIndexes, overrideIds, overrideCount
                    );
                    overrideIndexes[overrideCount] = cursor;
                    overrideIds[overrideCount] = lastId;
                    unchecked {
                        ++overrideCount;
                    }
                }
                unchecked {
                    --length;
                }
                if (cursor >= length && length != 0) cursor = 0;
            } else {
                unchecked {
                    ++cursor;
                }
            }
        }
    }

    function _virtualActivePositionAt(
        INativeBookQuoterSource source,
        PoolId poolId,
        uint256 index,
        uint256[] memory overrideIndexes,
        bytes32[] memory overrideIds,
        uint256 overrideCount
    ) internal view returns (bytes32 positionId) {
        positionId = source.activePositionAt(poolId, index);
        for (uint256 i = overrideCount; i != 0;) {
            unchecked {
                --i;
            }
            if (overrideIndexes[i] == index) return overrideIds[i];
        }
    }

    function _accumulateQuoteAdjustment(
        SwapSimulator.TickAdjustment[] memory tickAdjustments,
        uint256 tickAdjustmentCount,
        int24 tick,
        int128 liquidityNetDelta,
        uint128 liquidityGrossRemoved
    ) internal pure returns (uint256) {
        for (uint256 i; i < tickAdjustmentCount;) {
            if (tickAdjustments[i].tick == tick) {
                tickAdjustments[i].liquidityNetDelta += liquidityNetDelta;
                tickAdjustments[i].liquidityGrossRemoved += liquidityGrossRemoved;
                return tickAdjustmentCount;
            }
            unchecked {
                ++i;
            }
        }

        tickAdjustments[tickAdjustmentCount] = SwapSimulator.TickAdjustment({
            tick: tick, liquidityNetDelta: liquidityNetDelta, liquidityGrossRemoved: liquidityGrossRemoved
        });
        return tickAdjustmentCount + 1;
    }
}
