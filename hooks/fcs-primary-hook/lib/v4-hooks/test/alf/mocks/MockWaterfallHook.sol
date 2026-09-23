// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {BaseHook} from "../../../src/base/BaseHook.sol";
import {IIndicativeQuote} from "../../../src/interfaces/IIndicativeQuote.sol";

/// @notice Test-only V4 hook that executes a constant-rate (1:1 minus a configurable fee) swap
///         in `beforeSwap`. Has `BEFORE_SWAP_RETURNS_DELTA_FLAG` set, so the multiplexer cannot
///         use `SwapSimulator` against it — the hook hits either tier 3 (IIndicativeQuote) or
///         tier 4 (reverting self-swap) depending on configuration.
///
///         Knobs:
///           - `claimIndicativeQuote`: when true, `supportsInterface(IIndicativeQuote)` returns
///             true (so the multiplexer's tier 3 fires). Defaults to false (tier 4 fallback).
///           - `indicativeQuoteReverts`: when true, `indicativeQuote` reverts; the multiplexer
///             should fall through to tier 4 in this case.
///           - `indicativeQuoteOverride`: when non-zero, `indicativeQuote` returns this value
///             instead of the constant-rate computation. Useful to test that the multiplexer
///             returns exactly what the hook reports.
///           - `feePips`: linear fee in 1e6 pips applied to the output amount (max 1_000_000).
contract MockWaterfallHook is BaseHook, IIndicativeQuote {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    bool public claimIndicativeQuote;
    bool public indicativeQuoteReverts;
    uint256 public indicativeQuoteOverride;
    uint24 public feePips;

    error MockIndicativeQuoteReverted();

    constructor(IPoolManager _manager) BaseHook(_manager) {}

    /// @notice Test plumbing — configure the hook's behavior for the next swap/quote.
    function setClaimIndicativeQuote(bool v) external {
        claimIndicativeQuote = v;
    }

    function setIndicativeQuoteReverts(bool v) external {
        indicativeQuoteReverts = v;
    }

    function setIndicativeQuoteOverride(uint256 v) external {
        indicativeQuoteOverride = v;
    }

    function setFeePips(uint24 v) external {
        feePips = v;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @inheritdoc IIndicativeQuote
    function indicativeQuote(PoolKey calldata, bool, int256 amountSpecified)
        external
        view
        override
        returns (uint256 amountUnspecified)
    {
        if (indicativeQuoteReverts) revert MockIndicativeQuoteReverted();
        if (indicativeQuoteOverride != 0) return indicativeQuoteOverride;
        uint256 abs = amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified);
        return _applyFee(abs);
    }

    /// @notice ERC-165. Toggled by `claimIndicativeQuote` for the IIndicativeQuote selector.
    function supportsInterface(bytes4 interfaceId) external view returns (bool) {
        if (interfaceId == type(IERC165).interfaceId) return true;
        if (interfaceId == type(IIndicativeQuote).interfaceId) return claimIndicativeQuote;
        return false;
    }

    // ──── Swap execution: constant-rate (1:1 minus feePips) ────

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        Currency takeCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        Currency settleCurrency = params.zeroForOne ? key.currency1 : key.currency0;

        if (params.amountSpecified < 0) {
            // Exact-in: consume |amountSpecified|, deliver applyFee(amount).
            uint256 amountIn = uint256(-params.amountSpecified);
            uint256 amountOut = _applyFee(amountIn);

            poolManager.take(takeCurrency, address(this), amountIn);
            poolManager.sync(settleCurrency);
            IERC20(Currency.unwrap(settleCurrency)).safeTransfer(address(poolManager), amountOut);
            poolManager.settle();

            int128 specifiedDelta = int128(-params.amountSpecified); // +amountIn
            int128 unspecifiedDelta = -int128(int256(amountOut));
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(specifiedDelta, unspecifiedDelta), 0);
        } else {
            // Exact-out: deliver amountSpecified, consume amountSpecified/(1-fee).
            uint256 amountOut = uint256(params.amountSpecified);
            uint256 amountIn = _reverseApplyFee(amountOut);

            poolManager.take(takeCurrency, address(this), amountIn);
            poolManager.sync(settleCurrency);
            IERC20(Currency.unwrap(settleCurrency)).safeTransfer(address(poolManager), amountOut);
            poolManager.settle();

            int128 specifiedDelta = -int128(int256(amountOut));
            int128 unspecifiedDelta = int128(int256(amountIn));
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(specifiedDelta, unspecifiedDelta), 0);
        }
    }

    function _applyFee(uint256 amount) internal view returns (uint256) {
        return amount - (amount * feePips) / 1_000_000;
    }

    function _reverseApplyFee(uint256 amount) internal view returns (uint256) {
        // Round up so the hook never under-collects input.
        uint256 num = amount * 1_000_000;
        uint256 den = 1_000_000 - feePips;
        return (num + den - 1) / den;
    }
}
