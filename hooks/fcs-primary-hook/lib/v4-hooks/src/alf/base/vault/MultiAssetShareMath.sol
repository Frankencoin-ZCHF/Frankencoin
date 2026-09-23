// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title MultiAssetShareMath
/// @author Uniswap Labs
/// @notice Pure share-math helpers for the `Shares` ledger. Extracted so peripheral
///         contracts (aggregator routers, off-chain quote helpers, alternative vault
///         implementations) can compute the same conversions without touching the
///         ledger's storage.
///
///         Implements the EIP-4626 virtual-shares pattern in two-asset form. The vault
///         conversion has a bounded share/asset ratio: every read adds `1` virtual asset
///         to each side and `10**decimalsOffset` virtual shares to supply. The virtual
///         position can never withdraw, so any post-bootstrap inflation attempt
///         (e.g., a donation that surfaces through `_assetBalance`) is captured
///         proportionally by it, making such attacks uneconomic regardless of bootstrap
///         size.
///
///         All functions are `internal pure` and stateless. The conversion helpers
///         ({convertToAmounts}) are overflow-safe via Solady's 512-bit `fullMulDiv` /
///         `fullMulDivUp`; {bootstrapShares} carries its own overflow precondition documented
///         on that function (its `received0 * received1` product is a plain checked multiply).
/// @custom:security-contact security@uniswap.org
library MultiAssetShareMath {
    /// @notice Convert a share count to the equivalent two-asset amounts at the current
    ///         vault state, applying virtual-shares offsets.
    ///
    ///         Formula (per asset):
    ///             amount = shares * (total + 1) / (supply + 10**decimalsOffset)
    ///
    /// @param shares          The number of shares to convert.
    /// @param total0          Real asset0 balance (output of `_assetBalance` for asset 0).
    /// @param total1          Real asset1 balance.
    /// @param supply          Real share supply (`Shares.totalSupply(vaultId)`).
    /// @param decimalsOffset  Virtual-shares decimal offset (typically 12).
    /// @param roundUp         True for deposits (round up to prevent dilution), false for
    ///                        withdrawals (round down to prevent over-withdrawal).
    /// @return amount0 The asset0 amount equivalent to `shares`.
    /// @return amount1 The asset1 amount equivalent to `shares`.
    function convertToAmounts(
        uint256 shares,
        uint256 total0,
        uint256 total1,
        uint256 supply,
        uint8 decimalsOffset,
        bool roundUp
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        uint256 effSupply = supply + 10 ** decimalsOffset;
        if (roundUp) {
            amount0 = FixedPointMathLib.fullMulDivUp(shares, total0 + 1, effSupply);
            amount1 = FixedPointMathLib.fullMulDivUp(shares, total1 + 1, effSupply);
        } else {
            amount0 = FixedPointMathLib.fullMulDiv(shares, total0 + 1, effSupply);
            amount1 = FixedPointMathLib.fullMulDiv(shares, total1 + 1, effSupply);
        }
    }

    /// @notice Bootstrap shares for the first deposit at the bootstrapper-chosen ratio:
    ///         `sqrt(received0 * received1)` (Uniswap V2 style). Uses Solady's overflow-
    ///         safe integer sqrt.
    /// @dev    `received0 * received1` is a plain checked multiply (not `fullMulDiv`); it panics
    ///         on overflow. Precondition: `received0 * received1 < 2**256`. This is unreachable
    ///         for real inventory because both inputs originate from uint128-packed balances, so
    ///         the product is at most `2**256 - 2**129 + 1 < 2**256`. The sqrt itself cannot
    ///         overflow once the product fits in uint256.
    /// @dev    Returns 0 if `received0 * received1 == 0`; the caller should treat that as
    ///         "insufficient bootstrap."
    function bootstrapShares(uint256 received0, uint256 received1) internal pure returns (uint256) {
        return FixedPointMathLib.sqrt(received0 * received1);
    }
}
