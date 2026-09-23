// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Emitted when a pool's liveness flag changes.
/// @param poolId The pool whose liveness changed.
/// @param isLive The new liveness state.
event PoolLivenessUpdated(PoolId indexed poolId, bool isLive);

/// @dev A live-gated operation (a swap) ran on a paused pool. Pools default to paused after
///      `manager.initialize`; the owner enables a pool via its `setPoolLive` entry point.
/// @param poolId The pool whose live flag is currently false.
error PoolNotLive(PoolId poolId);

/// @title Liveness
/// @author Uniswap Labs
/// @notice Per-pool pause/resume flag for ALF quoter hooks, as a type-driven value. A pool defaults
///         to paused (`false`); the owner toggles it. Swap entry points gate on {requireLive}, and
///         the hook reports per-pool state via the consumer's `livePools` getter. The hook-level
///         `IALFHook.isLive()` is a separate, coarser signal and is unaffected by this type.
/// @param _inner Whether each pool is currently quoting and executing swaps.
/// @custom:security-contact security@uniswap.org
struct Liveness {
    mapping(PoolId poolId => bool) _inner;
}

using {isLive, setLive, requireLive} for Liveness global;

/// @notice Whether `poolId` is currently live.
/// @param self   Liveness storage.
/// @param poolId The pool to read.
/// @return Whether the pool is live and accepting swaps.
function isLive(Liveness storage self, PoolId poolId) view returns (bool) {
    return self._inner[poolId];
}

/// @notice Set `poolId`'s liveness flag and emit {PoolLivenessUpdated}.
/// @param self   Liveness storage.
/// @param poolId The pool to toggle.
/// @param live   The new liveness state.
function setLive(Liveness storage self, PoolId poolId, bool live) {
    self._inner[poolId] = live;
    emit PoolLivenessUpdated(poolId, live);
}

/// @notice Revert {PoolNotLive} if `poolId` is paused.
/// @param self   Liveness storage.
/// @param poolId The pool to gate on.
function requireLive(Liveness storage self, PoolId poolId) view {
    if (!self._inner[poolId]) revert PoolNotLive(poolId);
}
