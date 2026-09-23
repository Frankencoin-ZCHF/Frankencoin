// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Side} from "./BookPositions.sol";

/// @dev EIP-712 type hash for one `BinCapacity` entry.
bytes32 constant BIN_CAPACITY_TYPEHASH = keccak256("BinCapacity(int8 offset,uint128 amount)");

/// @dev EIP-712 type hash for a whole-ladder replacement order.
bytes32 constant REPLACE_LADDER_TYPEHASH = keccak256(
    "ReplaceLadder(address maker,bytes32 poolId,BinCapacity[] bids,BinCapacity[] asks,uint40 ttl,int24 expectedRefTick,uint24 maxTickDeviation,uint256 nonce,uint256 deadline)BinCapacity(int8 offset,uint128 amount)"
);

/// @dev EIP-712 type hash for a whole-ladder cancellation order.
bytes32 constant CANCEL_LADDER_TYPEHASH =
    keccak256("CancelLadder(address maker,bytes32 poolId,uint256 nonce,uint256 deadline)");

/// @dev A bin offset is outside its side's canonical range: bids must sit in `[-binsPerSide, -1]`
///      and asks in `[1, binsPerSide]`. Offset zero is reserved as the current-price gap.
error InvalidBinOffset();

/// @dev Two entries on the same side of a ladder share an offset. Each canonical bin can carry at
///      most one capacity entry per replacement.
error DuplicateBinOffset();

/// @notice Maker-supplied capacity for one canonical bin.
/// @dev Bids use negative offsets below the reference bin. Asks use positive offsets above the
///      reference bin. Offset zero is reserved as the current-price gap.
/// @param offset Canonical bin offset from the current reference bin.
/// @param amount Maker output amount to deploy into this bin.
struct BinCapacity {
    int8 offset;
    uint128 amount;
}

/// @notice Whether `offset` is canonical for `side` given the pool's `binsPerSide`.
/// @param side        Bid or ask.
/// @param offset      The offset to validate.
/// @param binsPerSide The pool's per-side bin count.
/// @return Whether the offset is within the side's canonical range.
function validOffset(Side side, int8 offset, uint8 binsPerSide) pure returns (bool) {
    if (side == Side.Bid) return offset < 0 && offset >= -int8(binsPerSide);
    return offset > 0 && offset <= int8(binsPerSide);
}

/// @notice Validate that every bid offset is negative, every ask offset is positive, and no side
///         repeats an offset.
/// @dev Uses one 32-bit-wide seen-bitmap per side (offsets are bounded to [-32, 32] by the int8
///      encoding and the `MAX_BINS_PER_SIDE` config bound). Reverts {InvalidBinOffset} for a
///      zero or wrong-signed offset and {DuplicateBinOffset} for a repeat. Range checking
///      against the pool's `binsPerSide` happens later, per bin, via {validOffset}.
/// @param bids Bid capacities.
/// @param asks Ask capacities.
function validateDistinctOffsets(BinCapacity[] calldata bids, BinCapacity[] calldata asks) pure {
    uint256 seenBids = 0;
    for (uint256 i; i < bids.length;) {
        int8 offset = bids[i].offset;
        if (offset < -32 || offset >= 0) revert InvalidBinOffset();
        uint256 bit = 1 << uint8(uint8(-offset) - 1);
        if (seenBids & bit != 0) revert DuplicateBinOffset();
        seenBids |= bit;
        unchecked {
            ++i;
        }
    }

    uint256 seenAsks = 0;
    for (uint256 i; i < asks.length;) {
        int8 offset = asks[i].offset;
        if (offset <= 0 || offset > 32) revert InvalidBinOffset();
        uint256 bit = 1 << uint8(uint8(offset) - 1);
        if (seenAsks & bit != 0) revert DuplicateBinOffset();
        seenAsks |= bit;
        unchecked {
            ++i;
        }
    }
}

/// @notice EIP-712 struct hash for a ladder replacement order.
/// @dev The consumer wraps this in its own EIP-712 domain via `_hashTypedDataV4`.
/// @param poolId           The pool the ladder targets.
/// @param maker            The maker whose ladder is being replaced.
/// @param bids             Bid capacities.
/// @param asks             Ask capacities.
/// @param ttl              Quote lifetime in seconds.
/// @param expectedRefTick  Reference tick the maker priced the ladder against.
/// @param maxTickDeviation Maximum allowed reference-tick drift at execution.
/// @param nonce            Maker nonce.
/// @param deadline         Signature expiry timestamp.
/// @return The EIP-712 struct hash.
function replaceLadderStructHash(
    PoolId poolId,
    address maker,
    BinCapacity[] calldata bids,
    BinCapacity[] calldata asks,
    uint40 ttl,
    int24 expectedRefTick,
    uint24 maxTickDeviation,
    uint256 nonce,
    uint256 deadline
) pure returns (bytes32) {
    return keccak256(
        abi.encode(
            REPLACE_LADDER_TYPEHASH,
            maker,
            poolId,
            hashBinCapacities(bids),
            hashBinCapacities(asks),
            ttl,
            expectedRefTick,
            maxTickDeviation,
            nonce,
            deadline
        )
    );
}

/// @notice EIP-712 struct hash for a ladder cancellation order.
/// @dev The consumer wraps this in its own EIP-712 domain via `_hashTypedDataV4`.
/// @param poolId   The pool the cancellation targets.
/// @param maker    The maker whose ladder is being cancelled.
/// @param nonce    Maker nonce.
/// @param deadline Signature expiry timestamp.
/// @return The EIP-712 struct hash.
function cancelLadderStructHash(PoolId poolId, address maker, uint256 nonce, uint256 deadline) pure returns (bytes32) {
    return keccak256(abi.encode(CANCEL_LADDER_TYPEHASH, maker, poolId, nonce, deadline));
}

/// @notice EIP-712 array hash for a list of `BinCapacity` entries.
/// @param bins The entries to hash.
/// @return The keccak256 of the concatenated per-entry struct hashes.
function hashBinCapacities(BinCapacity[] calldata bins) pure returns (bytes32) {
    bytes32[] memory hashes = new bytes32[](bins.length);
    for (uint256 i; i < bins.length;) {
        hashes[i] = keccak256(abi.encode(BIN_CAPACITY_TYPEHASH, bins[i].offset, bins[i].amount));
        unchecked {
            ++i;
        }
    }
    return keccak256(abi.encodePacked(hashes));
}
