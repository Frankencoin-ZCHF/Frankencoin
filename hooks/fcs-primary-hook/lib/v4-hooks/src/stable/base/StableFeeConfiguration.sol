// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IStableFeeConfiguration, StableFeeConfig, StableFeeState} from "../interfaces/IStableFeeConfiguration.sol";
import {IDynamicFeeHook} from "../../interfaces/IDynamicFeeHook.sol";
import {StableFeeCalculation} from "../libraries/StableFeeCalculation.sol";
import {HookRoles} from "../../base/HookRoles.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BlockNumberish} from "@uniswap/blocknumberish/src/BlockNumberish.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title StableFeeConfiguration
/// @notice Holds the per-pool stable fee config + validation
abstract contract StableFeeConfiguration is HookRoles, BlockNumberish, IStableFeeConfiguration {
    /// @notice The maximum optimal fee in 1e6 precision: 1% (1e4 out of 1e6)
    uint256 public constant MAX_OPTIMAL_FEE_E6 = 1e4;

    /// @notice The maximum target multiplier (100 = 100%, full closeBoundaryFee subtraction)
    uint256 public constant MAX_TARGET_MULTIPLIER = 100;

    /// @custom:storage-location erc7201:uniswap.storage.StableFeeConfiguration
    struct StableFeeConfigurationStorage {
        /// @dev The fee config for each pool
        mapping(PoolId => StableFeeConfig) feeConfig;
        /// @dev The fee state for each pool
        mapping(PoolId => StableFeeState) feeState;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("uniswap.storage.StableFeeConfiguration")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STABLE_FEE_CONFIGURATION_STORAGE_LOCATION =
        0x4e65cbff7fdec8e7b73e40370c540338cf2b602902c10f166d6a73c4a7ee9e00;

    /// @notice Accessor for this contract's ERC-7201 namespaced storage
    function _getStableFeeConfigurationStorage() internal pure returns (StableFeeConfigurationStorage storage $) {
        assembly ("memory-safe") {
            $.slot := STABLE_FEE_CONFIGURATION_STORAGE_LOCATION
        }
    }

    /// @inheritdoc IStableFeeConfiguration
    function updateFeeConfig(PoolId poolId_, StableFeeConfig calldata feeConfig_)
        external
        onlyRole(CONFIG_MANAGER_ROLE)
    {
        _checkPoolInitialized(poolId_);
        _updateFeeConfig(poolId_, feeConfig_);
        emit FeeConfigUpdated(poolId_, feeConfig_);
    }

    /// @inheritdoc IStableFeeConfiguration
    function batchUpdateFeeConfig(PoolId[] calldata poolIds_, StableFeeConfig[] calldata feeConfigs_)
        external
        onlyRole(CONFIG_MANAGER_ROLE)
    {
        if (poolIds_.length != feeConfigs_.length) revert LengthMismatch();
        for (uint256 i = 0; i < poolIds_.length; i++) {
            _checkPoolInitialized(poolIds_[i]);
            _updateFeeConfig(poolIds_[i], feeConfigs_[i]);
            emit FeeConfigUpdated(poolIds_[i], feeConfigs_[i]);
        }
    }

    /// @notice The fee config for a pool
    /// @param poolId The PoolId of the pool
    function feeConfig(PoolId poolId)
        public
        view
        returns (uint24 k, uint24 optimalFeeE6, uint8 targetMultiplier, uint160 referenceSqrtPriceX96)
    {
        StableFeeConfig storage config = _getStableFeeConfigurationStorage().feeConfig[poolId];
        return (config.k, config.optimalFeeE6, config.targetMultiplier, config.referenceSqrtPriceX96);
    }

    /// @notice The fee state for a pool
    /// @param poolId The PoolId of the pool
    function feeState(PoolId poolId)
        public
        view
        returns (uint40 decayingFeeE12, uint160 sqrtAmmPriceX96, uint40 blockNumber)
    {
        StableFeeState storage state = _getStableFeeConfigurationStorage().feeState[poolId];
        return (state.decayingFeeE12, state.sqrtAmmPriceX96, state.blockNumber);
    }

    /// @notice Internal helper to validate, reset state, and store fee config
    /// @param _poolId The pool ID to initialize
    /// @param _feeConfig The fee config to validate and store
    function _updateFeeConfig(PoolId _poolId, StableFeeConfig calldata _feeConfig) internal {
        _validateK(_feeConfig.k);
        _validateOptimalFeeE6(_feeConfig.optimalFeeE6);
        _validateTargetMultiplier(_feeConfig.targetMultiplier);
        _validateReferenceSqrtPriceX96(_feeConfig.referenceSqrtPriceX96);
        _resetFeeState(_poolId);
        _getStableFeeConfigurationStorage().feeConfig[_poolId] = _feeConfig;
    }

    /// @notice Internal helper to reset fee state
    /// @param _poolId The pool ID to reset fee state for
    function _resetFeeState(PoolId _poolId) internal {
        StableFeeState storage state = _getStableFeeConfigurationStorage().feeState[_poolId];
        state.decayingFeeE12 = uint40(StableFeeCalculation.UNDEFINED_DECAYING_FEE_E12);
        state.blockNumber = uint40(_getBlockNumberish());
        state.sqrtAmmPriceX96 = 0; // Force the next swap to read a fresh price from the pool, not the cached start-of-block price
    }

    /// @notice Reverts unless the pool already has a stored config
    /// @dev Config is only ever seeded by the hook's pool-initialization entrypoint, which enforces
    ///      the hook address and dynamic fee and initializes the pool on the PoolManager in the same
    ///      call. A nonzero reference price (validated nonzero on every write) therefore proves the
    ///      pool exists, uses this hook, and has a dynamic fee.
    /// @param _poolId The pool ID to check
    function _checkPoolInitialized(PoolId _poolId) internal view {
        if (_getStableFeeConfigurationStorage().feeConfig[_poolId].referenceSqrtPriceX96 == 0) {
            revert IDynamicFeeHook.PoolNotInitialized(_poolId);
        }
    }

    /// @notice Validate k (zero would mean instant decay)
    /// @param _k The k value to validate
    function _validateK(uint256 _k) internal pure {
        if (_k == 0) {
            revert InvalidK(_k);
        }
    }

    /// @notice Validate the optimal fee
    /// @param _optimalFeeE6 The optimal fee to validate
    function _validateOptimalFeeE6(uint256 _optimalFeeE6) internal pure {
        if (_optimalFeeE6 > MAX_OPTIMAL_FEE_E6) {
            revert InvalidOptimalFeeE6(_optimalFeeE6);
        }
    }

    /// @notice Validate the target multiplier (0-100, representing 0%-100%)
    /// @param _targetMultiplier The target multiplier to validate
    function _validateTargetMultiplier(uint256 _targetMultiplier) internal pure {
        if (_targetMultiplier > MAX_TARGET_MULTIPLIER) revert InvalidTargetMultiplier(_targetMultiplier);
    }

    /// @notice Validate the reference sqrt price
    /// @dev The optimal range is defined in terms of PRICE (not sqrt price):
    ///      [referencePrice * (1 - maxOptimalFee), referencePrice / (1 - maxOptimalFee)]
    ///      Since price = sqrtPrice², the sqrt price bounds are:
    ///      [referenceSqrtPrice * sqrt(1 - maxOptimalFee), referenceSqrtPrice / sqrt(1 - maxOptimalFee)]
    ///      Note: MIN_SQRT_PRICE is valid (inclusive) but MAX_SQRT_PRICE is invalid (exclusive) in v4.
    /// @param _referenceSqrtPriceX96 The reference sqrt price to validate
    function _validateReferenceSqrtPriceX96(uint256 _referenceSqrtPriceX96) internal pure {
        // Calculate bounds that ensure optimal range stays within v4 sqrt price limits
        // The optimal range boundaries in sqrt price terms use sqrt(1 - fee), not (1 - fee)
        // minBound: referenceSqrtPrice * sqrt(1 - maxOptimalFee) >= MIN_SQRT_PRICE
        //           => referenceSqrtPrice >= MIN_SQRT_PRICE / sqrt(1 - maxOptimalFee)
        // maxBound: referenceSqrtPrice / sqrt(1 - maxOptimalFee) < MAX_SQRT_PRICE  (strictly less than!)
        //           => referenceSqrtPrice < MAX_SQRT_PRICE * sqrt(1 - maxOptimalFee)
        uint256 oneMinusMaxFee = StableFeeCalculation.ONE_E6 - MAX_OPTIMAL_FEE_E6;
        uint256 sqrtOneMinusMaxFeeE6 = FixedPointMathLib.sqrt(oneMinusMaxFee * StableFeeCalculation.ONE_E6);
        uint256 minBoundedReferenceSqrtPrice =
            (uint256(TickMath.MIN_SQRT_PRICE) * StableFeeCalculation.ONE_E6 + sqrtOneMinusMaxFeeE6 - 1)
                / sqrtOneMinusMaxFeeE6;
        uint256 maxBoundedReferenceSqrtPrice =
            uint256(TickMath.MAX_SQRT_PRICE) * sqrtOneMinusMaxFeeE6 / StableFeeCalculation.ONE_E6;

        if (
            _referenceSqrtPriceX96 < minBoundedReferenceSqrtPrice
                || _referenceSqrtPriceX96 >= maxBoundedReferenceSqrtPrice
        ) {
            revert InvalidReferenceSqrtPriceX96(_referenceSqrtPriceX96);
        }
    }
}
