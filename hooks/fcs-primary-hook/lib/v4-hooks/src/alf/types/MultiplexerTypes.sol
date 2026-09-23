// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title MultiplexerTypes
/// @author Uniswap Labs
/// @notice hookData encoding for the ALF multiplexer.
/// @dev Callers encode hookData as `abi.encode(MultiplexerHookData(...))`.
///
///      The multiplexer supports two execution modes, selected implicitly:
///
///      **Autonomous mode** (all targets have amountSpecified = 0):
///        The multiplexer queries each target for an indicative quote, sorts by quote
///        quality, and executes a greedy split fill with price limits derived from each
///        candidate's pool state. Self-contained: no external planning required.
///
///      **Pre-planned mode** (any target has amountSpecified != 0):
///        The router has pre-computed the optimal split (e.g., using `swapToPrice` offchain).
///        The multiplexer executes targets in the given order with their specified amounts.
///        A target with amountSpecified = 0 receives whatever input/output remains.
///        Skips indicative queries and sorting: lower gas, router controls execution.
///
///      Both modes support tolerance enforcement via `strictTolerancePips` and forward
///      shared attestation data to the nested swaps.
/// @param attestationData Shared attestation payload forwarded to nested quoter swaps.
/// @param targets Targeted quoter list. Must be non-empty.
/// @param strictTolerancePips Maximum relative deviation before revert, in parts per million
///                            (parts-per-million, not basis points: 10_000 pips = 1%).
///                            Set to 0 to disable strict tolerance checks.
struct MultiplexerHookData {
    bytes attestationData;
    TargetedQuoter[] targets;
    uint24 strictTolerancePips;
}

/// @notice A specific quoter target for the multiplexer.
/// @dev `amountSpecified` controls how much flow this quoter handles:
///        - 0: autonomous mode, the multiplexer decides (fills remaining with price limits)
///        - negative: exact input amount for this quoter (e.g., -600e18 = spend 600 tokens here)
///        - positive: exact output amount from this quoter (e.g., 400e18 = get 400 tokens here)
///      The sign convention matches SwapParams.amountSpecified.
/// @param poolKey The quoter's pool key (hook address embedded in `poolKey.hooks`).
/// @param amountSpecified Pre-planned amount for this quoter. Zero lets the multiplexer
///                        decide the amount or fill the remaining amount.
struct TargetedQuoter {
    PoolKey poolKey;
    int256 amountSpecified;
}
