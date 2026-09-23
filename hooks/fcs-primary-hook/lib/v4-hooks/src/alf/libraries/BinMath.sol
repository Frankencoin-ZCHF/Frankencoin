// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Side} from "../types/BookPositions.sol";

/// @title BinMath
/// @author Uniswap Labs
/// @notice Pure geometry for NativeBook canonical bins: the reference-tick grid, offset-to-range
///         projection, single-sided liquidity sizing, and the maker's reference-tick slippage
///         bound.
/// @custom:security-contact security@uniswap.org
library BinMath {
    /// @dev The pool's reference tick drifted further from the maker's expectation than the
    ///      order's `maxTickDeviation` allows. The ladder was priced against a grid position that
    ///      no longer holds.
    /// @param expectedRefTick The reference tick the maker priced against.
    /// @param actualRefTick   The reference tick at execution.
    /// @param maxTickDeviation The maker's allowed drift.
    error RefTickSlippage(int24 expectedRefTick, int24 actualRefTick, uint24 maxTickDeviation);

    /// @notice The canonical grid tick at or below `currentTick`.
    /// @dev Floor division by `binSpacing` (rounding toward negative infinity), scaled back to
    ///      ticks. All bin ranges are projected from this anchor.
    /// @param currentTick The pool's current tick.
    /// @param binSpacing  The pool's bin width in ticks.
    /// @return refTick The reference tick.
    function referenceTick(int24 currentTick, int24 binSpacing) internal pure returns (int24 refTick) {
        int24 compressed = currentTick / binSpacing;
        if (currentTick < 0 && currentTick % binSpacing != 0) compressed--;
        refTick = compressed * binSpacing;
    }

    /// @notice Project a canonical offset onto its tick range.
    /// @param refTick         The pool's reference tick.
    /// @param offset          The canonical bin offset (negative bids, positive asks).
    /// @param binSpacingTicks The pool's bin width in ticks.
    /// @return tickLower The bin's lower tick.
    /// @return tickUpper The bin's upper tick.
    function binRange(int24 refTick, int8 offset, int24 binSpacingTicks)
        internal
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        tickLower = refTick + int24(offset) * binSpacingTicks;
        tickUpper = tickLower + binSpacingTicks;
    }

    /// @notice Size the v4 liquidity for a single-sided bin capacity.
    /// @dev Bids are quoted in currency1 (`getLiquidityForAmount1`), asks in currency0
    ///      (`getLiquidityForAmount0`), matching which token the range holds while unfilled.
    /// @param side      Bid or ask.
    /// @param tickLower The bin's lower tick.
    /// @param tickUpper The bin's upper tick.
    /// @param amount    The maker capacity to deploy.
    /// @return liquidity The v4 liquidity the capacity converts to.
    function binLiquidity(Side side, int24 tickLower, int24 tickUpper, uint128 amount)
        internal
        pure
        returns (uint128 liquidity)
    {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        liquidity = side == Side.Bid
            ? LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, amount)
            : LiquidityAmounts.getLiquidityForAmount0(sqrtLower, sqrtUpper, amount);
    }

    /// @notice Enforce the maker's reference-tick slippage bound.
    /// @dev Reverts {RefTickSlippage} when `|actualRefTick - expectedRefTick| > maxTickDeviation`.
    /// @param actualRefTick    The reference tick at execution.
    /// @param expectedRefTick  The reference tick the maker priced against.
    /// @param maxTickDeviation The maker's allowed drift.
    function requireRefTickWithin(int24 actualRefTick, int24 expectedRefTick, uint24 maxTickDeviation) internal pure {
        int256 delta = int256(actualRefTick) - int256(expectedRefTick);
        uint256 deviation = delta >= 0 ? uint256(delta) : uint256(-delta);
        if (deviation > maxTickDeviation) {
            revert RefTickSlippage(expectedRefTick, actualRefTick, maxTickDeviation);
        }
    }
}
