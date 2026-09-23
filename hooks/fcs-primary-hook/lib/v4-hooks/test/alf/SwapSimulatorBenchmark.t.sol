// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {LiquidityMath} from "@uniswap/v4-core/src/libraries/LiquidityMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {SwapSimulator} from "../../src/alf/libraries/SwapSimulator.sol";

contract SwapSimulatorBenchmarkTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    int24 internal constant TICK_SPACING = 60;
    uint24 internal constant POOL_FEE = 3000;
    uint24 internal constant QUOTE_FEE_PIPS = 90;

    PoolKey internal poolKey;
    PoolId internal poolId;
    SwapSimulatorBenchHarness internal harness;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        poolId = poolKey.toId();

        manager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        // Seed multiple adjacent ranges to force bitmap walking/crossing on large quotes.
        _seedLP(-1200, -600, 250_000e18, 250_000e18);
        _seedLP(-600, 0, 250_000e18, 250_000e18);
        _seedLP(0, 600, 250_000e18, 250_000e18);
        _seedLP(600, 1200, 250_000e18, 250_000e18);

        harness = new SwapSimulatorBenchHarness();
    }

    function _seedLP(int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1) internal {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int128(liq), salt: 0}),
            ""
        );
    }

    function test_gas_swapSimulator_before_singleTick() public {
        uint256 out = harness.quoteBefore(manager, poolId, true, -1e18, QUOTE_FEE_PIPS, TICK_SPACING);
        assertGt(out, 0);
        vm.snapshotGasLastCall("swapSimulator_before_singleTick");
    }

    function test_gas_swapSimulator_after_singleTick() public {
        uint256 out = harness.quoteAfter(manager, poolId, true, -1e18, QUOTE_FEE_PIPS, TICK_SPACING);
        assertGt(out, 0);
        vm.snapshotGasLastCall("swapSimulator_after_singleTick");
    }

    function test_gas_swapSimulator_before_multiTick() public {
        uint256 out = harness.quoteBefore(manager, poolId, true, -120_000e18, QUOTE_FEE_PIPS, TICK_SPACING);
        assertGt(out, 0);
        vm.snapshotGasLastCall("swapSimulator_before_multiTick");
    }

    function test_gas_swapSimulator_after_multiTick() public {
        uint256 out = harness.quoteAfter(manager, poolId, true, -120_000e18, QUOTE_FEE_PIPS, TICK_SPACING);
        assertGt(out, 0);
        vm.snapshotGasLastCall("swapSimulator_after_multiTick");
    }
}

contract SwapSimulatorBenchHarness {
    function quoteBefore(
        IPoolManager manager,
        PoolId poolId,
        bool zeroForOne,
        int256 amountSpecified,
        uint24 feePips,
        int24 tickSpacing
    ) external view returns (uint256) {
        return SwapSimulatorBefore.simulateSwap(manager, poolId, zeroForOne, amountSpecified, feePips, tickSpacing);
    }

    function quoteAfter(
        IPoolManager manager,
        PoolId poolId,
        bool zeroForOne,
        int256 amountSpecified,
        uint24 feePips,
        int24 tickSpacing
    ) external view returns (uint256) {
        return SwapSimulator.simulateSwap(manager, poolId, zeroForOne, amountSpecified, feePips, tickSpacing);
    }
}

