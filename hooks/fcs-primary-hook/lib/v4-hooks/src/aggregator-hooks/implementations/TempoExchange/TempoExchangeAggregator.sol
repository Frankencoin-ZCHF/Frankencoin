// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {BaseAggregatorHook} from "../../BaseAggregatorHook.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ITempoExchange} from "./interfaces/ITempoExchange.sol";
import {ITIP20} from "./interfaces/ITIP20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title TempoExchangeAggregator
/// @notice Singleton Uniswap V4 hook that aggregates liquidity from Tempo's enshrined stablecoin DEX
/// @dev Supports multiple pools and both exact-input and exact-output swaps
/// @dev Tempo uses uint128 for amounts; this contract handles the conversion from uint256
contract TempoExchangeAggregator is BaseAggregatorHook {
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    /// @notice The Tempo stablecoin exchange (precompiled contract)
    ITempoExchange public immutable tempoExchange;

    /// @notice Token pair info for each registered pool
    struct PoolTokens {
        address token0;
        address token1;
    }

    /// @notice Maps Uniswap V4 pool IDs to their token addresses
    mapping(PoolId => PoolTokens) public poolIdToTokens;

    /// @notice Canonical pool per token pair (key = keccak256(abi.encode(ordered token0, ordered token1)))
    /// @dev Enforces one pool per pair
    mapping(bytes32 => PoolId) private _canonicalPoolByPair;

    // Tempo's exact-out quoting operates per-tick while execution operates per-order,
    // so accumulated rounding can cause the real input consumed to differ from the quoted value.
    // Buffer scales with amount: max(INACCURACY_BUFFER, amount / INACCURACY_SCALE)
    uint256 private constant INACCURACY_BUFFER = 20;
    uint256 private constant INACCURACY_SCALE = 1_000_000; // 1 part per million

    error AmountExceedsUint128();
    error TokensNotSupported(address token0, address token1);
    error ExchangeDoesNotSupportPair(address token0, address token1);
    error PairAlreadyHasCanonicalPool(PoolId existingPoolId, address token0, address token1);

    /// @param _manager The Uniswap V4 PoolManager contract
    /// @param _tempoExchange The Tempo stablecoin exchange address
    constructor(IPoolManager _manager, ITempoExchange _tempoExchange)
        BaseAggregatorHook(_manager, "TempoExchangeAggregator v1.0")
    {
        tempoExchange = _tempoExchange;
    }

    /// @inheritdoc BaseAggregatorHook
    function _rawQuote(bool zeroToOne, int256 amountSpecified, PoolId poolId)
        internal
        view
        override
        returns (uint256 amountUnspecified)
    {
        PoolTokens storage tokens = poolIdToTokens[poolId];
        if (tokens.token0 == address(0)) revert PoolDoesNotExist();

        address tokenIn = zeroToOne ? tokens.token0 : tokens.token1;
        address tokenOut = zeroToOne ? tokens.token1 : tokens.token0;

        if (amountSpecified < 0) {
            // Exact-In: get expected output
            uint128 amountIn = _safeToUint128(uint256(-amountSpecified));
            amountUnspecified = uint256(tempoExchange.quoteSwapExactAmountIn(tokenIn, tokenOut, amountIn));
        } else {
            // Exact-Out: get required input (with buffer for per-tick vs per-order rounding)
            uint128 amountOut = _safeToUint128(uint256(amountSpecified));
            uint256 quoted = uint256(tempoExchange.quoteSwapExactAmountOut(tokenIn, tokenOut, amountOut));
            amountUnspecified = quoted + _getBuffer(quoted);
        }
    }

    /// @inheritdoc BaseAggregatorHook
    function pseudoTotalValueLocked(PoolId poolId) external view override returns (uint256 amount0, uint256 amount1) {
        PoolTokens storage tokens = poolIdToTokens[poolId];
        if (tokens.token0 == address(0)) revert PoolDoesNotExist();
        // Tempo exchange is a precompiled contract, query token balances directly
        amount0 = IERC20(tokens.token0).balanceOf(address(tempoExchange));
        amount1 = IERC20(tokens.token1).balanceOf(address(tempoExchange));
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        // Validate tokens are directly connected in the DEX tree
        // One must be the quoteToken of the other (no multi-hop pairs)
        bool directlyConnected = ITIP20(token0).quoteToken() == token1 || ITIP20(token1).quoteToken() == token0;
        if (!directlyConnected) {
            revert TokensNotSupported(token0, token1);
        }

        // Verify the pair is actually supported by the Tempo exchange precompile.
        // The quoteToken() check above only trusts the tokens' self-reported interface;
        // a malicious ERC20 could implement quoteToken() to spoof adjacency.
        // This call confirms the exchange can actually trade this pair.
        try tempoExchange.quoteSwapExactAmountIn(token0, token1, 1) {}
        catch {
            revert ExchangeDoesNotSupportPair(token0, token1);
        }

        // Enforce one canonical pool per token pair
        bytes32 pairKey = _canonicalPairKey(token0, token1);
        PoolId existing = _canonicalPoolByPair[pairKey];
        if (PoolId.unwrap(existing) != bytes32(0)) {
            revert PairAlreadyHasCanonicalPool(existing, token0, token1);
        }
        _canonicalPoolByPair[pairKey] = key.toId();

        // Store token addresses for this pool
        poolIdToTokens[key.toId()] = PoolTokens({token0: token0, token1: token1});

        // Approve Tempo exchange to spend tokens (forceApprove handles repeated approvals safely)
        IERC20(token0).forceApprove(address(tempoExchange), type(uint256).max);
        IERC20(token1).forceApprove(address(tempoExchange), type(uint256).max);

        emit AggregatorPoolRegistered(key.toId());
        pollTokenJar();
        return IHooks.beforeInitialize.selector;
    }

    function _conductSwap(Currency settleCurrency, Currency takeCurrency, SwapParams calldata params, PoolId)
        internal
        override
        returns (uint256 amountSettle, uint256 amountTake, bool hasSettled)
    {
        address tokenIn = Currency.unwrap(takeCurrency);
        address tokenOut = Currency.unwrap(settleCurrency);

        if (params.amountSpecified < 0) {
            // Exact-In swap
            amountTake = uint256(-params.amountSpecified);
            uint128 amountIn = _safeToUint128(amountTake);

            // Take input tokens from PoolManager to hook
            poolManager.take(takeCurrency, address(this), amountTake);

            // Execute swap on Tempo (output comes to hook)
            uint128 amountOut = tempoExchange.swapExactAmountIn(tokenIn, tokenOut, amountIn, 0);
            amountSettle = uint256(amountOut);

            // Sync output currency and transfer to PoolManager
            poolManager.sync(settleCurrency);
            IERC20(tokenOut).safeTransfer(address(poolManager), amountSettle);
            poolManager.settle();
            hasSettled = true;
        } else {
            // Exact-Out swap
            amountSettle = uint256(params.amountSpecified);
            uint128 amountOut = _safeToUint128(amountSettle);

            // Get the required input amount with buffer for per-tick vs per-order rounding
            uint128 requiredIn = tempoExchange.quoteSwapExactAmountOut(tokenIn, tokenOut, amountOut);
            uint256 bufferedIn = uint256(requiredIn) + _getBuffer(uint256(requiredIn));

            // Take buffered input tokens from PoolManager to hook
            poolManager.take(takeCurrency, address(this), bufferedIn);

            // Execute swap on Tempo and capture actual input consumed
            uint128 actualIn =
                tempoExchange.swapExactAmountOut(tokenIn, tokenOut, amountOut, _safeToUint128(bufferedIn));
            amountTake = uint256(actualIn);

            // Return unused input tokens to PoolManager
            uint256 excess = bufferedIn - amountTake;
            if (excess > 0) {
                poolManager.sync(takeCurrency);
                IERC20(tokenIn).safeTransfer(address(poolManager), excess);
                poolManager.settle();
            }

            // Sync output currency and transfer to PoolManager
            poolManager.sync(settleCurrency);
            IERC20(tokenOut).safeTransfer(address(poolManager), amountSettle);
            poolManager.settle();
            hasSettled = true;
        }

        return (amountSettle, amountTake, hasSettled);
    }

    /// @notice Returns the canonical storage key for a token pair (ordered by address)
    function _canonicalPairKey(address token0, address token1) private pure returns (bytes32) {
        (address t0, address t1) = token0 < token1 ? (token0, token1) : (token1, token0);
        return keccak256(abi.encode(t0, t1));
    }

    /// @notice Returns a buffer to account for per-tick vs per-order rounding in exact-out quotes
    function _getBuffer(uint256 amount) internal pure returns (uint256) {
        uint256 scaled = amount / INACCURACY_SCALE;
        return scaled > INACCURACY_BUFFER ? scaled : INACCURACY_BUFFER;
    }

    /// @notice Safely converts uint256 to uint128, reverting on overflow
    /// @param value The uint256 value to convert
    /// @return The uint128 value
    function _safeToUint128(uint256 value) internal pure returns (uint128) {
        if (value > type(uint128).max) revert AmountExceedsUint128();
        return uint128(value);
    }
}
