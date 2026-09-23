// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IStablePairHook} from "./interfaces/IStablePairHook.sol";
import {IDynamicFeeHook} from "../interfaces/IDynamicFeeHook.sol";
import {StableFeeConfiguration} from "./base/StableFeeConfiguration.sol";
import {BaseDynamicFeeHook} from "../base/BaseDynamicFeeHook.sol";
import {StableFeeCalculation} from "./libraries/StableFeeCalculation.sol";
import {StableFeeConfig, StableFeeState} from "./interfaces/IStableFeeConfiguration.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// @title StablePairHook
/// @notice Dynamic fee hook for pools of two assets expected to hold the same price; a UUPS implementation whose ERC1967 proxy
///         is the registered v4 hook.
/// @dev The fee calculations adjust the LP fee to hit the target pre-impact buy/sell prices and do
///      not take the pool's protocolFee into account if it's turned on.
/// @custom:security-contact security@uniswap.org
contract StablePairHook is BaseDynamicFeeHook, StableFeeConfiguration, IStablePairHook {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @param _manager The Uniswap v4 PoolManager
    constructor(IPoolManager _manager) BaseDynamicFeeHook(_manager) {}

    /// @inheritdoc IStablePairHook
    function initializePool(PoolKey calldata poolKey, uint160 sqrtPriceX96, StableFeeConfig calldata feeConfig)
        external
        onlyRole(POOL_INITIALIZER_ROLE)
        returns (int24 tick)
    {
        if (!poolKey.fee.isDynamicFee()) {
            revert MustUseDynamicFee(poolKey.fee);
        }
        if (poolKey.hooks != IHooks(address(this))) {
            revert InvalidHookAddress(address(poolKey.hooks));
        }
        _updateFeeConfig(poolKey.toId(), feeConfig);
        tick = poolManager.initialize(poolKey, sqrtPriceX96);
        emit PoolInitialized(poolKey, sqrtPriceX96, feeConfig);
    }

    /// @inheritdoc IDynamicFeeHook
    /// @dev StablePair's fee is size-independent (it never reads the swap amount), so this always
    ///      returns and never reverts on the size-dependence basis. It reverts only for an uninitialized pool, whose fee is undefined.
    function getFee(PoolKey calldata key) external view returns (uint24 feeE6ZeroForOne, uint24 feeE6OneForZero) {
        PoolId poolId = key.toId();
        _checkPoolInitialized(poolId);

        (uint256 sqrtAmmPriceX96, bool isNewBlock) = _loadPrice(poolId);

        // Compute each direction from the same start-of-block state the next swap would see
        (uint256 feeE12ZeroForOne,) = _getFee(poolId, sqrtAmmPriceX96, isNewBlock, true);
        (uint256 feeE12OneForZero,) = _getFee(poolId, sqrtAmmPriceX96, isNewBlock, false);

        // Uniswap v4 handles fees in E6 not E12
        feeE6ZeroForOne = StableFeeCalculation.toFeeE6(feeE12ZeroForOne);
        feeE6OneForZero = StableFeeCalculation.toFeeE6(feeE12OneForZero);
    }

    /// @notice Calculate and apply dynamic fee before each swap
    /// @param key The PoolKey of the pool
    /// @param params The SwapParams of the swap
    /// @return selector The function selector for IHooks.beforeSwap
    /// @return delta BeforeSwapDelta (always zero for this hook)
    /// @return lpFeeOverride The calculated dynamic fee with override flag
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();

        (uint256 sqrtAmmPriceX96, bool isNewBlock) = _loadPrice(poolId);

        (uint256 lpFeeE12, uint256 decayingFeeE12) = _getFee(poolId, sqrtAmmPriceX96, isNewBlock, params.zeroForOne);

        // Only update feeState on the first swap of a new block
        if (isNewBlock) {
            StableFeeState storage poolFeeState = _getStableFeeConfigurationStorage().feeState[poolId];
            poolFeeState.decayingFeeE12 = uint40(decayingFeeE12);
            poolFeeState.sqrtAmmPriceX96 = uint160(sqrtAmmPriceX96);
            poolFeeState.blockNumber = uint40(_getBlockNumberish());
        }

        // Uniswap v4 handles fees in E6 not E12
        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            StableFeeCalculation.toFeeE6(lpFeeE12) | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    /// @notice Select the AMM price used for fee calculation and whether this is a new block.
    /// @param poolId The PoolId of the pool
    /// @return sqrtAmmPriceX96 The (potentially cached) AMM sqrt price to compute the fee from
    /// @return isNewBlock True if this is the first swap of a new block (or after init/reset)
    function _loadPrice(PoolId poolId) private view returns (uint256 sqrtAmmPriceX96, bool isNewBlock) {
        StableFeeState storage poolFeeState = _getStableFeeConfigurationStorage().feeState[poolId];
        // Use start of block price for fee calculation to prevent swap splitting advantage, or read fresh price if first swap after pool init/reset.
        // Tradeoff: cached price becomes stale within a block, but impact is minimal for stable pools.
        // Accepted: with zero active liquidity the price moves for free, so the cache can sit on the opposite side of
        // the reference and a same-block corrective swap is charged 0. Needs a same-block mint, and self-heals next block.
        isNewBlock = (_getBlockNumberish() > poolFeeState.blockNumber) || poolFeeState.sqrtAmmPriceX96 == 0;
        if (isNewBlock) {
            (sqrtAmmPriceX96,,,) = poolManager.getSlot0(poolId); // grab the current sqrt price of the pool
        } else {
            sqrtAmmPriceX96 = poolFeeState.sqrtAmmPriceX96;
        }
    }

    /// @notice Calculate the LP fee for one swap direction, plus the decaying fee to persist.
    /// @param poolId The PoolId of the pool
    /// @param sqrtAmmPriceX96 The AMM sqrt price to compute the fee from (from _loadPrice)
    /// @param isNewBlock Whether this is the first swap of a new block (from _loadPrice)
    /// @param zeroForOne The swap direction
    /// @return lpFeeE12 The lp fee for this swap in 1e12 precision
    /// @return decayingFeeE12 The decaying fee to persist for this block (UNDEFINED inside optimal range)
    function _getFee(PoolId poolId, uint256 sqrtAmmPriceX96, bool isNewBlock, bool zeroForOne)
        private
        view
        returns (uint256 lpFeeE12, uint256 decayingFeeE12)
    {
        StableFeeConfig storage poolFeeConfig = _getStableFeeConfigurationStorage().feeConfig[poolId];
        uint256 sqrtReferencePriceX96 = poolFeeConfig.referenceSqrtPriceX96;
        uint256 optimalFeeE6 = poolFeeConfig.optimalFeeE6;

        // Calculate the price ratio using the (potentially cached) price
        uint256 priceRatioX96 = StableFeeCalculation.calculatePriceRatioX96(sqrtAmmPriceX96, sqrtReferencePriceX96);

        // The optimalFee defines a price range (the "optimal spread") in PRICE space (not sqrt price space).
        // Let RP = the actual reference price (i.e., sqrtReferencePriceX96² expressed as a price).
        // The optimal range bounds are:
        //   - Lower bound (price): RP * (1 - optimalFee)
        //   - Upper bound (price): RP / (1 - optimalFee)

        // closeBoundaryFeeE12 represents the fee to reach whichever boundary is closer to the current AMM price.
        //   - If closeBoundaryFeeE12 <= 0: AMM price is inside the optimal range (past the close boundary)
        //   - If closeBoundaryFeeE12 > 0: AMM price is outside the optimal range (hasn't reached the close boundary)
        int256 closeBoundaryFeeE12 = StableFeeCalculation.calculateCloseBoundaryFee(priceRatioX96, optimalFeeE6);

        // Uses the (cached) price, so a within-block crossing of the reference inverts the fee
        // direction until the next block refreshes it
        bool ammPriceBelowRP = sqrtAmmPriceX96 < sqrtReferencePriceX96;

        // closeBoundaryFee is the fee that would place the pre-impact price at the close boundary.
        // A negative value means the AMM price is already inside the optimal range (past the close boundary).
        if (closeBoundaryFeeE12 <= 0) {
            // Inside optimal range: The fee is set such that all swappers have consistent pre-impact prices:
            //   - Sells: ammPrice * (1 - fee) = RP * (1 - optimalFee) (lower bound)
            //   - Buys: ammPrice / (1 - fee) = RP / (1 - optimalFee) (upper bound)
            lpFeeE12 = StableFeeCalculation.calculateInsideOptimalRangeFee(
                priceRatioX96, optimalFeeE6, ammPriceBelowRP, zeroForOne
            );
            decayingFeeE12 = StableFeeCalculation.UNDEFINED_DECAYING_FEE_E12; // No decaying fee inside optimal range
        } else {
            // Outside optimal range: The fee is calculated such that the fee decays exponentially toward a target fee
            StableFeeState storage poolFeeState = _getStableFeeConfigurationStorage().feeState[poolId];
            if (isNewBlock) {
                // farBoundaryFeeE12 represents the fee to reach whichever boundary is farther from the current AMM price.
                uint256 farBoundaryFeeE12 = StableFeeCalculation.calculateFarBoundaryFee(priceRatioX96, optimalFeeE6);

                // closeBoundaryFeeE12 is positive since we are outside the optimal range
                decayingFeeE12 = _calculateDecayingFee(
                    poolFeeConfig,
                    poolFeeState,
                    sqrtAmmPriceX96,
                    sqrtReferencePriceX96,
                    uint256(closeBoundaryFeeE12),
                    farBoundaryFeeE12,
                    ammPriceBelowRP
                );
            } else {
                // Same block: reuse the decaying fee calculated on the first swap
                decayingFeeE12 = poolFeeState.decayingFeeE12;
            }

            // Select which fee to charge based on swap direction
            // Price is moving further from reference: charge 0 fee. Otherwise, charge the decaying fee.
            lpFeeE12 = (ammPriceBelowRP == zeroForOne) ? 0 : decayingFeeE12;
        }
    }

    /// @notice Calculate decaying fee when price is outside optimal range
    /// @param poolFeeConfig The StableFeeConfig of the pool
    /// @param poolFeeState The StableFeeState of the pool
    /// @param sqrtAmmPriceX96 The current AMM sqrt price
    /// @param sqrtReferencePriceX96 The reference sqrt price
    /// @param closeBoundaryFeeE12 The fee to reach the close boundary of the optimal range (negative = already inside)
    /// @param farBoundaryFeeE12 The fee to reach the far boundary of the optimal range
    /// @param ammPriceBelowRP True if current AMM price < reference price
    /// @return decayingFeeE12 The calculated decaying fee in 1e12 precision
    function _calculateDecayingFee(
        StableFeeConfig storage poolFeeConfig,
        StableFeeState storage poolFeeState,
        uint256 sqrtAmmPriceX96,
        uint256 sqrtReferencePriceX96,
        uint256 closeBoundaryFeeE12,
        uint256 farBoundaryFeeE12,
        bool ammPriceBelowRP
    ) private view returns (uint256 decayingFeeE12) {
        // Load the state stored about the previous swap on this pool
        uint256 previousSqrtAmmPriceX96 = poolFeeState.sqrtAmmPriceX96;
        uint256 previousDecayingFeeE12 = poolFeeState.decayingFeeE12;

        // Determine the starting fee for exponential decay based on how the price moved since the last swap
        uint256 decayStartFeeE12;
        if (
            previousDecayingFeeE12 == StableFeeCalculation.UNDEFINED_DECAYING_FEE_E12
                || (previousSqrtAmmPriceX96 < sqrtReferencePriceX96) != ammPriceBelowRP
        ) {
            // Price just left optimal range or jumped across reference: start from far boundary
            decayStartFeeE12 = farBoundaryFeeE12;
        } else if (ammPriceBelowRP == (sqrtAmmPriceX96 < previousSqrtAmmPriceX96)) {
            // Price moved further from reference (left of ref and moved more left, OR right of ref and moved more right)
            // Adjust fee upward to preserve the same pre-impact price, then decay starts from this adjusted fee
            uint256 priceMovementRatioX96 =
                StableFeeCalculation.calculatePriceRatioX96(sqrtAmmPriceX96, previousSqrtAmmPriceX96);
            decayStartFeeE12 =
                StableFeeCalculation.adjustPreviousFeeForPriceMovement(priceMovementRatioX96, previousDecayingFeeE12);
        } else if (previousDecayingFeeE12 > farBoundaryFeeE12) {
            // Price moved toward reference, lowering farBoundaryFee below previousFee: cap at the new far boundary
            decayStartFeeE12 = farBoundaryFeeE12;
        } else {
            // Price moved toward reference but previousFee is still within bounds — no adjustment needed
            decayStartFeeE12 = previousDecayingFeeE12;
        }

        // Calculate target fee. targetMultiplier (0-100) controls how aggressively the target fee
        // drops below farBoundaryFee as price moves further from optimal range.
        // 100 = full subtraction (tightest spread), 50 = half, 0 = no reduction.
        uint256 targetFeeE12 =
            farBoundaryFeeE12 - closeBoundaryFeeE12 * poolFeeConfig.targetMultiplier / MAX_TARGET_MULTIPLIER;

        // When targetMultiplier/100 > (1 - optimalFee)^2, the target fee rises as price moves back toward
        // reference. A previousDecayingFee that decayed toward an earlier (lower) target can then sit below
        // the new target, so clamp the decay start up to target to avoid underflow in calculateDecayingFee.
        if (decayStartFeeE12 < targetFeeE12) {
            decayStartFeeE12 = targetFeeE12;
        }

        // Apply exponential decay toward target. Elapsed blocks is 0 both for the first swap in the
        // same block as an init/reset (equal block numbers — no decay yet) and, defensively, when a
        // non-monotonic block-number source reads below the stored block, so the subtraction never underflows.
        decayingFeeE12 = StableFeeCalculation.calculateDecayingFee(
            targetFeeE12,
            decayStartFeeE12,
            poolFeeConfig.k,
            _getBlockNumberish() > poolFeeState.blockNumber ? _getBlockNumberish() - poolFeeState.blockNumber : 0
        );
    }
}
