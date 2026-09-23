// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BaseAggregatorHook} from "./BaseAggregatorHook.sol";

/// @title BaseHookDataAggregator
/// @notice Variant of {BaseAggregatorHook} for aggregator hooks whose swap behaviour depends on the per-swap
///         `hookData` (e.g. an encoded order, intent, or signature). It forwards `hookData` into a hookData-aware
///         `_conductSwap`, so implementations read it straight from calldata — no storage stash, and no change to
///         the routing `quote` interface.
/// @dev This contract only overrides settlement so it can thread `hookData` through to a hookData-aware
///      `_conductSwap`; the shared delta/protocol-fee accounting is reused from `BaseAggregatorHook._innerBeforeSwap`,
///      so there is no duplicated logic to keep in sync with the base.
///      Hooks that do not need `hookData` should continue to extend {BaseAggregatorHook} directly so they remain
///      completely unaffected by this variant.
abstract contract BaseHookDataAggregator is BaseAggregatorHook {
    using PoolIdLibrary for PoolKey;

    /// @notice Thrown if the hookData-less `_conductSwap` overload is somehow reached. Hooks built on this base
    ///         only implement the hookData-aware overload.
    error HookDataRequired();
    error QuoteNotSupported();

    constructor(IPoolManager _manager, string memory _aggregatorHookVersion)
        BaseAggregatorHook(_manager, _aggregatorHookVersion)
    {}

    /// @inheritdoc BaseAggregatorHook
    /// @dev Settles via the hookData-aware `_conductSwap`, then delegates the delta/protocol-fee accounting to
    ///      the shared `BaseAggregatorHook._innerBeforeSwap`.
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (uint256 amountIn, uint256 amountOut) = _internalSettleWithHookData(key, params, hookData);
        return _innerBeforeSwap(sender, key, params, amountIn, amountOut);
    }

    /// @dev Mirror of `BaseAggregatorHook._internalSettle` that forwards `hookData` to `_conductSwap`.
    function _internalSettleWithHookData(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        returns (uint256 amountIn, uint256 amountOut)
    {
        Currency settleCurrency = params.zeroForOne ? key.currency1 : key.currency0;
        Currency takeCurrency = params.zeroForOne ? key.currency0 : key.currency1;

        (uint256 amountSettle, uint256 amountTake, bool hasSettled) =
            _conductSwap(settleCurrency, takeCurrency, params, key.toId(), hookData);

        if (!hasSettled) {
            _settle(settleCurrency, address(this), amountSettle);
        }

        return (amountTake, amountSettle);
    }

    /// @inheritdoc BaseAggregatorHook
    /// @dev Sealed: hooks on this base implement the hookData-aware overload below. This overload is never reached
    ///      because `_beforeSwap` routes through `_internalSettleWithHookData`.
    function _conductSwap(Currency, Currency, SwapParams calldata, PoolId)
        internal
        override
        returns (uint256, uint256, bool)
    {
        revert HookDataRequired();
    }

    /// @notice Conduct the swap on the aggregated liquidity source using the swap's `hookData`.
    /// @param settleCurrency The currency to be settled on the V4 PoolManager (swapper's output currency)
    /// @param takeCurrency The currency to be taken from the V4 PoolManager (swapper's input currency)
    /// @param params The swap parameters
    /// @param poolId The V4 Pool ID
    /// @param hookData The arbitrary hook data forwarded from the swap's beforeSwap call
    /// @return amountSettle The amount of the currency being settled (swapper's output amount)
    /// @return amountTake The amount of the currency being taken (swapper's input amount)
    /// @return hasSettled Whether the swap has been settled inside of the _conductSwap function
    function _conductSwap(
        Currency settleCurrency,
        Currency takeCurrency,
        SwapParams calldata params,
        PoolId poolId,
        bytes calldata hookData
    ) internal virtual returns (uint256 amountSettle, uint256 amountTake, bool hasSettled);

    /// @inheritdoc BaseAggregatorHook
    /// @dev Router-style quoting (no hookData) cannot resolve a per-swap order, so it is unsupported. Use
    ///      {quoteWithHookData} instead, supplying the order as hookData.
    function _rawQuote(bool, int256, PoolId) internal virtual override returns (uint256) {
        revert QuoteNotSupported();
    }

    /// @notice Returns the raw quote for a swap whose behaviour depends on `hookData`, without protocol fees.
    /// @dev Mirror of {_rawQuote} for hookData-driven hooks. Implementations resolve `hookData` to the
    ///      unspecified-side amount; whether this can be `view` depends on the implementation.
    function _rawQuoteWithHookData(bool zeroToOne, int256 amountSpecified, PoolId poolId, bytes calldata hookData)
        internal
        virtual
        returns (uint256 amountUnspecified);

    /// @notice hookData-aware analogue of {BaseAggregatorHook.quote}: resolves the order/intent in `hookData` and
    ///         applies the protocol fee the same way the standard quote does (via the shared `_innerQuote`).
    function quoteWithHookData(bool zeroToOne, int256 amountSpecified, PoolId poolId, bytes calldata hookData)
        external
        returns (uint256 amountUnspecified)
    {
        return _innerQuote(
            zeroToOne, amountSpecified, poolId, _rawQuoteWithHookData(zeroToOne, amountSpecified, poolId, hookData)
        );
    }
}
