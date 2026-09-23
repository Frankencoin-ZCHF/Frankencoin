// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @dev A debit was attempted against a maker balance that cannot cover it. Posting a bin,
///      settling a removal shortfall, and withdrawing inventory all debit through this path.
/// @param maker    The maker whose balance was insufficient.
/// @param currency The currency being debited.
/// @param available The maker's current balance.
/// @param required  The amount the debit needed.
error InsufficientInventory(address maker, Currency currency, uint256 available, uint256 required);

/// @title MakerInventory
/// @author Uniswap Labs
/// @notice Maker-scoped internal custody ledger for NativeBook hooks, as a type-driven value.
///         Makers pre-fund quoting inventory with {credit} (backed by an ERC-20 transfer the
///         consumer performs), bins consume it via {debit} when posted, and removal or fee
///         proceeds return via {credit}. Distinct from the pool-scoped `Inventory` settlement
///         type: this ledger tracks which maker owns the hook-held ERC-20, not what the hook
///         owes the PoolManager.
/// @param _inner Per-maker, per-currency balances.
/// @custom:security-contact security@uniswap.org
struct MakerInventory {
    mapping(address maker => mapping(Currency currency => uint256)) _inner;
}

using {balanceOf, credit, debit} for MakerInventory global;

/// @notice Read `maker`'s balance of `currency`.
/// @param self     MakerInventory storage.
/// @param maker    The maker to read.
/// @param currency The currency to read.
/// @return The maker's internal balance.
function balanceOf(MakerInventory storage self, address maker, Currency currency) view returns (uint256) {
    return self._inner[maker][currency];
}

/// @notice Increase `maker`'s balance of `currency` by `amount`.
/// @dev The consumer is responsible for the backing asset movement (inbound ERC-20 transfer or
///      PoolManager take) before crediting.
/// @param self     MakerInventory storage.
/// @param maker    The maker to credit.
/// @param currency The currency to credit.
/// @param amount   The amount to credit.
function credit(MakerInventory storage self, address maker, Currency currency, uint256 amount) {
    self._inner[maker][currency] += amount;
}

/// @notice Decrease `maker`'s balance of `currency` by `amount`.
/// @dev Reverts {InsufficientInventory} when the balance cannot cover the debit.
/// @param self     MakerInventory storage.
/// @param maker    The maker to debit.
/// @param currency The currency to debit.
/// @param amount   The amount to debit.
function debit(MakerInventory storage self, address maker, Currency currency, uint256 amount) {
    uint256 available = self._inner[maker][currency];
    if (available < amount) revert InsufficientInventory(maker, currency, available, amount);
    unchecked {
        self._inner[maker][currency] = available - amount;
    }
}
