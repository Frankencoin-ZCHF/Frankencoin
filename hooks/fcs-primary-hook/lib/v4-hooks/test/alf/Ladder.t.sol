// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Side} from "../../src/alf/types/BookPositions.sol";
import {
    BinCapacity,
    InvalidBinOffset,
    DuplicateBinOffset,
    BIN_CAPACITY_TYPEHASH,
    REPLACE_LADDER_TYPEHASH,
    CANCEL_LADDER_TYPEHASH,
    validOffset,
    validateDistinctOffsets,
    hashBinCapacities,
    replaceLadderStructHash,
    cancelLadderStructHash
} from "../../src/alf/types/Ladder.sol";

/// @notice Isolated coverage for the `Ladder` order type: per-side offset validation, the
///         distinct-offset bitmap, and the EIP-712 struct hashing that backs signed ladder
///         replacement and cancellation.
contract LadderTest is Test {
    PoolId internal poolId = PoolId.wrap(keccak256("pool"));
    address internal maker = makeAddr("maker");

    function extValidate(BinCapacity[] calldata bids, BinCapacity[] calldata asks) external pure {
        validateDistinctOffsets(bids, asks);
    }

    function _bin(int8 offset) internal pure returns (BinCapacity memory) {
        return BinCapacity({offset: offset, amount: 1e18});
    }

    // ══════════════════════════════════════════════════════════
    //  validOffset
    // ══════════════════════════════════════════════════════════

    function test_validOffset_bidRange() public pure {
        assertTrue(validOffset(Side.Bid, -1, 8));
        assertTrue(validOffset(Side.Bid, -8, 8));
        assertFalse(validOffset(Side.Bid, -9, 8));
        assertFalse(validOffset(Side.Bid, 0, 8));
        assertFalse(validOffset(Side.Bid, 1, 8));
    }

    function test_validOffset_askRange() public pure {
        assertTrue(validOffset(Side.Ask, 1, 8));
        assertTrue(validOffset(Side.Ask, 8, 8));
        assertFalse(validOffset(Side.Ask, 9, 8));
        assertFalse(validOffset(Side.Ask, 0, 8));
        assertFalse(validOffset(Side.Ask, -1, 8));
    }

    // ══════════════════════════════════════════════════════════
    //  validateDistinctOffsets
    // ══════════════════════════════════════════════════════════

    function test_validate_distinctSides_ok() public view {
        BinCapacity[] memory bids = new BinCapacity[](2);
        bids[0] = _bin(-1);
        bids[1] = _bin(-32);
        BinCapacity[] memory asks = new BinCapacity[](2);
        asks[0] = _bin(1);
        asks[1] = _bin(32);
        this.extValidate(bids, asks);
    }

    function test_validate_zeroOffset_reverts() public {
        BinCapacity[] memory bids = new BinCapacity[](1);
        bids[0] = _bin(0);
        BinCapacity[] memory asks = new BinCapacity[](0);
        vm.expectRevert(InvalidBinOffset.selector);
        this.extValidate(bids, asks);

        BinCapacity[] memory noBids = new BinCapacity[](0);
        BinCapacity[] memory zeroAsk = new BinCapacity[](1);
        zeroAsk[0] = _bin(0);
        vm.expectRevert(InvalidBinOffset.selector);
        this.extValidate(noBids, zeroAsk);
    }

    function test_validate_wrongSignedOffset_reverts() public {
        BinCapacity[] memory bids = new BinCapacity[](1);
        bids[0] = _bin(1); // positive offset on the bid side
        BinCapacity[] memory asks = new BinCapacity[](0);
        vm.expectRevert(InvalidBinOffset.selector);
        this.extValidate(bids, asks);

        BinCapacity[] memory noBids = new BinCapacity[](0);
        BinCapacity[] memory negAsk = new BinCapacity[](1);
        negAsk[0] = _bin(-1); // negative offset on the ask side
        vm.expectRevert(InvalidBinOffset.selector);
        this.extValidate(noBids, negAsk);
    }

    function test_validate_bidBelowEncodingFloor_reverts() public {
        BinCapacity[] memory bids = new BinCapacity[](1);
        bids[0] = _bin(-33);
        BinCapacity[] memory asks = new BinCapacity[](0);
        vm.expectRevert(InvalidBinOffset.selector);
        this.extValidate(bids, asks);
    }

    function test_validate_askAboveEncodingCeiling_reverts() public {
        BinCapacity[] memory bids = new BinCapacity[](0);
        BinCapacity[] memory asks = new BinCapacity[](1);
        asks[0] = _bin(33);
        vm.expectRevert(InvalidBinOffset.selector);
        this.extValidate(bids, asks);
    }

    function test_validate_duplicateOffsets_revert() public {
        BinCapacity[] memory bids = new BinCapacity[](2);
        bids[0] = _bin(-3);
        bids[1] = _bin(-3);
        BinCapacity[] memory asks = new BinCapacity[](0);
        vm.expectRevert(DuplicateBinOffset.selector);
        this.extValidate(bids, asks);

        BinCapacity[] memory noBids = new BinCapacity[](0);
        BinCapacity[] memory dupAsks = new BinCapacity[](2);
        dupAsks[0] = _bin(5);
        dupAsks[1] = _bin(5);
        vm.expectRevert(DuplicateBinOffset.selector);
        this.extValidate(noBids, dupAsks);
    }

    function test_validate_sameMagnitudeAcrossSides_ok() public view {
        // A -3 bid and a +3 ask are distinct bins; the bitmaps are per side.
        BinCapacity[] memory bids = new BinCapacity[](1);
        bids[0] = _bin(-3);
        BinCapacity[] memory asks = new BinCapacity[](1);
        asks[0] = _bin(3);
        this.extValidate(bids, asks);
    }

    // ══════════════════════════════════════════════════════════
    //  EIP-712 hashing
    // ══════════════════════════════════════════════════════════

    function test_typehashConstants() public pure {
        assertEq(BIN_CAPACITY_TYPEHASH, keccak256("BinCapacity(int8 offset,uint128 amount)"));
        assertEq(
            REPLACE_LADDER_TYPEHASH,
            keccak256(
                "ReplaceLadder(address maker,bytes32 poolId,BinCapacity[] bids,BinCapacity[] asks,uint40 ttl,int24 expectedRefTick,uint24 maxTickDeviation,uint256 nonce,uint256 deadline)BinCapacity(int8 offset,uint128 amount)"
            )
        );
        assertEq(
            CANCEL_LADDER_TYPEHASH,
            keccak256("CancelLadder(address maker,bytes32 poolId,uint256 nonce,uint256 deadline)")
        );
    }

    function extHashBins(BinCapacity[] calldata bins) external pure returns (bytes32) {
        return hashBinCapacities(bins);
    }

    function test_hashBinCapacities_matchesManualEncoding() public view {
        BinCapacity[] memory bins = new BinCapacity[](2);
        bins[0] = BinCapacity({offset: -1, amount: 5e18});
        bins[1] = BinCapacity({offset: -2, amount: 7e18});

        bytes32 h0 = keccak256(abi.encode(BIN_CAPACITY_TYPEHASH, bins[0].offset, bins[0].amount));
        bytes32 h1 = keccak256(abi.encode(BIN_CAPACITY_TYPEHASH, bins[1].offset, bins[1].amount));
        assertEq(this.extHashBins(bins), keccak256(abi.encodePacked(h0, h1)));
    }

    function extReplaceHash(
        BinCapacity[] calldata bids,
        BinCapacity[] calldata asks,
        uint40 ttl,
        int24 expectedRefTick,
        uint24 maxTickDeviation,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32) {
        return replaceLadderStructHash(
            poolId, maker, bids, asks, ttl, expectedRefTick, maxTickDeviation, nonce, deadline
        );
    }

    function test_replaceLadderStructHash_matchesManualEncoding() public view {
        BinCapacity[] memory bids = new BinCapacity[](1);
        bids[0] = _bin(-1);
        BinCapacity[] memory asks = new BinCapacity[](1);
        asks[0] = _bin(2);

        bytes32 expected = keccak256(
            abi.encode(
                REPLACE_LADDER_TYPEHASH,
                maker,
                poolId,
                this.extHashBins(bids),
                this.extHashBins(asks),
                uint40(120),
                int24(60),
                uint24(30),
                uint256(1),
                uint256(999)
            )
        );
        assertEq(this.extReplaceHash(bids, asks, 120, 60, 30, 1, 999), expected);
    }

    function test_cancelLadderStructHash_matchesManualEncoding() public view {
        bytes32 expected = keccak256(abi.encode(CANCEL_LADDER_TYPEHASH, maker, poolId, uint256(3), uint256(777)));
        assertEq(cancelLadderStructHash(poolId, maker, 3, 777), expected);
    }
}
