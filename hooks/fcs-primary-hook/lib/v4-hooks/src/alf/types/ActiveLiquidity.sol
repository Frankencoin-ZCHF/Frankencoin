// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @dev Transient-storage namespace seed for the active per-bucket JIT liquidity array. Combined
///      with a `PoolId` to derive a per-pool base slot; see {activeLiquidityFor}.
bytes32 constant ACTIVE_LIQUIDITY_NAMESPACE = keccak256("dualpoolhook.activeliq.v1");

/// @title ActiveLiquidity
/// @author Uniswap Labs
/// @notice The transient-storage base slot for a pool's per-bucket JIT liquidity, as a type-driven
///         value. A JIT hook derives one `ActiveLiquidity` per swap cycle via {activeLiquidityFor},
///         records each deployed bucket's liquidity with {store} during `beforeSwap`, and reads it
///         back with {takeAndClear} during `afterSwap` to size the inverse `modifyLiquidity`.
///
///         The slot for bucket `i` is `base + i`, so a single keccak per cycle yields the base and
///         every per-bucket access is a plain addition plus one `tstore`/`tload`. Transient storage
///         is used because the values live only for the duration of one `beforeSwap`/`afterSwap`
///         pair, which avoids the cold/warm SSTORE penalty (~22K cold, ~5K warm) per bucket that
///         persistent storage would incur.
///
///         ## Load-and-clear
///
///         {takeAndClear} zeroes each slot on read rather than relying on end-of-transaction
///         auto-clear. Transient storage scopes to the transaction, not the v4 unlock, so for
///         multiple swaps on the same pool within one transaction a stale value would otherwise
///         persist across cycles: if bucket `i` deployed `liq = 100` in swap 1 and the price moved
///         so bucket `i` deploys `liq = 0` in swap 2, the deploy path skips the write (it only
///         {store}s when `liq > 0`), leaving slot `i` at `100` from swap 1. Without the clear,
///         swap 2's teardown would read `100` and try to remove a position that no longer exists,
///         reverting the swap. {store} drops zero writes itself, so a zeroed slot unambiguously
///         means "no position deployed" regardless of caller discipline: the invariant is
///         self-enforcing rather than relying on every caller to skip zero stores.
/// @custom:security-contact security@uniswap.org
type ActiveLiquidity is bytes32;

using {store, takeAndClear} for ActiveLiquidity global;

/// @notice Derive the active-liquidity base slot for `poolId`.
/// @dev One keccak per JIT cycle; per-bucket slots are this base plus the bucket index.
/// @param poolId The pool whose JIT liquidity slots to address.
/// @return The per-pool transient base slot.
function activeLiquidityFor(PoolId poolId) pure returns (ActiveLiquidity) {
    return ActiveLiquidity.wrap(keccak256(abi.encode(ACTIVE_LIQUIDITY_NAMESPACE, poolId)));
}

/// @notice Record bucket `i`'s deployed liquidity in transient storage.
/// @dev Writes to slot `base + i`. The addition wraps in the unlikely event the keccak base is
///      near `type(uint256).max`, matching the v4 transient-namespace convention; the bucket index
///      is bounded well below that. A zero `liq` returns early without touching the slot, so a
///      zeroed slot unambiguously means "no position deployed for this bucket" and the load-and-clear
///      invariant holds without depending on callers to skip zero stores.
/// @param self The pool's active-liquidity base slot.
/// @param i    The bucket index.
/// @param liq  The liquidity deployed for the bucket.
function store(ActiveLiquidity self, uint256 i, uint128 liq) {
    if (liq == 0) return;
    bytes32 base = ActiveLiquidity.unwrap(self);
    assembly ("memory-safe") {
        tstore(add(base, i), liq)
    }
}

/// @notice Read bucket `i`'s recorded liquidity and clear the slot in one step.
/// @dev Reads slot `base + i` then zeroes it (see the type-level "Load-and-clear" note). Returns
///      `0` for any bucket that was never {store}d this cycle.
/// @param self The pool's active-liquidity base slot.
/// @param i    The bucket index.
/// @return liq The liquidity recorded for the bucket, or `0` if none.
function takeAndClear(ActiveLiquidity self, uint256 i) returns (uint128 liq) {
    bytes32 base = ActiveLiquidity.unwrap(self);
    assembly ("memory-safe") {
        let slot := add(base, i)
        liq := tload(slot)
        tstore(slot, 0)
    }
}
