// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {MultiAssetShareMath} from "../../src/alf/base/vault/MultiAssetShareMath.sol";

/// @title MultiAssetShareMathFuzzTest
/// @notice Stateless property fuzzing for the pure share-math primitive that underpins every
///         ALF vault (`PoolVault` / `MultiAssetVault`). These are the value-conservation and
///         anti-dilution properties the whole LP accounting rests on, exercised directly
///         against the library so they are independent of any hook's state machine.
///
/// @dev    `MultiAssetShareMath` is `internal pure`, so the test calls it directly (functions
///         inline into this contract). Inputs are bounded to realistic-but-wide ranges that
///         keep the intermediate products inside `uint256` without relying on the 512-bit
///         path to mask an unintended overflow.
contract MultiAssetShareMathFuzzTest is Test {
    /// @dev Upper bound for balances/supply. 1e33 dwarfs any real token supply yet keeps
    ///      `shares * (total + 1)` well inside `uint256` (1e33 * 1e33 = 1e66 << 1.1e77).
    uint256 internal constant MAX_AMOUNT = 1e33;
    uint8 internal constant MAX_OFFSET = 18;

    // ───────────────────────────── convertToAmounts ─────────────────────────────

    /// @notice ANTI-DILUTION: for identical state and share count, the deposit (round-up)
    ///         conversion never returns less than the withdraw (round-down) conversion, and
    ///         the gap is at most 1 wei per asset. This is what guarantees a depositor pays
    ///         at least what an immediate withdrawer would receive — no value can be minted
    ///         out of rounding.
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_convertToAmounts_roundUpGeRoundDown(
        uint256 shares,
        uint256 total0,
        uint256 total1,
        uint256 supply,
        uint8 offset
    ) public pure {
        offset = uint8(bound(offset, 0, MAX_OFFSET));
        supply = bound(supply, 1, MAX_AMOUNT);
        shares = bound(shares, 0, supply);
        total0 = bound(total0, 0, MAX_AMOUNT);
        total1 = bound(total1, 0, MAX_AMOUNT);

        (uint256 up0, uint256 up1) = MultiAssetShareMath.convertToAmounts(shares, total0, total1, supply, offset, true);
        (uint256 dn0, uint256 dn1) = MultiAssetShareMath.convertToAmounts(shares, total0, total1, supply, offset, false);

        assertGe(up0, dn0, "roundUp0 < roundDown0");
        assertGe(up1, dn1, "roundUp1 < roundDown1");
        assertLe(up0 - dn0, 1, "rounding gap0 > 1 wei");
        assertLe(up1 - dn1, 1, "rounding gap1 > 1 wei");
    }

    /// @notice MONOTONICITY IN SHARES: more shares converts to at least as many assets, in
    ///         both rounding modes. A withdrawer burning more shares can never receive less.
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_convertToAmounts_monotonicInShares(
        uint256 sharesA,
        uint256 sharesB,
        uint256 total0,
        uint256 total1,
        uint256 supply,
        uint8 offset
    ) public pure {
        offset = uint8(bound(offset, 0, MAX_OFFSET));
        supply = bound(supply, 1, MAX_AMOUNT);
        sharesA = bound(sharesA, 0, supply);
        sharesB = bound(sharesB, sharesA, supply); // sharesB >= sharesA
        total0 = bound(total0, 0, MAX_AMOUNT);
        total1 = bound(total1, 0, MAX_AMOUNT);

        (uint256 a0, uint256 a1) = MultiAssetShareMath.convertToAmounts(sharesA, total0, total1, supply, offset, false);
        (uint256 b0, uint256 b1) = MultiAssetShareMath.convertToAmounts(sharesB, total0, total1, supply, offset, false);

        assertGe(b0, a0, "asset0 not monotonic in shares");
        assertGe(b1, a1, "asset1 not monotonic in shares");
    }

    /// @notice MONOTONICITY IN BALANCE: more underlying for the same shares/supply converts
    ///         to at least as many assets (yield accrual can only increase a share's value).
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_convertToAmounts_monotonicInBalance(
        uint256 shares,
        uint256 totalLo,
        uint256 totalHi,
        uint256 supply,
        uint8 offset
    ) public pure {
        offset = uint8(bound(offset, 0, MAX_OFFSET));
        supply = bound(supply, 1, MAX_AMOUNT);
        shares = bound(shares, 0, supply);
        totalLo = bound(totalLo, 0, MAX_AMOUNT);
        totalHi = bound(totalHi, totalLo, MAX_AMOUNT); // totalHi >= totalLo

        (uint256 lo,) = MultiAssetShareMath.convertToAmounts(shares, totalLo, 0, supply, offset, false);
        (uint256 hi,) = MultiAssetShareMath.convertToAmounts(shares, totalHi, 0, supply, offset, false);

        assertGe(hi, lo, "asset amount not monotonic in balance");
    }

    /// @notice IDENTITY: zero shares converts to zero assets in both rounding modes.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_convertToAmounts_zeroSharesIsZero(uint256 total0, uint256 total1, uint256 supply, uint8 offset)
        public
        pure
    {
        offset = uint8(bound(offset, 0, MAX_OFFSET));
        supply = bound(supply, 1, MAX_AMOUNT);
        total0 = bound(total0, 0, MAX_AMOUNT);
        total1 = bound(total1, 0, MAX_AMOUNT);

        (uint256 up0, uint256 up1) = MultiAssetShareMath.convertToAmounts(0, total0, total1, supply, offset, true);
        (uint256 dn0, uint256 dn1) = MultiAssetShareMath.convertToAmounts(0, total0, total1, supply, offset, false);

        assertEq(up0, 0, "roundUp0 != 0");
        assertEq(up1, 0, "roundUp1 != 0");
        assertEq(dn0, 0, "roundDown0 != 0");
        assertEq(dn1, 0, "roundDown1 != 0");
    }

    /// @notice UPPER BOUND: a round-down conversion of the entire real supply can never claim
    ///         more than the real balance. The virtual offset (`supply + 10**offset` in the
    ///         denominator) plus the `+1` virtual asset in the numerator means the full real
    ///         supply maps strictly below `total + 1`; in particular it cannot drain `total`.
    ///         This is the inflation-defense guarantee that keeps the virtual position
    ///         un-withdrawable.
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_convertToAmounts_fullSupplyCannotOverdraw(uint256 total0, uint256 supply, uint8 offset)
        public
        pure
    {
        offset = uint8(bound(offset, 0, MAX_OFFSET));
        supply = bound(supply, 1, MAX_AMOUNT);
        total0 = bound(total0, 0, MAX_AMOUNT);

        // Round DOWN: amount = supply * (total0 + 1) / (supply + 10**offset). Since
        // supply < supply + 10**offset, amount < total0 + 1, i.e. amount <= total0.
        (uint256 amount,) = MultiAssetShareMath.convertToAmounts(supply, total0, 0, supply, offset, false);
        assertLe(amount, total0, "full-supply withdraw overdrew real balance");
    }

    // ───────────────────────────── bootstrapShares ─────────────────────────────

    /// @notice SQRT CORRECTNESS: `bootstrapShares == floor(sqrt(r0 * r1))`. Verified via the
    ///         defining inequalities `s*s <= p` and `p - s*s <= 2*s` (equivalent to
    ///         `p < (s+1)^2`), phrased to avoid overflowing `(s+1)^2`.
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_bootstrapShares_isFloorSqrt(uint128 r0, uint128 r1) public pure {
        uint256 p = uint256(r0) * uint256(r1); // (2^128-1)^2 < 2^256, safe
        uint256 s = MultiAssetShareMath.bootstrapShares(r0, r1);

        assertLe(s * s, p, "s*s > r0*r1");
        assertLe(p - s * s, 2 * s, "r0*r1 >= (s+1)^2");
    }

    /// @notice SYMMETRY: bootstrap shares do not depend on currency ordering.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_bootstrapShares_symmetric(uint128 r0, uint128 r1) public pure {
        assertEq(MultiAssetShareMath.bootstrapShares(r0, r1), MultiAssetShareMath.bootstrapShares(r1, r0), "asymmetric");
    }

    /// @notice MONOTONICITY: increasing one side never decreases bootstrap shares.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_bootstrapShares_monotonic(uint128 r1, uint128 r0Lo, uint128 r0Hi) public pure {
        if (r0Hi < r0Lo) (r0Lo, r0Hi) = (r0Hi, r0Lo);
        assertGe(
            MultiAssetShareMath.bootstrapShares(r0Hi, r1),
            MultiAssetShareMath.bootstrapShares(r0Lo, r1),
            "bootstrap shares not monotonic"
        );
    }

    /// @notice CROSS-CHECK against Solady's reference sqrt on the raw product.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_bootstrapShares_matchesReferenceSqrt(uint128 r0, uint128 r1) public pure {
        uint256 p = uint256(r0) * uint256(r1);
        assertEq(MultiAssetShareMath.bootstrapShares(r0, r1), FixedPointMathLib.sqrt(p), "diverged from reference sqrt");
    }
}
