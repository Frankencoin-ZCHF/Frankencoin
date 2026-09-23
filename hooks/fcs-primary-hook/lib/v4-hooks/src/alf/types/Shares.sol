// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MultiAssetShareMath} from "../base/vault/MultiAssetShareMath.sol";
import {VaultId} from "./VaultId.sol";

/// @dev The caller attempted to burn more shares than the holder owns.
error InsufficientShares();
/// @dev A share operation read or mutated a vault that has not been bootstrapped (`totalShares == 0`).
error VaultNotBootstrapped();
/// @dev Bootstrap was attempted on a vault that already holds shares.
error VaultAlreadyBootstrapped();
/// @dev {bindAssets} was called on a vault whose asset pair is already bound. The pair is fixed for
///      the vault's lifetime, so re-binding is rejected.
error AssetsAlreadyBound();
/// @dev Bootstrap amounts produce zero shares (one or both received amounts is zero).
error InsufficientBootstrap();
/// @dev A withdrawal arrived before the depositor's lock elapsed
///      (`blockNumber < lastDepositBlock + minDepositBlocks`). Defends against atomic
///      deposit-swap-withdraw fee/yield sniping.
/// @param unlockBlock The clock block at which the lock clears.
error DepositLocked(uint256 unlockBlock);
/// @dev Bootstrap shares (`sqrt(received0 * received1)`) are below the inflation-defense floor of
///      `100 * 10**offset`. Below this floor the bootstrapper permanently loses more than ~1% of
///      their seed capital to the virtual position, so operators MUST seed larger amounts.
/// @param sharesMinted The bootstrap shares the operator's amounts would have produced.
/// @param minShares    The minimum shares the offset requires (`100 * 10**offset`).
error BootstrapTooSmall(uint256 sharesMinted, uint256 minShares);

/// @notice The asset pair backing a vault, bound at bootstrap and immutable thereafter.
/// @param asset0 First asset (subclass-defined identifier; PoolVault uses the unwrapped currency).
/// @param asset1 Second asset.
struct Assets {
    address asset0;
    address asset1;
}

/// @title Shares
/// @author Uniswap Labs
/// @notice Two-asset proportional share ledger as a type-driven value. Tracks non-transferable
///         shares of an abstract `(asset0, asset1)` pair indexed by an opaque `VaultId`: there is
///         no ERC-20 share token, only internal accounting. A consumer holds a `Shares` storage
///         field and drives it through the free functions below; the consumer owns the lifecycle
///         (asset I/O, accrual checkpoints, the block clock, and the per-vault offset/lock config),
///         while this type owns the ledger state, the conversion math, and the ledger invariants.
///
///         ## Inflation defense
///
///         Conversion uses the EIP-4626 virtual-shares pattern:
///
///             amount = shares * (total + 1) / (supply + 10**offset)
///
///         The `+1` virtual asset per side and `+10**offset` virtual shares exist only in the math;
///         they hold no real entry and can never withdraw. They mitigate post-bootstrap donation
///         attacks: a direct donation to any balance source the consumer reports through the
///         conversion's `bal0`/`bal1` inputs is captured proportionally by the virtual position,
///         making such attacks uneconomic regardless of bootstrap size.
///
///         ## Bootstrap drift
///
///         The bootstrapper's economic claim is `S / (S + 10**offset)` where
///         `S = sqrt(received0 * received1)`. When `S` is comparable to or smaller than
///         `10**offset`, the bootstrapper permanently loses a meaningful fraction of their seed to
///         the virtual position. With `offset = 12`:
///
///             | Bootstrap (each side, 6dec)  | shares S | drift |
///             |------------------------------|---------:|------:|
///             | 1 USDC (1e6 wei)             |    1e6   |   ~1  |
///             | 1k USDC (1e9 wei)            |    1e9   |  ~99% |
///             | 1M USDC (1e12 wei)           |    1e12  |   50% |
///             | 100M USDC (1e14 wei)         |    1e14  | 1ppm  |
///             | Bootstrap (each side, 18dec) | shares S | drift |
///             | 1 token (1e18 wei)           |    1e18  | 1ppb  |
///             | 1k token (1e21 wei)          |    1e21  |  ~0   |
///
///         For ~ppm-or-better drift, operators MUST seed with `S >= 100 * 10**offset`. The
///         {creditBootstrap} caller enforces this floor with {BootstrapTooSmall}. Consumers serving
///         low-decimal pairs SHOULD lower the offset they pass to {convertToAmounts} and the floor
///         (e.g. 6 for stablecoin pairs).
///
/// @dev    This type is reentrancy-agnostic and makes no external calls: every function is pure
///         ledger math over storage. The consumer guards its own entry points and orders the
///         lifecycle effects-first (mutating share counters before asset I/O) so a reentrant view
///         path observes a coherent snapshot.
/// @param assets          The bootstrap-bound asset pair per vault.
/// @param totalShares     Real shares outstanding per vault. Conversion adds virtual shares on top.
/// @param userShares      Real shares per `(vault, user)`. Numerator of a user's proportional claim.
/// @param lastDepositBlock Block of the last deposit per `(vault, user)`, on the consumer's clock.
/// @custom:security-contact security@uniswap.org
struct Shares {
    mapping(VaultId vaultId => Assets) assets;
    mapping(VaultId vaultId => uint256) totalShares;
    mapping(VaultId vaultId => mapping(address user => uint256)) userShares;
    mapping(VaultId vaultId => mapping(address user => uint256)) lastDepositBlock;
}

