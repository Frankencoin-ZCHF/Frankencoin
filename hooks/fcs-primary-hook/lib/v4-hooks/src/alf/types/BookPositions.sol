// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @dev Namespace seed for hook-owned v4 position salts. Kept identical to the pre-refactor
///      `NativeBookHook` constant so position salts are bit-for-bit unchanged.
bytes32 constant BOOK_SALT_NAMESPACE = keccak256("alf.native-book.salt.v1");

/// @dev A position id was recorded while an entry with the same id is still tracked. Position ids
///      are deterministic over `(poolId, maker, side, tickLower)`, so a live duplicate means the
///      caller failed to remove the prior bin first.
error DuplicatePosition();

/// @notice Side of a native-book maker position.
enum Side {
    Bid,
    Ask
}

/// @notice Hook-owned position metadata for one maker bin.
/// @param maker Maker that owns this quote.
/// @param poolId Pool this quote belongs to.
/// @param side Bid or ask.
/// @param tickLower Native v4 position lower tick.
/// @param tickUpper Native v4 position upper tick.
/// @param liquidity Native v4 liquidity currently deployed.
/// @param expiry Unix timestamp after which the quote can be retired.
/// @param active Whether this slot currently owns native v4 liquidity.
struct PositionInfo {
    address maker;
    PoolId poolId;
    Side side;
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    uint40 expiry;
    bool active;
}

/// @title BookPositions
/// @author Uniswap Labs
/// @notice The NativeBook position registry, as a type-driven value. Tracks every active
///         hook-owned bin three ways: by id ({get}), by maker ({makerCount}/{makerAt}, backing
///         whole-ladder replacement and cancellation), and by pool ({activeCount}/{activeAt},
///         backing the bounded opportunistic retirement scan through {cursor}/{storeCursor}).
///         Index arrays use swap-remove with a one-based index mapping so removal is O(1) and a
///         zero index means untracked.
/// @param _positions Position metadata by id.
/// @param _makerPositions Active position ids per `(poolId, maker)` key.
/// @param _makerPositionIndex One-based index of an id in its maker array. Zero means untracked.
/// @param _activePositions Active position ids per pool.
/// @param _activePositionIndex One-based index of an id in its pool array. Zero means untracked.
/// @param _retireCursor Per-pool scan cursor for bounded opportunistic retirement.
/// @custom:security-contact security@uniswap.org
struct BookPositions {
    mapping(bytes32 positionId => PositionInfo) _positions;
    mapping(bytes32 makerKey => bytes32[]) _makerPositions;
    mapping(bytes32 positionId => uint256) _makerPositionIndex;
    mapping(PoolId poolId => bytes32[]) _activePositions;
    mapping(bytes32 positionId => uint256) _activePositionIndex;
    mapping(PoolId poolId => uint256) _retireCursor;
}

using {get, record, remove, makerCount, makerAt, activeCount, activeAt, cursor, storeCursor} for BookPositions global;

/// @notice Deterministic id for a maker bin.
/// @dev One id per `(poolId, maker, side, tickLower)`: a maker replacing a bin at the same tick
///      reuses the same id (and therefore the same v4 position salt) after removing the prior one.
/// @param poolId    The pool the bin belongs to.
/// @param maker     The maker that owns the bin.
/// @param side      Bid or ask.
/// @param tickLower The bin's lower tick.
/// @return The position id.
function positionId(PoolId poolId, address maker, Side side, int24 tickLower) pure returns (bytes32) {
    return keccak256(abi.encode(poolId, maker, side, tickLower));
}

/// @notice Derive the v4 position salt for a position id.
/// @dev Namespaced so the hook's own positions cannot collide with any other salt scheme sharing
///      the hook address.
/// @param id The position id.
/// @return The salt to pass to `modifyLiquidity`.
function positionSalt(bytes32 id) pure returns (bytes32) {
    return keccak256(abi.encode(BOOK_SALT_NAMESPACE, id));
}

/// @notice Whether a position is currently retirable.
/// @dev A position is retirable when it is active in `poolId` and either expired by wall clock or
///      crossed: an ask whose full range is at or below the current tick, or a bid whose range is
///      above it. Crossed bins hold only the taker-side token, so leaving them deployed grants
///      free optionality against the maker.
/// @param p           The position metadata (a memory snapshot).
/// @param poolId      The pool the caller is operating on.
/// @param currentTick The pool's current tick.
/// @return Whether the position can be retired.
function isRetirable(PositionInfo memory p, PoolId poolId, int24 currentTick) view returns (bool) {
    if (!p.active || PoolId.unwrap(p.poolId) != PoolId.unwrap(poolId)) return false;
    if (block.timestamp >= p.expiry) return true;
    if (p.side == Side.Ask) return currentTick >= p.tickUpper;
    return currentTick < p.tickLower;
}

