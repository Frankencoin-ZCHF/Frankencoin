// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Inventory} from "../types/Inventory.sol";

/// @title SettlementLib
/// @author Uniswap Labs
/// @notice Single net-delta settlement authority for ALF hooks that custody an `Inventory`.
///         Under v4 flash accounting every currency delta must net to zero before an `unlock`
///         finalizes, so only one actor may call `settle`, `take`, `mint`, or `burn` for delta
///         resolution. That actor is this library. Composed capabilities do not settle
///         themselves: they mutate their `Inventory` partition (deposit, withdraw, fee skim), and
///         {resolveCurrency} settles or parks the resulting net delta once per currency.
///
///         Routing all resolution through one function lets several fund-touching capabilities
///         share a hook. Each records its effect as a partition adjustment, and a single resolve
///         nets the combined position, so no two capabilities write the same `currencyDelta`.
///
///         ## Resolution
///
///         For each currency, after the cycle's operations complete:
///           - negative delta (hook owes the PoolManager): settle from the hook's raw balance
///             (sync, transfer, settle; or sync + `settle{value}` for native ETH) and debit the partition's
///             raw ledger.
///           - positive delta (PoolManager owes the hook): the swapper has not settled yet, so
///             mint ERC-6909 claims rather than calling `take`, and record them on the partition.
///             The claims redeem to raw on the next cycle via `InventoryLib.redeemClaims`.
///
///         Internal library functions inline into the consumer, so `address(this)` and token
///         custody resolve to the consuming hook. The `Inventory` is passed by storage reference
///         from the field the consumer holds.
/// @custom:security-contact security@uniswap.org
library SettlementLib {
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;

    /// @notice Resolve the hook's net delta for a single `currency` against an `Inventory` partition:
    ///         settle a debit from the partition's raw balance, or mint claims for a credit.
    /// @dev MUST be called inside the v4 unlock once the cycle's operations are complete, and is
    ///      the ONLY delta-resolution path that touches `settle` / `mint`. A negative delta settles
    ///      `owed` of the hook's raw balance and debits the partition (reverts
    ///      `InsufficientPoolBalance` if the partition's raw ledger is short). A positive delta mints
    ///      ERC-6909 claims (rather than `take`, since the swapper's input is not yet settled) and
    ///      records them on the partition.
    /// @dev `delta == 0` is a no-op: neither branch is taken, nothing is owed in either direction,
    ///      and the partition is left untouched.
    /// @param inventory   The consumer's `Inventory` storage; the partition's raw ledger and claim
    ///                    counter are updated here.
    /// @param poolManager The v4 PoolManager to settle against.
    /// @param partition      The `Inventory` accounting partition backing this (pool, currency).
    /// @param currency    The currency whose net delta to resolve.
    function resolveCurrency(
        Inventory storage inventory,
        IPoolManager poolManager,
        bytes32 partition,
        Currency currency
    ) internal {
        int256 delta = poolManager.currencyDelta(address(this), currency);
        if (delta < 0) {
            uint256 owed = uint256(-delta);
            if (currency.isAddressZero()) {
                // Reset the synced currency to native before settling value, so a different
                // currency left synced-but-unsettled earlier in this unlock cannot misattribute
                // the settled amount. Mirrors the unconditional sync in v4-periphery DeltaResolver.
                poolManager.sync(currency);
                poolManager.settle{value: owed}();
            } else {
                poolManager.sync(currency);
                currency.transfer(address(poolManager), owed);
                poolManager.settle();
            }
            inventory.debitERC20(partition, owed);
        } else if (delta > 0) {
            uint256 amount = uint256(delta);
            poolManager.mint(address(this), currency.toId(), amount);
            // The `toUint128` inside `recordClaims` is the only magnitude backstop on this path;
            // real v4 deltas are bounded by pool reserves and never approach `uint128.max`.
            inventory.recordClaims(partition, amount);
        }
    }
}
