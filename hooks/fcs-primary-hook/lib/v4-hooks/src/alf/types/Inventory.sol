// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {InventoryLib} from "../libraries/InventoryLib.sol";

using CurrencyLibrary for Currency;
using SafeCast for uint256;

/// @dev {debitERC20} was asked to pay more than the partition's tracked ERC-20 balance.
error InsufficientPoolBalance();

/// @notice Emitted when a vault is bound to a partition via {setVault} (`address(0)` unbinds to raw ERC-20).
/// @param partition The accounting partition reconfigured.
/// @param vault  The ERC-4626 vault now bound to the partition.
event VaultBound(bytes32 indexed partition, IERC4626 vault);

/// @notice Packed per-partition ERC-20 + ERC-6909 claim balance.
/// @dev Co-located in one 32-byte slot so the pair-aware paths read both with a single SLOAD.
///      `uint128` per field dwarfs any plausible per-partition amount; writes SafeCast.
/// @param erc20  Raw ERC-20 tokens (in the token's native decimals) attributed to the partition.
/// @param claims ERC-6909 claims on the PoolManager (token's native decimals) for the partition.
struct CurrencyState {
    uint128 erc20;
    uint128 claims;
}

/// @title Inventory
/// @author Uniswap Labs
/// @notice Rehypothecation + claim-accounting capability for ALF hooks, as a type-driven value.
///         Tracks three asset sources per opaque `bytes32 partition`:
///
///           1. ERC-4626 vault shares: assets rehypothecated into yield-bearing vaults between
///              swaps, isolated per partition so deployments sharing a vault contract cannot consume
///              each other's shares.
///           2. ERC-6909 claims: deferred-settlement credits minted on the PoolManager when a
///              positive hook delta cannot yet be `take`n; redeemed via `InventoryLib.redeemClaims`.
///           3. Raw ERC-20: tokens held directly by the consuming contract, attributed per partition.
///              The source of truth for ownership; the contract's global `balanceOf` is never read
///              for accounting decisions.
///
///         ## Type-driven composition
///
///         The consumer holds an `Inventory` as a plain storage field and calls behavior on it
///         directly, as `_inventory.assetBalance(partition)`. The pure, context-free operations
///         (accessors, balance views, claim accounting) live here as file-level free functions
///         bound `using { ... } for Inventory global`. The operations
///         that need the consumer's execution context (`address(this)` for vault
///         `deposit`/`withdraw`/`redeem`, `maxWithdraw` sizing in `effectiveBalance`, PoolManager
///         `take`/`burn`, allowance checks) live in `InventoryLib`, a library whose internal
///         functions inline into the consumer so `this` resolves correctly. Both are invoked
///         uniformly as `_inventory.method(...)`.
///
///         ## Partition key
///
///         `partition` is opaque and consumer-defined: the accounting partition, distinct from the
///         asset (`currency`). `PoolVault` uses `keccak256(poolId, currency)`; a token-keyed
///         consumer uses `bytes32(uint256(uint160(token)))`. Functions that touch tokens take
///         `currency` separately because the partition alone does not name the underlying asset.
///
///         ## Compatibility
///
///         Vault interaction is via the ERC-4626 interface only. Effective-liquidity sizing
///         (`InventoryLib.effectiveBalance`) reads `maxWithdraw` first, the vault's own answer
///         to "how much can this owner withdraw atomically right now", and falls back to
///         `previewRedeem` for vaults that return a `0` sentinel from `maxWithdraw`
///         (curated/gated vaults like Morpho VaultV2). Liquidity-gated vaults whose
///         `previewRedeem` reverts when idle liquidity cannot cover the amount (Spark savings
///         vaults) are sized by `maxWithdraw` alone. Fee-on-entry/exit vaults are rejected by
///         `InventoryLib.requireFeelessVault`; fee-on-transfer / rebasing underlyings are not
///         supported.
/// @param vault       The ERC-4626 vault bound to a partition (`address(0)` = hold as raw ERC-20).
/// @param vaultShares The number of vault shares the partition owns.
/// @param state       The partition's packed raw ERC-20 + ERC-6909 claim balances.
/// @custom:security-contact security@uniswap.org
struct Inventory {
    mapping(bytes32 partition => IERC4626 vault) vault;
    mapping(bytes32 partition => uint256 shares) vaultShares;
    mapping(bytes32 partition => CurrencyState) state;
}

using InventoryLib for Inventory global;
using {
    vaultOf,
    setVault,
    sharesOf,
    erc20Of,
    claimsOf,
    assetBalance,
    unbackedClaims,
    recordClaims,
    debitERC20
} for Inventory global;

// ─────────────────────────────────────── Partition accessors ──────────────────────────────────────