using {
    totalSupply,
    balanceOf,
    assetPair,
    convertToAmounts,
    requireBootstrapped,
    requireNotBootstrapped,
    requireBalance,
    checkUnlocked,
    bindAssets,
    creditBootstrap,
    mint,
    burn
} for Shares global;

/// @notice Real shares outstanding for a vault, across all holders. Excludes the virtual shares
///         that {convertToAmounts} adds for inflation defense.
/// @param self    Shares ledger storage.
/// @param vaultId The vault to read.
/// @return The real share supply.
function totalSupply(Shares storage self, VaultId vaultId) view returns (uint256) {
    return self.totalShares[vaultId];
}

/// @notice Share balance for `(vaultId, user)`.
/// @param self    Shares ledger storage.
/// @param vaultId The vault to read.
/// @param user    The account to read.
/// @return The holder's share balance.
function balanceOf(Shares storage self, VaultId vaultId, address user) view returns (uint256) {
    return self.userShares[vaultId][user];
}

/// @notice The asset pair bound to a vault at bootstrap.
/// @param self    Shares ledger storage.
/// @param vaultId The vault to read.
/// @return The `(asset0, asset1)` pair (zero addresses if never bootstrapped).
function assetPair(Shares storage self, VaultId vaultId) view returns (Assets memory) {
    return self.assets[vaultId];
}

/// @notice Convert a share count to the equivalent two-asset amounts at the supplied balances,
///         applying the virtual-shares offset. Deposits round up (depositor pays slightly more,
///         preventing dilution); withdrawals round down (withdrawer receives slightly less,
///         preventing over-withdrawal at remaining holders' expense).
/// @dev    The consumer supplies `bal0`/`bal1` (the total managed balance per asset) because the
///         balance sources live outside this type. Reverts {VaultNotBootstrapped} when the supply
///         is zero: a pre-bootstrap vault has no defined ratio.
/// @param self    Shares ledger storage.
/// @param vaultId The vault whose supply sets the denominator.
/// @param bal0    Total managed asset0 balance.
/// @param bal1    Total managed asset1 balance.
/// @param offset  Virtual-shares decimal offset for the inflation defense.
/// @param shares  The share count to convert.
/// @param roundUp True to round up (deposit), false to round down (withdraw).
/// @return amount0 The asset0 amount equivalent to `shares`.
/// @return amount1 The asset1 amount equivalent to `shares`.
function convertToAmounts(
    Shares storage self,
    VaultId vaultId,
    uint256 bal0,
    uint256 bal1,
    uint8 offset,
    uint256 shares,
    bool roundUp
) view returns (uint256 amount0, uint256 amount1) {
    uint256 supply = self.totalShares[vaultId];
    if (supply == 0) revert VaultNotBootstrapped();
    return MultiAssetShareMath.convertToAmounts(shares, bal0, bal1, supply, offset, roundUp);
}

/// @notice Revert {VaultNotBootstrapped} unless the vault has shares.
/// @param self    Shares ledger storage.
/// @param vaultId The vault to check.
function requireBootstrapped(Shares storage self, VaultId vaultId) view {
    if (self.totalShares[vaultId] == 0) revert VaultNotBootstrapped();
}

/// @notice Revert {VaultAlreadyBootstrapped} if the vault already has shares.
/// @param self    Shares ledger storage.
/// @param vaultId The vault to check.
function requireNotBootstrapped(Shares storage self, VaultId vaultId) view {
    if (self.totalShares[vaultId] != 0) revert VaultAlreadyBootstrapped();
}

/// @notice Revert {InsufficientShares} unless `user` holds at least `shares`.
/// @param self    Shares ledger storage.
/// @param vaultId The vault to check.
/// @param user    The holder whose balance gates the burn.
/// @param shares  The share count the caller intends to burn.
function requireBalance(Shares storage self, VaultId vaultId, address user, uint256 shares) view {
    if (self.userShares[vaultId][user] < shares) revert InsufficientShares();
}

