// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IIndicativeQuote
/// @notice Minimal, non-binding-quote interface for V4 hooks that override the AMM curve but
///         expose a cheap on-chain price oracle. Designed to sit between the rich `IALFHook`
///         surface (which carries gas budgets, liveness, attestation) and the universal but
///         expensive reverting-self-swap quote primitive.
/// @dev    Routers and aggregators (e.g. `ALFMultiplexer`) probe for support via ERC-165 and
///         call `indicativeQuote` to size split-fills or rank candidates without paying for a
///         full reverting swap. Implementations SHOULD NOT mutate state. Implementations MAY
///         return `0` to signal that the pool is currently untradable (e.g. pair retired, no
///         inventory) — callers treat `0` as "skip this candidate".
interface IIndicativeQuote is IERC165 {
    /// @notice Non-binding indicative quote for a swap. The actual execution price may differ
    ///         (e.g., by a router-applied protocol fee, or by within-block oracle drift).
    /// @param key The pool key being quoted.
    /// @param zeroForOne Swap direction.
    /// @param amountSpecified V4 convention: negative for exact input, positive for exact output.
    /// @return amountUnspecified For exact-in: expected output amount. For exact-out: required
    ///         input amount. Always positive (or `0` if no quote is available).
    function indicativeQuote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified)
        external
        returns (uint256 amountUnspecified);
}