library SwapSimulatorBefore {
    using StateLibrary for IPoolManager;

    struct SwapState {
        uint160 sqrtPriceX96;
        int24 tick;
        uint128 liquidity;
        int256 amountRemaining;
        int256 amountCalc;
    }

    function simulateSwap(
        IPoolManager manager,
        PoolId poolId,
        bool zeroForOne,
        int256 amountSpecified,
        uint24 feePips,
        int24 tickSpacing
    ) internal view returns (uint256 result) {
        SwapState memory s;
        {
            int24 tick;
            (s.sqrtPriceX96, tick,,) = manager.getSlot0(poolId);
            s.tick = tick;
        }
        s.liquidity = manager.getLiquidity(poolId);

        if (s.sqrtPriceX96 == 0 || amountSpecified == 0) return 0;

        uint160 sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        s.amountRemaining = amountSpecified;

        while (s.amountRemaining != 0 && s.sqrtPriceX96 != sqrtPriceLimitX96) {
            (int24 tickNext, bool initialized) = _nextInitializedTick(manager, poolId, s.tick, tickSpacing, zeroForOne);

            if (tickNext <= TickMath.MIN_TICK) tickNext = TickMath.MIN_TICK;
            if (tickNext >= TickMath.MAX_TICK) tickNext = TickMath.MAX_TICK;

            uint160 sqrtPriceNextX96 = TickMath.getSqrtPriceAtTick(tickNext);

            {
                uint160 sqrtPriceStartX96 = _stepAndAccumulate(
                    s,
                    SwapMath.getSqrtPriceTarget(zeroForOne, sqrtPriceNextX96, sqrtPriceLimitX96),
                    feePips,
                    amountSpecified < 0
                );

                if (s.sqrtPriceX96 != sqrtPriceNextX96 && s.sqrtPriceX96 != sqrtPriceStartX96) {
                    s.tick = TickMath.getTickAtSqrtPrice(s.sqrtPriceX96);
                }
            }

            if (s.sqrtPriceX96 == sqrtPriceNextX96) {
                if (initialized) {
                    (, int128 liquidityNet) = manager.getTickLiquidity(poolId, tickNext);
                    unchecked {
                        if (zeroForOne) liquidityNet = -liquidityNet;
                    }
                    s.liquidity = LiquidityMath.addDelta(s.liquidity, liquidityNet);
                }
                unchecked {
                    s.tick = zeroForOne ? tickNext - 1 : tickNext;
                }
            }
        }

        if (amountSpecified < 0) {
            result = uint256(s.amountCalc);
        } else {
            result = uint256(-s.amountCalc);
        }
    }

    function _stepAndAccumulate(SwapState memory s, uint160 sqrtPriceTargetX96, uint24 feePips, bool exactInput)
        private
        pure
        returns (uint160 sqrtPriceStartX96)
    {
        sqrtPriceStartX96 = s.sqrtPriceX96;

        (uint160 sqrtPriceAfter, uint256 amountIn, uint256 amountOut, uint256 feeAmount) =
            SwapMath.computeSwapStep(sqrtPriceStartX96, sqrtPriceTargetX96, s.liquidity, s.amountRemaining, feePips);

        s.sqrtPriceX96 = sqrtPriceAfter;

        assembly ("memory-safe") {
            let rem := mload(add(s, 0x60))
            let calc := mload(add(s, 0x80))
            let inputPlusFee := add(amountIn, feeAmount)
            switch exactInput
            case 1 {
                mstore(add(s, 0x60), add(rem, inputPlusFee))
                mstore(add(s, 0x80), add(calc, amountOut))
            }
            default {
                mstore(add(s, 0x60), sub(rem, amountOut))
                mstore(add(s, 0x80), sub(calc, inputPlusFee))
            }
        }
    }

    function _nextInitializedTick(IPoolManager manager, PoolId poolId, int24 tick, int24 tickSpacing, bool lte)
        private
        view
        returns (int24 next, bool initialized)
    {
        unchecked {
            int24 compressed = TickBitmap.compress(tick, tickSpacing);

            if (lte) {
                (int16 wordPos, uint8 bitPos) = TickBitmap.position(compressed);
                uint256 masked =
                    manager.getTickBitmap(poolId, wordPos) & (type(uint256).max >> (uint256(type(uint8).max) - bitPos));

                initialized = masked != 0;
                next = initialized
                    ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * tickSpacing
                    : (compressed - int24(uint24(bitPos))) * tickSpacing;
            } else {
                ++compressed;
                (int16 wordPos, uint8 bitPos) = TickBitmap.position(compressed);
                uint256 masked = manager.getTickBitmap(poolId, wordPos) & ~((1 << bitPos) - 1);

                initialized = masked != 0;
                next = initialized
                    ? (compressed + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * tickSpacing
                    : (compressed + int24(uint24(type(uint8).max - bitPos))) * tickSpacing;
            }
        }
    }
}