/// @notice Read the metadata stored for `id`.
/// @dev Returns a storage pointer; callers that mutate the registry afterwards should copy to
///      memory first. An untracked id returns the zero struct (`active == false`).
/// @param self BookPositions storage.
/// @param id   The position id to read.
/// @return The position metadata.
function get(BookPositions storage self, bytes32 id) view returns (PositionInfo storage) {
    return self._positions[id];
}

/// @notice Record a new active position and track it in the maker and pool indexes.
/// @dev Reverts {DuplicatePosition} if `id` is already tracked in either index.
/// @param self BookPositions storage.
/// @param id   The position id to record.
/// @param info The position metadata to store.
function record(BookPositions storage self, bytes32 id, PositionInfo memory info) {
    if (self._makerPositionIndex[id] != 0 || self._activePositionIndex[id] != 0) revert DuplicatePosition();

    self._positions[id] = info;

    bytes32 mk = _makerKey(info.poolId, info.maker);
    self._makerPositionIndex[id] = self._makerPositions[mk].length + 1;
    self._makerPositions[mk].push(id);
    self._activePositionIndex[id] = self._activePositions[info.poolId].length + 1;
    self._activePositions[info.poolId].push(id);
}

/// @notice Delete a position and remove it from the maker and pool indexes.
/// @dev Swap-remove keeps both index arrays dense. A no-op for ids that are not tracked.
/// @param self BookPositions storage.
/// @param id   The position id to remove.
function remove(BookPositions storage self, bytes32 id) {
    PositionInfo storage p = self._positions[id];
    bytes32 mk = _makerKey(p.poolId, p.maker);
    PoolId poolId = p.poolId;

    delete self._positions[id];
    _removeTracked(self._makerPositions[mk], self._makerPositionIndex, id);
    _removeTracked(self._activePositions[poolId], self._activePositionIndex, id);
}

/// @notice Number of active position ids tracked for `maker` in `poolId`.
/// @param self   BookPositions storage.
/// @param poolId The pool to read.
/// @param maker  The maker to read.
/// @return The maker's active position count.
function makerCount(BookPositions storage self, PoolId poolId, address maker) view returns (uint256) {
    return self._makerPositions[_makerKey(poolId, maker)].length;
}

/// @notice Read the maker's active position id at `index`.
/// @param self   BookPositions storage.
/// @param poolId The pool to read.
/// @param maker  The maker to read.
/// @param index  Zero-based index into the maker's active ids.
/// @return The position id at `index`.
function makerAt(BookPositions storage self, PoolId poolId, address maker, uint256 index) view returns (bytes32) {
    return self._makerPositions[_makerKey(poolId, maker)][index];
}

/// @notice Number of active position ids tracked for `poolId`.
/// @param self   BookPositions storage.
/// @param poolId The pool to read.
/// @return The pool's active position count.
function activeCount(BookPositions storage self, PoolId poolId) view returns (uint256) {
    return self._activePositions[poolId].length;
}

/// @notice Read the pool's active position id at `index`.
/// @param self   BookPositions storage.
/// @param poolId The pool to read.
/// @param index  Zero-based index into the pool's active ids.
/// @return The position id at `index`.
function activeAt(BookPositions storage self, PoolId poolId, uint256 index) view returns (bytes32) {
    return self._activePositions[poolId][index];
}

/// @notice Read the pool's bounded-retirement scan cursor.
/// @param self   BookPositions storage.
/// @param poolId The pool to read.
/// @return The cursor into the pool's active ids.
function cursor(BookPositions storage self, PoolId poolId) view returns (uint256) {
    return self._retireCursor[poolId];
}

/// @notice Store the pool's bounded-retirement scan cursor.
/// @param self   BookPositions storage.
/// @param poolId The pool to update.
/// @param value  The new cursor value.
function storeCursor(BookPositions storage self, PoolId poolId, uint256 value) {
    self._retireCursor[poolId] = value;
}

/// @dev Key for the per-maker index: one array per `(poolId, maker)`.
function _makerKey(PoolId poolId, address maker) pure returns (bytes32) {
    return keccak256(abi.encode(poolId, maker));
}

/// @dev Swap-remove `id` from `ids`, maintaining the one-based `indexOf` mapping. A no-op when
///      `id` is untracked.
function _removeTracked(bytes32[] storage ids, mapping(bytes32 => uint256) storage indexOf, bytes32 id) {
    uint256 indexPlusOne = indexOf[id];
    if (indexPlusOne == 0) return;
    uint256 index = indexPlusOne - 1;
    uint256 lastIndex = ids.length - 1;
    if (index != lastIndex) {
        bytes32 last = ids[lastIndex];
        ids[index] = last;
        indexOf[last] = indexPlusOne;
    }
    ids.pop();
    delete indexOf[id];
}