/// @notice Revert {DepositLocked} if `user`'s deposit lock has not elapsed on the consumer's clock.
/// @dev    The lock spans `[lastDepositBlock, lastDepositBlock + minBlocks)`. `minBlocks == 0`
///         disables the lock (same-block deposit-then-withdraw allowed); `1` reproduces a
///         same-block ban; `N > 1` enforces an `N`-block hold.
/// @param self      Shares ledger storage.
/// @param vaultId   The vault to check.
/// @param user      The holder whose last-deposit block gates the withdrawal.
/// @param minBlocks The lock duration in the consumer's clock blocks.
/// @param nowBlock  The current block on the consumer's clock.
function checkUnlocked(Shares storage self, VaultId vaultId, address user, uint64 minBlocks, uint256 nowBlock) view {
    uint256 unlockBlock = self.lastDepositBlock[vaultId][user] + minBlocks;
    if (nowBlock < unlockBlock) revert DepositLocked(unlockBlock);
}

/// @notice Bind the asset pair for a vault. The consumer calls this once at bootstrap, before
///         pulling assets, so the pair is fixed for the vault's lifetime.
/// @dev    Reverts {AssetsAlreadyBound} on a re-bind so the immutability the NatSpec promises is
///         enforced rather than assumed. Bootstrap calls this exactly once on an empty vault, so
///         the guard is a no-op on the happy path.
/// @param self    Shares ledger storage.
/// @param vaultId The vault to bind.
/// @param asset0  First asset.
/// @param asset1  Second asset.
function bindAssets(Shares storage self, VaultId vaultId, address asset0, address asset1) {
    if (self.assets[vaultId].asset0 != address(0)) revert AssetsAlreadyBound();
    self.assets[vaultId] = Assets({asset0: asset0, asset1: asset1});
}

/// @notice Compute the bootstrap share supply from received amounts and enforce the
///         inflation-defense floor. A bootstrap mints `sqrt(received0 * received1)` (V2-style).
/// @dev Reverts {InsufficientBootstrap} when the geometric mean rounds to zero, and
///      {BootstrapTooSmall} when it falls below `100 * 10**offset` (~1% drift). Below the floor the
///      bootstrapper permanently loses non-trivial seed capital to the EIP-4626 virtual position,
///      and a later attacker can cheaply capture the remainder via small deposits (the virtual-share
///      defense protects future depositors from each other, not the bootstrapper themselves). Pure
///      policy, co-located with the ledger that {creditBootstrap} writes.
/// @param received0 Token0 actually received by the vault (post FoT/rebasing reconciliation).
/// @param received1 Token1 actually received by the vault.
/// @param offset    The vault's decimals offset, which sets the floor scale.
/// @return sharesMinted The bootstrap share supply to credit.
function computeBootstrapShares(uint256 received0, uint256 received1, uint8 offset)
    pure
    returns (uint256 sharesMinted)
{
    sharesMinted = MultiAssetShareMath.bootstrapShares(received0, received1);
    if (sharesMinted == 0) revert InsufficientBootstrap();
    uint256 minShares = 100 * 10 ** uint256(offset);
    if (sharesMinted < minShares) revert BootstrapTooSmall(sharesMinted, minShares);
}

/// @notice Credit the full bootstrap supply to `to` and stamp their deposit block. Sets both the
///         total and the holder balance to `sharesMinted` (a bootstrap mints into an empty vault).
/// @param self         Shares ledger storage.
/// @param vaultId      The vault being bootstrapped.
/// @param to           The account credited with the bootstrap shares.
/// @param sharesMinted The bootstrap shares to credit.
/// @param nowBlock     The current block on the consumer's clock, stamped as the last deposit.
function creditBootstrap(Shares storage self, VaultId vaultId, address to, uint256 sharesMinted, uint256 nowBlock) {
    self.totalShares[vaultId] = sharesMinted;
    self.userShares[vaultId][to] = sharesMinted;
    self.lastDepositBlock[vaultId][to] = nowBlock;
}

/// @notice Mint `shares` to `to` and stamp their deposit block. Increments both the total and the
///         holder balance. The consumer must have already verified the vault is bootstrapped.
/// @param self    Shares ledger storage.
/// @param vaultId The vault receiving the mint.
/// @param to      The account credited with the minted shares.
/// @param shares  The share count to mint.
/// @param nowBlock The current block on the consumer's clock, stamped as the last deposit.
function mint(Shares storage self, VaultId vaultId, address to, uint256 shares, uint256 nowBlock) {
    self.totalShares[vaultId] += shares;
    self.userShares[vaultId][to] += shares;
    self.lastDepositBlock[vaultId][to] = nowBlock;
}

/// @notice Burn `shares` from `from`, decrementing both the total and the holder balance.
/// @dev    Does not range-check `shares`; the consumer calls {requireBalance} first so the
///         decrement cannot underflow, matching the holder-balance invariant
///         (`userShares <= totalShares`).
/// @param self    Shares ledger storage.
/// @param vaultId The vault the burn debits.
/// @param from    The account whose shares are burned.
/// @param shares  The share count to burn.
function burn(Shares storage self, VaultId vaultId, address from, uint256 shares) {
    self.totalShares[vaultId] -= shares;
    self.userShares[vaultId][from] -= shares;
}
