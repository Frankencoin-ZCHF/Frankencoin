// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {BinMath} from "../../src/alf/libraries/BinMath.sol";
import {Side} from "../../src/alf/types/BookPositions.sol";

/// @notice Isolated coverage for the `BinMath` library: reference-tick grid flooring, offset
///         range projection, single-sided liquidity sizing, and the reference-tick slippage
///         bound.
contract BinMathTest is Test {
    int24 internal constant BIN_SPACING = 60;

    function extRequireWithin(int24 actualRefTick, int24 expectedRefTick, uint24 maxTickDeviation) external pure {
        BinMath.requireRefTickWithin(actualRefTick, expectedRefTick, maxTickDeviation);
    }

    // ══════════════════════════════════════════════════════════
    //  referenceTick
    // ══════════════════════════════════════════════════════════

    function test_referenceTick_positive() public pure {
        assertEq(BinMath.referenceTick(0, BIN_SPACING), 0);
        assertEq(BinMath.referenceTick(59, BIN_SPACING), 0);
        assertEq(BinMath.referenceTick(60, BIN_SPACING), 60);
        assertEq(BinMath.referenceTick(150, BIN_SPACING), 120);
    }

    function test_referenceTick_negativeFloorsTowardNegativeInfinity() public pure {
        assertEq(BinMath.referenceTick(-1, BIN_SPACING), -60);
        assertEq(BinMath.referenceTick(-60, BIN_SPACING), -60);
        assertEq(BinMath.referenceTick(-61, BIN_SPACING), -120);
        assertEq(BinMath.referenceTick(-150, BIN_SPACING), -180);
    }

    function testFuzz_referenceTick_isAlignedFloorWithinSpacing(int24 currentTick) public pure {
        currentTick = int24(bound(currentTick, TickMath.MIN_TICK, TickMath.MAX_TICK));
        int24 refTick = BinMath.referenceTick(currentTick, BIN_SPACING);
        assertEq(refTick % BIN_SPACING, 0, "grid aligned");
        assertLe(refTick, currentTick, "at or below current");
        assertGt(refTick + BIN_SPACING, currentTick, "within one bin");
    }

    // ══════════════════════════════════════════════════════════
    //  binRange
    // ══════════════════════════════════════════════════════════

    function test_binRange_projectsOffsets() public pure {
        (int24 lower, int24 upper) = BinMath.binRange(120, -1, BIN_SPACING);
        assertEq(lower, 60);
        assertEq(upper, 120);

        (lower, upper) = BinMath.binRange(120, 1, BIN_SPACING);
        assertEq(lower, 180);
        assertEq(upper, 240);

        (lower, upper) = BinMath.binRange(-120, -2, BIN_SPACING);
        assertEq(lower, -240);
        assertEq(upper, -180);
    }

    // ══════════════════════════════════════════════════════════
    //  binLiquidity
    // ══════════════════════════════════════════════════════════

    function test_binLiquidity_selectsSideAmount() public pure {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(60);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(120);

        assertEq(
            BinMath.binLiquidity(Side.Bid, 60, 120, 1e18),
            LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, 1e18)
        );
        assertEq(
            BinMath.binLiquidity(Side.Ask, 60, 120, 1e18),
            LiquidityAmounts.getLiquidityForAmount0(sqrtLower, sqrtUpper, 1e18)
        );
    }

    // ══════════════════════════════════════════════════════════
    //  requireRefTickWithin
    // ══════════════════════════════════════════════════════════

    function test_requireRefTickWithin_boundaryPasses() public view {
        this.extRequireWithin(120, 60, 60);
        this.extRequireWithin(60, 120, 60);
        this.extRequireWithin(60, 60, 0);
    }

    function test_requireRefTickWithin_beyondBound_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(BinMath.RefTickSlippage.selector, int24(60), int24(121), uint24(60)));
        this.extRequireWithin(121, 60, 60);

        vm.expectRevert(abi.encodeWithSelector(BinMath.RefTickSlippage.selector, int24(121), int24(60), uint24(60)));
        this.extRequireWithin(60, 121, 60);
    }
}
