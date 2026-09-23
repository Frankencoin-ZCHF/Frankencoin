// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {
    BookPositions,
    PositionInfo,
    Side,
    DuplicatePosition,
    BOOK_SALT_NAMESPACE,
    positionId,
    positionSalt,
    isRetirable
} from "../../src/alf/types/BookPositions.sol";

/// @notice Isolated coverage for the `BookPositions` capability type: id/salt derivation, the
///         dual maker/pool index bookkeeping under record/remove (including swap-remove index
///         integrity), the retirement cursor, and the `isRetirable` predicate.
contract BookPositionsTest is Test {
    BookPositions internal book;

    PoolId internal poolId = PoolId.wrap(keccak256("pool"));
    PoolId internal otherPoolId = PoolId.wrap(keccak256("other-pool"));
    address internal maker = makeAddr("maker");
    address internal otherMaker = makeAddr("otherMaker");

    function extRecord(bytes32 id, PositionInfo memory info) external {
        book.record(id, info);
    }

    function _info(PoolId pool, address who, Side side, int24 tickLower) internal pure returns (PositionInfo memory) {
        return PositionInfo({
            maker: who,
            poolId: pool,
            side: side,
            tickLower: tickLower,
            tickUpper: tickLower + 60,
            liquidity: 1e18,
            expiry: 1_000,
            active: true
        });
    }

    function _recordBin(PoolId pool, address who, Side side, int24 tickLower) internal returns (bytes32 id) {
        id = positionId(pool, who, side, tickLower);
        book.record(id, _info(pool, who, side, tickLower));
    }

    // ══════════════════════════════════════════════════════════
    //  Derivations
    // ══════════════════════════════════════════════════════════

    function test_positionId_isDeterministicOverInputs() public view {
        bytes32 id = positionId(poolId, maker, Side.Bid, -60);
        assertEq(id, keccak256(abi.encode(poolId, maker, Side.Bid, int24(-60))));
        assertTrue(id != positionId(poolId, maker, Side.Ask, -60));
        assertTrue(id != positionId(poolId, maker, Side.Bid, -120));
        assertTrue(id != positionId(poolId, otherMaker, Side.Bid, -60));
        assertTrue(id != positionId(otherPoolId, maker, Side.Bid, -60));
    }

    function test_positionSalt_isNamespaced() public pure {
        bytes32 id = keccak256("some-position");
        assertEq(positionSalt(id), keccak256(abi.encode(BOOK_SALT_NAMESPACE, id)));
    }

    // ══════════════════════════════════════════════════════════
    //  Record / remove / indexes
    // ══════════════════════════════════════════════════════════

    function test_record_tracksInBothIndexes() public {
        bytes32 id = _recordBin(poolId, maker, Side.Bid, -60);

        assertEq(book.makerCount(poolId, maker), 1);
        assertEq(book.makerAt(poolId, maker, 0), id);
        assertEq(book.activeCount(poolId), 1);
        assertEq(book.activeAt(poolId, 0), id);

        PositionInfo memory p = book.get(id);
        assertTrue(p.active);
        assertEq(p.maker, maker);
        assertEq(p.tickLower, -60);
    }

    function test_record_duplicate_reverts() public {
        bytes32 id = _recordBin(poolId, maker, Side.Bid, -60);
        vm.expectRevert(DuplicatePosition.selector);
        this.extRecord(id, _info(poolId, maker, Side.Bid, -60));
    }

    function test_indexesAreMakerAndPoolScoped() public {
        _recordBin(poolId, maker, Side.Bid, -60);
        _recordBin(poolId, otherMaker, Side.Ask, 60);
        _recordBin(otherPoolId, maker, Side.Bid, -60);

        assertEq(book.makerCount(poolId, maker), 1);
        assertEq(book.makerCount(poolId, otherMaker), 1);
        assertEq(book.makerCount(otherPoolId, maker), 1);
        assertEq(book.activeCount(poolId), 2);
        assertEq(book.activeCount(otherPoolId), 1);
    }

    function test_remove_swapRemoveKeepsIndexesCoherent() public {
        bytes32 first = _recordBin(poolId, maker, Side.Bid, -60);
        bytes32 middle = _recordBin(poolId, maker, Side.Bid, -120);
        bytes32 last = _recordBin(poolId, maker, Side.Bid, -180);

        // Removing the middle entry swap-moves the last entry into its slot.
        book.remove(middle);

        assertEq(book.makerCount(poolId, maker), 2);
        assertEq(book.makerAt(poolId, maker, 0), first);
        assertEq(book.makerAt(poolId, maker, 1), last);
        assertEq(book.activeCount(poolId), 2);
        assertEq(book.activeAt(poolId, 0), first);
        assertEq(book.activeAt(poolId, 1), last);
        assertFalse(book.get(middle).active);

        // The moved entry's index stays addressable: removing it after the swap works.
        book.remove(last);
        assertEq(book.makerCount(poolId, maker), 1);
        assertEq(book.makerAt(poolId, maker, 0), first);
        assertEq(book.activeAt(poolId, 0), first);
    }

    function test_remove_untracked_isNoOp() public {
        _recordBin(poolId, maker, Side.Bid, -60);
        book.remove(keccak256("never-recorded"));
        assertEq(book.makerCount(poolId, maker), 1);
        assertEq(book.activeCount(poolId), 1);
    }

    function test_remove_thenRecordSameId_succeeds() public {
        bytes32 id = _recordBin(poolId, maker, Side.Bid, -60);
        book.remove(id);
        // The id is deterministic; a maker reposting the same bin reuses it.
        book.record(id, _info(poolId, maker, Side.Bid, -60));
        assertEq(book.makerCount(poolId, maker), 1);
    }

    // ══════════════════════════════════════════════════════════
    //  Cursor
    // ══════════════════════════════════════════════════════════

    function test_cursor_roundtrip() public {
        assertEq(book.cursor(poolId), 0);
        book.storeCursor(poolId, 7);
        assertEq(book.cursor(poolId), 7);
        assertEq(book.cursor(otherPoolId), 0);
    }

    // ══════════════════════════════════════════════════════════
    //  isRetirable
    // ══════════════════════════════════════════════════════════

    function test_isRetirable_freshInRange_false() public {
        PositionInfo memory p = _info(poolId, maker, Side.Ask, 60);
        vm.warp(p.expiry - 1);
        // Current tick inside the ask's range: not crossed, not expired.
        assertFalse(isRetirable(p, poolId, 90));
    }

    function test_isRetirable_expired_true() public {
        PositionInfo memory p = _info(poolId, maker, Side.Ask, 60);
        vm.warp(p.expiry);
        assertTrue(isRetirable(p, poolId, 90));
    }

    function test_isRetirable_crossedAsk_true() public {
        PositionInfo memory p = _info(poolId, maker, Side.Ask, 60);
        vm.warp(p.expiry - 1);
        assertTrue(isRetirable(p, poolId, p.tickUpper));
        assertFalse(isRetirable(p, poolId, p.tickUpper - 1));
    }

    function test_isRetirable_crossedBid_true() public {
        PositionInfo memory p = _info(poolId, maker, Side.Bid, -120);
        vm.warp(p.expiry - 1);
        assertTrue(isRetirable(p, poolId, p.tickLower - 1));
        assertFalse(isRetirable(p, poolId, p.tickLower));
    }

    function test_isRetirable_inactiveOrWrongPool_false() public {
        PositionInfo memory p = _info(poolId, maker, Side.Ask, 60);
        vm.warp(p.expiry); // would be retirable on expiry alone

        assertFalse(isRetirable(p, otherPoolId, 90));

        p.active = false;
        assertFalse(isRetirable(p, poolId, 90));
    }
}
