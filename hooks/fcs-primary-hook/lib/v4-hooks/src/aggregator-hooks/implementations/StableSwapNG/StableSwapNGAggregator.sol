// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {BaseAggregatorHook} from "../../BaseAggregatorHook.sol";
import {ICurveStableSwapNG} from "./interfaces/ICurveStableSwapNG.sol";
import {ICurveStableSwapFactoryNG} from "./interfaces/ICurveStableSwapFactoryNG.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title StableSwapNGAggregator
/// @notice Uniswap V4 hook that aggregates liquidity from Curve StableSwap NG pools
/// @dev Supports both exact-input and exact-output swaps
contract StableSwapNGAggregator is BaseAggregatorHook {
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    /// @notice The Curve StableSwap NG pool
    ICurveStableSwapNG public immutable pool;

    /// @notice The Curve StableSwap NG factory for checking meta pool status
    ICurveStableSwapFactoryNG public immutable curveFactory;

    uint256 internal constant INACCURACY_BUFFER = 20;
    uint256 internal constant INACCURACY_SCALE = 1_000_000;

    struct PoolInfo {
        int128 token0Index;
        int128 token1Index;
    }

    /// @notice Maps Uniswap V4 pool IDs to their corresponding token indices in the Curve pool
    mapping(PoolId => PoolInfo) public poolIdToTokenInfo;

    error NativeCurrencyNotSupported();
    error AmountOutExceeded();
    error TokenNotInPool(address token);
    error TokensNotInPool(address token0, address token1);
    error PoolIsMetaPool();
    error InvalidPoolId();

    constructor(IPoolManager _manager, ICurveStableSwapNG _pool, ICurveStableSwapFactoryNG _curveFactory)
        BaseAggregatorHook(_manager, "StableSwapNGAggregator v1.0")
    {
        pool = _pool;
        curveFactory = _curveFactory;
    }

    /// @inheritdoc BaseAggregatorHook
    function _rawQuote(bool zeroToOne, int256 amountSpecified, PoolId poolId)
        internal
        view
        override
        returns (uint256 amountUnspecified)
    {
        PoolInfo storage poolInfo = poolIdToTokenInfo[poolId];
        if (amountSpecified < 0) {
            if (zeroToOne) {
                amountUnspecified = pool.get_dy(poolInfo.token0Index, poolInfo.token1Index, uint256(-amountSpecified));
            } else {
                amountUnspecified = pool.get_dy(poolInfo.token1Index, poolInfo.token0Index, uint256(-amountSpecified));
            }
        } else {
            uint256 amount = uint256(amountSpecified);
            uint256 _amountSpecified = amount + _getBuffer(amount);
            if (zeroToOne) {
                amountUnspecified = pool.get_dx(poolInfo.token0Index, poolInfo.token1Index, _amountSpecified);
            } else {
                amountUnspecified = pool.get_dx(poolInfo.token1Index, poolInfo.token0Index, _amountSpecified);
            }
        }
    }

    /// @inheritdoc BaseAggregatorHook
    function pseudoTotalValueLocked(PoolId poolId) external view override returns (uint256 amount0, uint256 amount1) {
        PoolInfo memory poolInfo = poolIdToTokenInfo[poolId];
        if (poolInfo.token0Index == 0 && poolInfo.token1Index == 0) revert InvalidPoolId();
        amount0 = pool.balances(uint256(uint128(poolInfo.token0Index)));
        amount1 = pool.balances(uint256(uint128(poolInfo.token1Index)));
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (curveFactory.is_meta(address(pool))) revert PoolIsMetaPool();

        uint256 totalCoins = curveFactory.get_n_coins(address(pool));
        bool token0Found = false;
        bool token1Found = false;
        int128 token0Index;
        int128 token1Index;
        for (uint256 i = 0; i < totalCoins; i++) {
            address coin = pool.coins(i);
            if (coin == Currency.unwrap(key.currency0)) {
                token0Index = int128(int256(i));
                token0Found = true;
            } else if (coin == Currency.unwrap(key.currency1)) {
                token1Index = int128(int256(i));
                token1Found = true;
            }
        }

        if (!token0Found && !token1Found) {
            revert TokensNotInPool(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1));
        }
        if (!token0Found) {
            revert TokenNotInPool(Currency.unwrap(key.currency0));
        }
        if (!token1Found) {
            revert TokenNotInPool(Currency.unwrap(key.currency1));
        }

        poolIdToTokenInfo[key.toId()] = PoolInfo({token0Index: token0Index, token1Index: token1Index});

        IERC20(Currency.unwrap(key.currency0)).forceApprove(address(pool), type(uint256).max);
        IERC20(Currency.unwrap(key.currency1)).forceApprove(address(pool), type(uint256).max);

        emit AggregatorPoolRegistered(key.toId());
        pollTokenJar();
        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc BaseAggregatorHook
    function _conductSwap(Currency settleCurrency, Currency takeCurrency, SwapParams calldata params, PoolId poolId)
        internal
        override
        returns (uint256 amountSettle, uint256 amountTake, bool hasSettled)
    {
        PoolInfo storage poolInfo = poolIdToTokenInfo[poolId];
        int128 tokenInIndex;
        int128 tokenOutIndex;
        if (params.zeroForOne) {
            tokenInIndex = poolInfo.token0Index;
            tokenOutIndex = poolInfo.token1Index;
        } else {
            tokenInIndex = poolInfo.token1Index;
            tokenOutIndex = poolInfo.token0Index;
        }

        if (params.amountSpecified < 0) {
            // Exact-In
            amountTake = uint256(-params.amountSpecified);
        } else {
            // Exact-Out: find out how much in (add buffer to cover precision loss)
            uint256 amount = uint256(params.amountSpecified);
            amountTake = pool.get_dx(tokenInIndex, tokenOutIndex, amount + _getBuffer(amount));
        }

        poolManager.take(takeCurrency, address(this), amountTake);

        amountSettle = _handleSwap(amountTake, tokenInIndex, tokenOutIndex, settleCurrency, params);
        hasSettled = true;

        return (amountSettle, amountTake, hasSettled);
    }

    function _handleSwap(
        uint256 amountTake,
        int128 tokenInIndex,
        int128 tokenOutIndex,
        Currency settleCurrency,
        SwapParams calldata params
    ) internal returns (uint256 amountOut) {
        poolManager.sync(settleCurrency);
        // Is exactOut has accuracy issues on Curve, so we do the gas inefficient way of transferring here first to ensure exact amount
        if (params.amountSpecified > 0) {
            // MinAmountOut is 0 to avoid slippage check because it is checked in the router
            pool.exchange(tokenInIndex, tokenOutIndex, amountTake, 0, address(this));
            amountOut = uint256(params.amountSpecified);
            settleCurrency.transfer(address(poolManager), uint256(params.amountSpecified));
        } else {
            // MinAmountOut is 0 to avoid slippage check because it is checked in the router
            amountOut = pool.exchange(tokenInIndex, tokenOutIndex, amountTake, 0, address(poolManager));
        }
        poolManager.settle();
    }

    function _getBuffer(uint256 amount) internal pure returns (uint256) {
        uint256 scaled = amount / INACCURACY_SCALE;
        return scaled > INACCURACY_BUFFER ? scaled : INACCURACY_BUFFER;
    }

    receive() external payable override {
        revert NativeCurrencyNotSupported();
    }
}