/// @notice The ERC-4626 vault bound to `partition`, or `address(0)` if held as raw ERC-20.
/// @param self   Capability storage.
/// @param partition The accounting partition to read.
/// @return The vault bound to the partition, or the zero vault if none.
function vaultOf(Inventory storage self, bytes32 partition) view returns (IERC4626) {
    return self.vault[partition];
}

/// @notice Bind `vault` to `partition`. Caller validates the vault matches the currency.
/// @param self   Capability storage.
/// @param partition The accounting partition to configure.
/// @param vault  The ERC-4626 vault to bind (`address(0)` to hold the currency as raw ERC-20).
function setVault(Inventory storage self, bytes32 partition, IERC4626 vault) {
    self.vault[partition] = vault;
    emit VaultBound(partition, vault);
}

/// @notice ERC-4626 shares this partition owns.
/// @param self   Capability storage.
/// @param partition The accounting partition to read.
/// @return The vault share count held for the partition.
function sharesOf(Inventory storage self, bytes32 partition) view returns (uint256) {
    return self.vaultShares[partition];
}

/// @notice Raw ERC-20 attributed to this partition.
/// @param self   Capability storage.
/// @param partition The accounting partition to read.
/// @return The raw ERC-20 balance (token's native decimals) attributed to the partition.
function erc20Of(Inventory storage self, bytes32 partition) view returns (uint256) {
    return self.state[partition].erc20;
}

/// @notice ERC-6909 claims attributed to this partition.
/// @param self   Capability storage.
/// @param partition The accounting partition to read.
/// @return The ERC-6909 claim balance (token's native decimals) attributed to the partition.
function claimsOf(Inventory storage self, bytes32 partition) view returns (uint256) {
    return self.state[partition].claims;
}

// ────────────────────────────────────────── Balances ───────────────────────────────────────────

/// @notice Gross managed balance: raw + claims + `convertToAssets(shares)`.
/// @dev The vault leg is the true per-share economic value, ignoring exit fees or temporary
///      throttles. Used by LP share math so claims are over true economic stake. Contrast
///      `InventoryLib.effectiveBalance`, which sizes the vault leg at its immediately-withdrawable
///      value (it lives in `InventoryLib` because that sizing reads `maxWithdraw(address(this))`,
///      and free functions cannot access `this`).
/// @param self   Capability storage.
/// @param partition The accounting partition to value.
/// @return bal The gross managed balance (token's native decimals).
function assetBalance(Inventory storage self, bytes32 partition) view returns (uint256 bal) {
    CurrencyState storage s = self.state[partition];
    bal = uint256(s.erc20) + uint256(s.claims);
    IERC4626 vault = self.vault[partition];
    if (address(vault) != address(0)) {
        uint256 shares = self.vaultShares[partition];
        if (shares > 0) bal += vault.convertToAssets(shares);
    }
}

// ─────────────────────────────────────────── Claims ────────────────────────────────────────────

/// @notice The portion of the partition's claims the PoolManager cannot physically honor yet.
/// @dev Claims whose backing settle is still pending this tx. Returns 0 in the common,
///      fully-backed case. Reads the PoolManager's balance (`pm`), not the consumer's, so it has
///      no `address(this)` dependency.
/// @param self     Capability storage.
/// @param partition   The accounting partition to inspect.
/// @param currency The underlying asset of the claims.
/// @param pm       The v4 PoolManager whose balance bounds the backed portion.
/// @return The unbacked claim amount (token's native decimals).
function unbackedClaims(Inventory storage self, bytes32 partition, Currency currency, IPoolManager pm)
    view
    returns (uint256)
{
    uint256 claims = self.state[partition].claims;
    if (claims == 0) return 0;
    uint256 available = currency.balanceOf(address(pm));
    return claims > available ? claims - available : 0;
}

/// @notice Record newly-minted ERC-6909 claims for a partition (after `pm.mint`).
/// @param self   Capability storage.
/// @param partition The accounting partition to credit.
/// @param amount The claim amount minted (token's native decimals).
function recordClaims(Inventory storage self, bytes32 partition, uint256 amount) {
    CurrencyState storage s = self.state[partition];
    s.claims = (uint256(s.claims) + amount).toUint128();
}

/// @notice Debit `amount` from the partition's raw ERC-20 after a PM settlement.
/// @dev The `_settle` itself is the consumer's responsibility; this only updates the per-partition
///      counter. Reverts {InsufficientPoolBalance} if the partition is short.
/// @param self   Capability storage.
/// @param partition The accounting partition to debit.
/// @param amount The raw amount settled away (token's native decimals).
function debitERC20(Inventory storage self, bytes32 partition, uint256 amount) {
    if (amount == 0) return;
    CurrencyState storage s = self.state[partition];
    uint256 bal = s.erc20;
    if (bal < amount) revert InsufficientPoolBalance();
    // bare cast is safe: `bal` is read from a uint128 field, so `bal - amount < 2**128`.
    s.erc20 = uint128(bal - amount);
}
