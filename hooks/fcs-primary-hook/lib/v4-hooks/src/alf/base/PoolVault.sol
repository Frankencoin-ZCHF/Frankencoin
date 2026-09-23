// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BlockNumberish} from "@uniswap/blocknumberish/src/BlockNumberish.sol";
import {VaultId} from "../types/VaultId.sol";
import {Shares, Assets, InsufficientBootstrap, computeBootstrapShares} from "../types/Shares.sol";
import {Inventory} from "../types/Inventory.sol";
import {InventoryLib} from "../libraries/InventoryLib.sol";

/// @title PoolVault
/// @author Uniswap Labs
///
/// @notice Uniswap v4 hook base for two-asset proportional share accounting. Owns the
///         bootstrap/deposit/withdraw lifecycle and the V4-specific concerns: ERC-4626 vault
///         rehypothecation, ERC-6909 PoolManager claim handling, and per-pool tracking of raw
///         ERC-20 attributed to the hook contract.
///
///         The share ledger and conversion math live in the `Shares` type (the `_shares` field):
///         non-transferable shares, the EIP-4626 virtual-shares inflation defense, and the
///         deposit-lock invariant. PoolVault drives that ledger through the lifecycle below,
///         supplying the pieces the type cannot: asset I/O (`_pullAsset` / `_pushAsset` over V4
///         currencies and rehypothecation), the managed balances fed to the conversion, the
///         per-pool decimals offset and lock duration, the `BlockNumberish` clock, and the
///         `_onShareCheckpoint` accrual seam a composed capability overrides. It exposes
///         `PoolKey`-flavored entry points so subclasses (e.g., DualPoolHook) integrate
///         naturally.
///
///         For every `(PoolId, Currency)`, PoolVault tracks three asset sources:
///
///           1. **ERC4626 vault shares**: assets rehypothecated into yield-bearing vaults
///              between swaps. Tracked per-pool via `_vaultShares` to isolate multi-pool
///              deployments that share the same vault contract.
///
///           2. **ERC-6909 claims**: deferred settlement tokens minted on the PoolManager
///              when afterSwap produces a positive delta but the PM lacks ERC-20 (because the
///              swapper hasn't settled yet). Tracked per-pool via `_state.claims` and redeemed
///              in the next `_redeemPoolClaims`.
///
///           3. **Raw ERC-20**: tokens held directly by the hook, attributed per-pool via
///              `_state.erc20`. Source of truth for pool ownership; the hook's global
///              `balanceOf` is never read for accounting decisions.
///
///         ## Token Compatibility
///
///         Inbound transfers (user → hook) use OZ `SafeERC20.safeTransferFrom`. Outbound
///         (hook → user) uses v4-core's `Currency.transfer`. Vault approvals use
///         `forceApprove` for tokens that require zero-out-first.
///
///         **Native ETH is not supported**: subclasses must reject `address(0)` currencies
///         at pool initialization. PoolVault calls `IERC20.safeTransferFrom(address(0), ...)`
///         which would revert; the subclass-level rejection makes the failure mode explicit
///         at init.
///
///         ## Vault Compatibility
///
///         PoolVault interacts with the configured per-currency vault solely through the
///         ERC-4626 interface (`deposit`, `withdraw`, `convertToAssets`, `convertToShares`,
///         `previewRedeem`, `maxWithdraw`). Effective-liquidity sizing (`_effectiveAssets`)
///         reads `maxWithdraw(hook)` first: it is the vault's own answer to "how much can
///         this owner withdraw atomically right now", and it is the only sizing view that
///         liquidity-gated vaults (Spark savings vaults) support, since their
///         `previewRedeem` reverts whenever idle liquidity cannot cover the amount.
///         Curated/gated vaults such as Morpho VaultV2 instead return `0` from
///         `maxWithdraw` by construction because they cannot honestly bound a single-block
///         withdrawal cap across their internal allocations; for those the sizing falls
///         back to `previewRedeem(shares)`, the realizable exit value per share (net of
///         any exit fee). See `InventoryLib.realizableVaultAssets` for the exact
///         resolution order. On the execution paths (`_withdrawFromVault`, `_ensureERC20`)
///         `withdraw` remains optimistic: if the vault cannot satisfy the request from its
///         current allocation, the revert bubbles up through `_pushAsset` → swap callback
///         → `beforeSwap`. Routers and aggregators see an explicit failure and route
///         elsewhere.
///
///         For curated/gated vaults (Morpho VaultV2 and similar), the curator gate is an
///         accepted trust assumption: operators MUST select vaults whose curators they
///         trust not to enable a denial gate against the hook. See `_depositToVault` for
///         the broader vault-trust model.
///
///         **Fee-on-entry / fee-on-exit vaults are not supported** and are rejected at
///         pool initialization by `_requireFeelessVault`. Two reasons compound:
///
///           1. JIT-cycle bleed. Every swap does `_ensureERC20` (vault withdraw) → swap →
///              `_depositAllToVaults` (vault deposit). A vault with `f_in + f_out = 20bps`
///              of round-trip fee bleeds 20bps of the JIT-deployed notional per swap,
///              charged entirely to LPs. At typical hook utilization this dwarfs the LP
///              fee revenue.
///
///           2. LP share-math socialization. `_totalAssets` reads `convertToAssets`
///              (gross per EIP-4626), but actual `vault.deposit`/`vault.withdraw` net out
///              the fee. The mismatch is socialized: a depositor underpays the entry fee
///              (existing LPs subsidize), and a withdrawer over-extracts the gross
///              valuation (remaining LPs pay the exit fee). Manifests as a
///              first-out-wins / last-out-loses redemption race.
///
/// @dev    See `Shares` for the ledger + conversion math and `MultiAssetShareMath` for the pure
///         formulas. This contract binds them to V4: it translates `PoolKey` / `PoolId` /
///         `Currency` into the `Shares` ledger's `VaultId` / `address asset` plumbing, runs the
///         lifecycle effects-first (share counters move before asset I/O so reentrant view paths
///         see a coherent snapshot), and adds the V4-specific helpers (`_redeemPoolClaims`,
///         `_recordClaims`, `_debitPoolERC20`) that the JIT lifecycle in subclasses calls during
///         swap callbacks. This base is reentrancy-agnostic; subclasses guard their own entry
///         points (typically `nonReentrant` plus a JIT-cycle lock).
/// @custom:security-contact security@uniswap.org
abstract contract PoolVault is BlockNumberish {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════════
    //                              CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Default virtual-shares offset (also the upper clamp for the per-pool derivation).
    ///      Correct for 18-decimal pairs; the default offset when a pool derives none.
    uint8 private constant DEFAULT_DECIMALS_OFFSET = 12;

    /// @dev Lower clamp on the per-pool offset, keeping the inflation defense at >= `1e6`
    ///      virtual shares even for low-decimal pairs.
    uint8 private constant MIN_DECIMALS_OFFSET = 6;

    /// @dev Subtracted from a pair's average decimals so an 18/18 pair maps to the default 12.
    uint8 private constant DECIMALS_OFFSET_MARGIN = 6;

    /// @dev Assumed decimals for tokens that don't implement the optional `decimals()` metadata.
    uint8 private constant FALLBACK_DECIMALS = 18;

    // ═══════════════════════════════════════════════════════════════════════════
    //                              STATE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Rehypothecation + claim state (vault bindings, vault shares, raw ERC-20, and
    ///      ERC-6909 claims) composed as a type-driven `Inventory` storage field, keyed per
    ///      `(pool, currency)` by `_partition`. Behavior is attached via the file-level free
    ///      functions on `Inventory` (accessors, balances, claim accounting) plus the
    ///      `InventoryLib` library (token-custody ops), so the wrappers below call
    ///      `_inventory.method(...)` directly. PoolVault is
    ///      the V4 binding: it owns the partition derivation, re-exposes the `vaults` getter, and
    ///      delegates every asset/claim operation through thin `(PoolId, Currency)` wrappers
    ///      (`_vaultOf`, `_setVault`, `_depositToVault`, `_redeemPoolClaims`, ...) so subclasses
    ///      and the test harness keep their existing call surface. Aggregate views
    ///      (`_totalAssets`, `_effectiveAssets`) call `_inventory` directly.
    Inventory internal _inventory;

    /// @dev Two-asset proportional share ledger composed as a type-driven `Shares` storage field,
    ///      keyed per pool by `_vaultIdFor`. Holds the share supply, per-holder balances, the
    ///      bootstrap-bound asset pair, and last-deposit blocks; the EIP-4626 conversion math and
    ///      ledger invariants are attached via the file-level free functions on `Shares`. The
    ///      lifecycle (`_bootstrap` / `_deposit` / `_withdraw`) and the typed getters (`totalShares`,
    ///      `userShares`) drive it through `_shares.method(...)`.
    Shares internal _shares;

    /// @notice Per-pool minimum deposit-lock duration, measured in `BlockNumberish`-clock blocks.
    /// @dev    Returned by `_minDepositBlocks(VaultId)` and consumed by the `_withdraw` lock
    ///         guard (`Shares.checkUnlocked`). `0` means no lock (same-block withdraw allowed);
    ///         `1` reproduces the legacy same-block ban; `N > 1` requires `N` blocks to elapse
    ///         between the depositor's last `_deposit` and any `_withdraw`. Set at pool
    ///         initialization and immutable thereafter.
    mapping(PoolId => uint64) public minDepositBlocks;

    /// @dev Per-pool virtual-shares offset, derived from the pair's token decimals at pool
    ///      initialization and immutable thereafter. See {_decimalsOffset} and
    ///      {_initDecimalsOffset} for the rationale and formula. `0` means "not initialized",
    ///      which `_decimalsOffset` maps to the base default of 12.
    mapping(PoolId => uint8) internal _poolDecimalsOffset;

    // ═══════════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The JIT cycle's post-swap `vault.deposit` reverted (typically because the
    ///         vault's `maxDeposit` cap is reached, or a curated allocator declined). The
    ///         underlying ERC-20 stays in `_state.erc20` and is retried on the next swap.
    ///         LP share math remains correct because `_totalAssets` reads
    ///         `s.erc20 + s.claims + vault`; LPs forgo vault yield on the
    ///         non-deposited portion until the cap loosens or operator intervention.
    /// @param poolId   The pool whose afterSwap re-deposit was skipped.
    /// @param currency The currency whose vault rejected the deposit.
    /// @param amount   The asset amount that could not be deposited (kept in `s.erc20`).
    /// @param reason   The raw revert data from `vault.deposit` (for operator diagnostics).
    event VaultDepositSkipped(PoolId indexed poolId, Currency indexed currency, uint256 amount, bytes reason);

    /// @notice Emitted when `_drainVaultBestEffort` successfully pulls the pool's full vault
    ///         position back into the raw ERC-20 ledger (e.g. during an emergency revocation).
    /// @param poolId   The pool whose vault position was drained.
    /// @param currency The currency that was withdrawn from the vault.
    /// @param shares   The vault shares redeemed (the pool's full holding).
    /// @param assets   The asset amount received and credited to `s.erc20`.
    event VaultDrained(PoolId indexed poolId, Currency indexed currency, uint256 shares, uint256 assets);

    /// @notice Emitted when a best-effort vault drain could not complete (vault paused, bricked,
    ///         or otherwise reverting on redeem). The assets remain in the vault; the caller
    ///         continues so the surrounding action (e.g. allowance revocation + pause) still lands.
    /// @param poolId   The pool whose vault drain was skipped.
    /// @param currency The currency whose vault rejected the redeem.
    /// @param shares   The vault shares that could not be redeemed.
    /// @param reason   The raw revert data from `vault.redeem` (for operator diagnostics).
    event VaultDrainSkipped(PoolId indexed poolId, Currency indexed currency, uint256 shares, bytes reason);

    /// @notice Emitted on first deposit (bootstrap); sets the initial share/asset ratio.
    /// @param vaultId  The vault being bootstrapped.
    /// @param provider The address that received the bootstrap shares.
    /// @param shares   Total shares minted (`sqrt(received0 * received1)`).
    /// @param amount0  Asset0 transferred from the bootstrapper (post-FoT receipt).
    /// @param amount1  Asset1 transferred from the bootstrapper (post-FoT receipt).
    event Bootstrap(
        VaultId indexed vaultId, address indexed provider, uint256 shares, uint256 amount0, uint256 amount1
    );

    /// @notice Emitted when a depositor mints shares by providing proportional token amounts.
    /// @param vaultId  The vault receiving the deposit.
    /// @param provider The address that received the minted shares.
    /// @param shares   Shares minted to `provider`.
    /// @param amount0  Asset0 transferred from the depositor (post-FoT receipt).
    /// @param amount1  Asset1 transferred from the depositor (post-FoT receipt).
    event Deposit(VaultId indexed vaultId, address indexed provider, uint256 shares, uint256 amount0, uint256 amount1);

    /// @notice Emitted when a depositor burns shares and receives proportional token amounts.
    /// @param vaultId  The vault being withdrawn from.
    /// @param provider The address whose shares were burned.
    /// @param shares   Shares burned from `provider`.
    /// @param amount0  Asset0 transferred to the withdrawer.
    /// @param amount1  Asset1 transferred to the withdrawer.
    event Withdraw(VaultId indexed vaultId, address indexed provider, uint256 shares, uint256 amount0, uint256 amount1);

    /// @dev A deposit/bootstrap pull delivered fewer tokens than requested (typically a
    ///      fee-on-transfer or rebasing token). Shares are minted against the requested amount, so
    ///      accepting under-receipt would dilute existing holders; the pull paths reject it outright.
    error TransferReceiptShortfall();

    // Vault/claim errors (CrossPoolShareLeak, InsufficientPoolBalance, ZeroSharesMinted,
    // VaultChargesEntryFee, VaultChargesExitFee) are declared and reverted by `InventoryLib`.
    // Selectors are unchanged; callers that match on them reference `InventoryLib.<Error>`.
    // Share-ledger errors (InsufficientShares, VaultNotBootstrapped, VaultAlreadyBootstrapped,
    // DepositLocked, plus the bootstrap-floor InsufficientBootstrap / BootstrapTooSmall reverted
    // here) are declared at file level in `Shares`; callers match on the bare error names.

    // ═══════════════════════════════════════════════════════════════════════════
    //                  TYPED VIEWS (PoolKey / PoolId wrappers)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Total shares outstanding for a pool, across all depositors.
    /// @param poolId The pool whose share supply should be read.
    /// @return shares Total non-transferable pool shares outstanding.
    function totalShares(PoolId poolId) external view returns (uint256) {
        return _shares.totalSupply(_vaultIdFor(poolId));
    }

    /// @notice Share balance for `(poolId, user)`.
    /// @param poolId The pool whose share ledger should be read.
    /// @param user The account whose share balance should be read.
    /// @return shares Non-transferable pool shares held by `user`.
    function userShares(PoolId poolId, address user) external view returns (uint256) {
        return _shares.balanceOf(_vaultIdFor(poolId), user);
    }

    /// @notice The virtual-shares offset used by a pool's bootstrap floor and share-price
    ///         inflation defense (`100 * 10**offset` minimum bootstrap shares; `10**offset`
    ///         virtual shares in the conversion math). Derived from the pair's token decimals
    ///         at initialization. Useful for off-chain bootstrap sizing.
    /// @param poolId The pool to read the offset for.
    /// @return The pool's decimals offset (12 if the pool was never initialized).
    function decimalsOffset(PoolId poolId) external view returns (uint8) {
        return _decimalsOffset(_vaultIdFor(poolId));
    }

    /// @notice Returns the total managed assets for a pool across both currencies. Sums
    ///         vault assets (via `convertToAssets`), ERC-6909 claims, and per-pool ERC-20.
    /// @param key The PoolKey identifying the pool and its two currencies.
    /// @return amount0 Total managed currency0 assets, in currency0 native decimals.
    /// @return amount1 Total managed currency1 assets, in currency1 native decimals.
    function totalAssets(PoolKey calldata key) external view returns (uint256 amount0, uint256 amount1) {
        return _totalAssets(key);
    }

    /// @notice Preview the token amounts required to mint `shares` for a pool. Rounds up.
    /// @param key The PoolKey identifying the pool and its two currencies.
    /// @param shares The number of non-transferable pool shares to mint.
    /// @return amount0 Required currency0 amount, rounded up, in currency0 native decimals.
    /// @return amount1 Required currency1 amount, rounded up, in currency1 native decimals.
    function previewDeposit(PoolKey calldata key, uint256 shares)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        return _convertToAmounts(
            _vaultIdFor(key.toId()), Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), shares, true
        );
    }

    /// @notice Preview the token amounts returned for burning `shares` from a pool. Rounds down.
    /// @param key The PoolKey identifying the pool and its two currencies.
    /// @param shares The number of non-transferable pool shares to burn.
    /// @return amount0 Returned currency0 amount, rounded down, in currency0 native decimals.
    /// @return amount1 Returned currency1 amount, rounded down, in currency1 native decimals.
    function previewWithdraw(PoolKey calldata key, uint256 shares)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        return _convertToAmounts(
            _vaultIdFor(key.toId()), Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), shares, false
        );
    }

    /// @dev Wrap a `PoolId` into the base's `VaultId` namespace. Info-lossless cast
    ///      through bytes32; both types are `type X is bytes32`.
    function _vaultIdFor(PoolId poolId) internal pure returns (VaultId) {
        return VaultId.wrap(PoolId.unwrap(poolId));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                  INVENTORY PARTITION / VAULT ACCESSORS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The ERC-4626 vault configured for `(poolId, currency)`, or `address(0)` if the
    ///         currency is held as raw ERC-20. Preserves the pre-extraction `vaults` getter ABI.
    /// @param poolId   The pool to read.
    /// @param currency The currency side (currency0 or currency1).
    /// @return The bound ERC-4626 vault, or the zero vault if none.
    function vaults(PoolId poolId, Currency currency) external view returns (IERC4626) {
        return _vaultOf(poolId, currency);
    }

    /// @dev Accounting partition for `(poolId, currency)` in the `InventoryLib` capability, and
    ///      the canonical partition derivation subclasses pass to `SettlementLib`. Distinct per pool
    ///      so a hook serving multiple pools that share a currency keeps each pool's reserves
    ///      isolated. Hashes in the 0x00-0x40 scratch region, equivalent to
    ///      `keccak256(abi.encode(poolId, currency))` but without the free-memory allocation,
    ///      so the hot path's repeated partition derivations cost no more than the prior nested
    ///      `mapping[poolId][currency]` lookups.
    /// @param poolId   The pool the partition belongs to.
    /// @param currency The currency side (currency0 or currency1).
    /// @return partition The opaque `InventoryLib` accounting partition for `(poolId, currency)`.
    function _partition(PoolId poolId, Currency currency) internal pure returns (bytes32 partition) {
        assembly ("memory-safe") {
            mstore(0x00, poolId)
            mstore(0x20, currency)
            partition := keccak256(0x00, 0x40)
        }
    }

    /// @dev Vault bound to `(poolId, currency)`.
    function _vaultOf(PoolId poolId, Currency currency) internal view returns (IERC4626) {
        return _inventory.vaultOf(_partition(poolId, currency));
    }

    /// @dev Bind `vault` to `(poolId, currency)`. Caller validates the asset match.
    function _setVault(PoolId poolId, Currency currency, IERC4626 vault) internal {
        _inventory.setVault(_partition(poolId, currency), vault);
    }

    /// @dev ERC-4626 shares owned by `(poolId, currency)`.
    function _vaultSharesOf(PoolId poolId, Currency currency) internal view returns (uint256) {
        return _inventory.sharesOf(_partition(poolId, currency));
    }

    /// @dev ERC-6909 claims attributed to `(poolId, currency)`.
    function _claimsOf(PoolId poolId, Currency currency) internal view returns (uint256) {
        return _inventory.claimsOf(_partition(poolId, currency));
    }

    /// @dev Raw ERC-20 attributed to `(poolId, currency)`.
    function _erc20Of(PoolId poolId, Currency currency) internal view returns (uint256) {
        return _inventory.erc20Of(_partition(poolId, currency));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //              SHARE LIFECYCLE (PoolKey adapters)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev See {_bootstrap}. Adapter over PoolKey/Currency.
    function _bootstrap(PoolKey calldata key, address from, address to, uint256 amount0, uint256 amount1)
        internal
        returns (uint256 sharesMinted)
    {
        return _bootstrap(
            _vaultIdFor(key.toId()),
            Currency.unwrap(key.currency0),
            Currency.unwrap(key.currency1),
            from,
            to,
            amount0,
            amount1
        );
    }

    /// @dev See {_deposit}. Asset pair is read from the `Shares` ledger (bound at bootstrap),
    ///      not threaded through here.
    function _deposit(PoolKey calldata key, address from, address to, uint256 shares)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        return _deposit(_vaultIdFor(key.toId()), from, to, shares);
    }

    /// @dev See {_withdraw}.
    function _withdraw(PoolKey calldata key, address from, address to, uint256 shares)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        return _withdraw(_vaultIdFor(key.toId()), from, to, shares);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //              SHARE LIFECYCLE (core)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Seed a vault with its first deposit. Binds the asset pair, pulls both legs, mints
    ///      `sqrt(received0 * received1)` shares to `to`, and stamps the initial share/asset ratio.
    ///      Caller is responsible for authorization (owner-only on the consuming subclass).
    ///
    ///      Ordering is load-bearing: the pair is bound before the pulls, but it is only ever read
    ///      by `_deposit`/`_withdraw`, which require a non-zero supply that this function sets
    ///      atomically with the credit at the end, so an intra-bootstrap reentrant deposit would
    ///      still revert {VaultNotBootstrapped}. The pre-mutation accrual checkpoint fires against
    ///      the empty `(0, 0)` pre-state so a composed incentive capability initializes the
    ///      bootstrapper's paid index here.
    /// @param vaultId The vault to bootstrap.
    /// @param asset0  First asset address (used by `_pullAsset`).
    /// @param asset1  Second asset address.
    /// @param from    The address to pull tokens from.
    /// @param to      The address to credit shares to.
    /// @param amount0 Asset0 to deposit.
    /// @param amount1 Asset1 to deposit.
    /// @return sharesMinted Total shares minted, all credited to `to`.
    function _bootstrap(
        VaultId vaultId,
        address asset0,
        address asset1,
        address from,
        address to,
        uint256 amount0,
        uint256 amount1
    ) internal returns (uint256 sharesMinted) {
        _shares.requireNotBootstrapped(vaultId);
        if (amount0 == 0 || amount1 == 0) revert InsufficientBootstrap();

        _shares.bindAssets(vaultId, asset0, asset1);

        // FoT/rebasing reconciliation is `_pullAsset`'s responsibility; the share math uses the
        // returned `received`, so any under-receipt shrinks bootstrap shares rather than silently
        // diluting future holders.
        uint256 received0 = _pullAsset(vaultId, asset0, from, amount0);
        uint256 received1 = _pullAsset(vaultId, asset1, from, amount1);
        if (received0 == 0 || received1 == 0) revert InsufficientBootstrap();

        // Bootstrap share supply + inflation-defense floor are share-ledger policy; `Shares` owns
        // the computation (see {computeBootstrapShares}), this contract only supplies the I/O.
        sharesMinted = computeBootstrapShares(received0, received1, _decimalsOffset(vaultId));

        _onShareCheckpoint(vaultId, to, 0, 0);

        _shares.creditBootstrap(vaultId, to, sharesMinted, _getBlockNumberish());

        emit Bootstrap(vaultId, to, sharesMinted, received0, received1);
    }

    /// @dev Mint `shares` to `to` by pulling proportional token amounts from `from`. The
    ///      conversion rounds up (depositor pays slightly more to prevent share-value dilution).
    ///      Effects-first: the share counters update before any asset I/O so a reentrant view path
    ///      sees a coherent snapshot. Shares are minted against the requested `want`, so a
    ///      FoT/rebasing under-receipt reverts {TransferReceiptShortfall} rather than leaving the
    ///      vault short on assets.
    function _deposit(VaultId vaultId, address from, address to, uint256 shares)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        _shares.requireBootstrapped(vaultId);

        Assets memory pair = _shares.assetPair(vaultId);
        (uint256 want0, uint256 want1) = _convertToAmounts(vaultId, pair.asset0, pair.asset1, shares, true);

        // Settle reward/accounting accrual on the pre-deposit balances before the counters move.
        _onShareCheckpoint(vaultId, to, _shares.totalSupply(vaultId), _shares.balanceOf(vaultId, to));

        _shares.mint(vaultId, to, shares, _getBlockNumberish());

        amount0 = want0 > 0 ? _pullAsset(vaultId, pair.asset0, from, want0) : 0;
        amount1 = want1 > 0 ? _pullAsset(vaultId, pair.asset1, from, want1) : 0;
        if (amount0 < want0 || amount1 < want1) revert TransferReceiptShortfall();

        emit Deposit(vaultId, to, shares, amount0, amount1);
    }

    /// @dev Burn `shares` from `from` and send proportional token amounts to `to`. The conversion
    ///      rounds down (withdrawer receives slightly less to prevent over-withdrawal at remaining
    ///      holders' expense). The deposit lock and the balance check run before the accrual
    ///      checkpoint and the counter mutation, matching the pre-extraction ordering.
    function _withdraw(VaultId vaultId, address from, address to, uint256 shares)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        _shares.checkUnlocked(vaultId, from, _minDepositBlocks(vaultId), _getBlockNumberish());
        _shares.requireBalance(vaultId, from, shares);

        Assets memory pair = _shares.assetPair(vaultId);
        (amount0, amount1) = _convertToAmounts(vaultId, pair.asset0, pair.asset1, shares, false);

        // Settle reward/accounting accrual on the pre-withdraw balances before the counters move.
        _onShareCheckpoint(vaultId, from, _shares.totalSupply(vaultId), _shares.balanceOf(vaultId, from));

        _shares.burn(vaultId, from, shares);

        if (amount0 > 0) _pushAsset(vaultId, pair.asset0, to, amount0);
        if (amount1 > 0) _pushAsset(vaultId, pair.asset1, to, amount1);

        emit Withdraw(vaultId, from, shares, amount0, amount1);
    }

    /// @dev Convert a share count to the equivalent token amounts for both assets, proportional to
    ///      the pool's current managed balances. Reads the gross managed balance
    ///      (`Inventory.assetBalance`) for each leg and the per-pool offset, then defers to the
    ///      `Shares` ledger's virtual-offset formula
    ///      (`amount = shares * (total + 1) / (supply + 10**offset)`). Reverts
    ///      {VaultNotBootstrapped} when the supply is zero.
    function _convertToAmounts(VaultId vaultId, address asset0, address asset1, uint256 shares, bool roundUp)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        PoolId poolId = PoolId.wrap(VaultId.unwrap(vaultId));
        uint256 bal0 = _inventory.assetBalance(_partition(poolId, Currency.wrap(asset0)));
        uint256 bal1 = _inventory.assetBalance(_partition(poolId, Currency.wrap(asset1)));
        return _shares.convertToAmounts(vaultId, bal0, bal1, _decimalsOffset(vaultId), shares, roundUp);
    }

    /// @notice Accounting checkpoint fired immediately before any share-balance mutation for
    ///         `user`, carrying the pre-mutation total and user share counts. A composed capability
    ///         (e.g. a liquidity-incentives `Rewards`) overrides this to settle per-share accrual on
    ///         the balances in force until now, following the Synthetix `updateReward` pattern
    ///         (settle the global index against the old supply, then the user against their old
    ///         balance, before the counts change). Fires on bootstrap, deposit, and withdraw.
    ///         Default no-op, so pools without an incentive capability are unaffected.
    /// @param vaultId           The vault whose shares are about to change.
    /// @param user              The account whose share balance is about to change.
    /// @param totalSharesBefore Total shares outstanding immediately before the mutation.
    /// @param userSharesBefore  `user`'s share balance immediately before the mutation.
    function _onShareCheckpoint(VaultId vaultId, address user, uint256 totalSharesBefore, uint256 userSharesBefore)
        internal
        virtual {}

    // ═══════════════════════════════════════════════════════════════════════════
    //                          ASSET ACCOUNTING (V4)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Total managed assets for a pool across both currencies, valuing each leg at its gross
    ///      economic balance (`Inventory.assetBalance`: raw + claims + `convertToAssets(shares)`).
    ///      LP share math reads this so claims are priced over the pool's true economic stake,
    ///      including capital temporarily behind a vault pause or an unrealized exit fee. Contrast
    ///      `_effectiveAssets`, which values the vault leg at what is realizable right now
    ///      (`maxWithdraw` first, `previewRedeem` fallback). The trade-off is that a vault
    ///      overstating `convertToAssets`
    ///      inflates these balances and dilutes new depositors; bounded by the vault-trust model.
    function _totalAssets(PoolKey memory key) internal view returns (uint256 amount0, uint256 amount1) {
        PoolId poolId = key.toId();
        amount0 = _inventory.assetBalance(_partition(poolId, key.currency0));
        amount1 = _inventory.assetBalance(_partition(poolId, key.currency1));
    }

    /// @dev Pool-level effective (immediately-withdrawable) assets across both currencies.
    function _effectiveAssets(PoolKey calldata key) internal view returns (uint256 amount0, uint256 amount1) {
        return _effectiveAssets(key.toId(), key.currency0, key.currency1);
    }

    /// @dev Pool-level effective assets when the caller already has the PoolId cached. Values each
    ///      leg at its realizable balance (`InventoryLib.effectiveBalance`: raw + claims + the
    ///      vault's immediately-withdrawable value, `maxWithdraw` first with a `previewRedeem`
    ///      fallback), i.e. what the vault would deliver right now. JIT-deployment sizing and
    ///      indicative quotes read this so a cycle never sizes against funds it cannot source.
    ///      Contrast `_totalAssets`, which uses `convertToAssets` for the pool's full economic
    ///      stake.
    function _effectiveAssets(PoolId poolId, Currency currency0, Currency currency1)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        amount0 = _inventory.effectiveBalance(_partition(poolId, currency0));
        amount1 = _inventory.effectiveBalance(_partition(poolId, currency1));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          ASSET I/O (V4)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Pull `want` of `asset` from `from` into the hook's custody for the share lifecycle,
    ///         returning the actual amount received.
    /// @dev Pulls underlying ERC-20 from `from` via `safeTransferFrom`, measures the actual
    ///      receipt, then routes:
    ///        - If a vault is configured for this `(pool, currency)`, deposits to the vault
    ///          (updating `_vaultShares`).
    ///        - Otherwise, credits the per-pool `_state.erc20` counter.
    ///
    ///      Fee-on-transfer / rebasing tokens are unsupported. The receipt is measured against
    ///      the hook's balance delta, and any shortfall (`received < want`, i.e. the token took
    ///      a transfer fee) reverts `TransferReceiptShortfall` for both the bootstrap and the
    ///      `addLiquidity` deposit paths, so a fee-charging token can never seed an unswappable
    ///      pool. This is a deposit-time check only: it cannot catch a token that begins
    ///      charging a fee or rebases down after the deposit, so operators must still restrict
    ///      pools to non-FoT, non-rebasing tokens.
    function _pullAsset(VaultId vaultId, address asset, address from, uint256 want)
        internal
        returns (uint256 received)
    {
        if (want == 0) return 0;
        PoolId poolId = PoolId.wrap(VaultId.unwrap(vaultId));
        Currency currency = Currency.wrap(asset);

        // Measure inbound receipt against the hook's balance, not the vault's, so a FoT/rebasing
        // shortfall is detected before any vault interaction. Reject under-receipt outright
        // rather than crediting the reduced figure: a smaller bootstrap/deposit would seed a
        // pool whose recorded balances exceed what the hook can ever settle, bricking its swaps.
        IERC20 token = IERC20(asset);
        uint256 balBefore = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), want);
        received = token.balanceOf(address(this)) - balBefore;
        if (received < want) revert TransferReceiptShortfall();

        // Route the receipt: `_depositToVault` deposits into the configured vault, or credits
        // the per-pool `_state.erc20` ledger when no vault is set. `received > 0` here (FoT
        // check above + the `want == 0` early return), so its zero-amount guard never fires.
        _depositToVault(poolId, currency, received);
    }

    /// @notice Push `amount` of `asset` from the hook's custody to `to` for the share lifecycle.
    /// @dev Ensures the per-pool `_state.erc20` holds at least `amount` (redeems claims
    ///      and/or withdraws from the configured vault as needed), then transfers via
    ///      `Currency.transfer` (USDT-safe).
    function _pushAsset(VaultId vaultId, address asset, address to, uint256 amount) internal {
        if (amount == 0) return;
        PoolId poolId = PoolId.wrap(VaultId.unwrap(vaultId));
        Currency currency = Currency.wrap(asset);

        _ensureERC20(poolId, currency, amount);
        currency.transfer(to, amount);
    }

    /// @notice Per-pool minimum deposit-lock duration, as consumed by the `_withdraw` lock guard.
    /// @dev Looks up the per-pool lock duration set at pool initialization.
    function _minDepositBlocks(VaultId vaultId) internal view returns (uint64) {
        return minDepositBlocks[PoolId.wrap(VaultId.unwrap(vaultId))];
    }

    /// @notice The virtual-shares offset for a pool's inflation defense and bootstrap floor.
    /// @dev Returns the per-pool offset derived from the pair's token decimals at init (see
    ///      {_initDecimalsOffset}). The default `12` is correct for 18-decimal pairs but makes the
    ///      bootstrap floor (`100 * 10**12` base units) very large for low-decimal pairs (e.g.
    ///      ~100M tokens/side for a 6/6 stablecoin pair), so the per-pool derivation lowers it so
    ///      common stablecoin pools can be bootstrapped at a realistic size. A pool that was never
    ///      initialized maps to `12`.
    function _decimalsOffset(VaultId vaultId) internal view returns (uint8) {
        uint8 offset = _poolDecimalsOffset[PoolId.wrap(VaultId.unwrap(vaultId))];
        return offset == 0 ? DEFAULT_DECIMALS_OFFSET : offset;
    }

    /// @dev Derive and cache a pool's virtual-shares offset from its currencies' `decimals()`:
    ///      `clamp((d0 + d1) / 2 - 6, 6, 12)`. This keeps the bootstrap floor (`100 * 10**offset`
    ///      base units) at a realistic per-side seed for the pair while keeping the `10**offset`
    ///      virtual-share inflation defense at least `1e6`:
    ///
    ///        - 18/18 → 12 (floor ~1e-4 token/side; unchanged from the prior hardcoded default)
    ///        - 6/6   → 6  (floor ~100 tokens/side, e.g. ~100 USDC, vs. ~100M before)
    ///        - 6/18  → 6, 8/8 → 6, etc.
    ///
    ///      The drift at the floor is ~1% regardless of offset (the floor is defined to give
    ///      ~1% drift); the offset only sets the absolute minimum seed and the defense strength,
    ///      which move together. Tokens that don't implement `decimals()` fall back to 18.
    ///      Called once per pool at initialization; the result is immutable thereafter, so the
    ///      conversion math reads a stable value for the pool's lifetime.
    /// @param poolId    The pool whose offset to derive and store.
    /// @param currency0 The pool's first currency.
    /// @param currency1 The pool's second currency.
    function _initDecimalsOffset(PoolId poolId, Currency currency0, Currency currency1) internal {
        uint256 avg = (uint256(_tokenDecimals(currency0)) + uint256(_tokenDecimals(currency1))) / 2;
        uint256 raw = avg > DECIMALS_OFFSET_MARGIN ? avg - DECIMALS_OFFSET_MARGIN : 0;
        if (raw < MIN_DECIMALS_OFFSET) raw = MIN_DECIMALS_OFFSET;
        if (raw > DEFAULT_DECIMALS_OFFSET) raw = DEFAULT_DECIMALS_OFFSET;
        _poolDecimalsOffset[poolId] = uint8(raw);
    }

    /// @dev Read a token's `decimals()`, defaulting to `FALLBACK_DECIMALS` for tokens that do
    ///      not implement the optional metadata extension. Used only at pool initialization.
    function _tokenDecimals(Currency currency) private view returns (uint8) {
        try IERC20Metadata(Currency.unwrap(currency)).decimals() returns (uint8 d) {
            return d;
        } catch {
            return FALLBACK_DECIMALS;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          INTERNAL: VAULT OPERATIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Deposit `amount` of `currency` into the pool's configured ERC4626 vault. Caller
    ///      must have already transferred `amount` tokens to this contract. If no vault is
    ///      configured, the amount is tracked in `_state.erc20` instead. Assumes the vault
    ///      is already approved (subclasses approve at pool init via `_approveVault`).
    ///
    ///      ## Vault trust model
    ///
    ///      The hook holds standing max allowance to each (pool, currency) vault. A
    ///      compromised or upgradeable vault for currency X can in principle `transferFrom`
    ///      the hook's full balance of X, including raw ERC-20 attributed to unrelated
    ///      pools that share that currency. Operators MUST select vaults whose security
    ///      properties they understand (immutable / non-upgradeable preferred).
    ///
    ///      The (pool, currency) → vault binding is immutable, but the standing allowance is
    ///      not: `_revokeVaultApproval` zeroes it, and a subclass MAY expose an owner-only
    ///      emergency action that revokes the allowance, disables deposits, and pauses the
    ///      pool atomically to cap the damage window when a vault incident is detected.
    ///
    ///      Curated/gated vaults (e.g., Morpho VaultV2) add a third trust dimension on top
    ///      of share-price and allowance trust: the curator can enable a gate that denies
    ///      future deposits or withdrawals from the hook. Operators MUST trust the chosen
    ///      vault's curator not to weaponize the gate against the pool.
    ///
    ///      Deposit-credit trust: LP shares are minted against `want` (the assets pulled),
    ///      but the pool's vault-backed value derives from `convertToAssets(_vaultShares)`. A
    ///      vault that credits a `deposit` with less value than the assets in (a deposit fee,
    ///      or shares worth less than they cost) would over-mint LP shares relative to value
    ///      backed, diluting existing LPs. `_requireFeelessVault` rejects this at init for any
    ///      honestly-disclosed fee; a vault that passes the probe yet charges a real deposit
    ///      fee is adversarial and already covered by the allowance trust above (it can drain
    ///      outright, which dwarfs dilution). A runtime net-credit check is intentionally NOT
    ///      added: ERC-4626 `deposit` rounds shares down, so `convertToAssets(sharesActual)`
    ///      is legitimately a few wei below `want` on honest vaults, and that dust rounds in
    ///      the pool's favour (a deposit→withdraw round-trip never profits the depositor).
    function _depositToVault(PoolId poolId, Currency currency, uint256 amount) internal {
        _inventory.depositToVault(_partition(poolId, currency), currency, amount);
    }

    /// @dev Deposit all of the pool's tracked ERC-20 balance for both currencies into vaults.
    ///      Called in afterSwap after the JIT cycle resolves.
    function _depositAllToVaults(PoolId poolId, PoolKey calldata key) internal {
        _depositAllToVault(poolId, key.currency0);
        _depositAllToVault(poolId, key.currency1);
    }

    /// @dev Deposit the pool's tracked ERC-20 balance of a currency into its vault. No-op
    ///      for non-vaulted pools (the balance stays in `_state.erc20`). Relies on the
    ///      init-time max approval so swap teardown does not pay an allowance read on every
    ///      vaulted currency.
    ///
    ///      Unlike `_depositToVault` (LP deposit path, surfaces vault rejection directly to
    ///      the caller), this function wraps `vault.deposit` in `try/catch`. The caller here
    ///      is the JIT cycle's afterSwap settlement: the swap itself has already executed
    ///      and a deposit-side revert would brick swaps for an operator-vault
    ///      misconfiguration (e.g., `maxDeposit` cap reached, curated allocator rejection,
    ///      paused vault). On failure the `try` block's state changes atomically revert, so
    ///      `s.erc20` and `_vaultShares` are untouched; the function emits `VaultDepositSkipped`
    ///      and continues. LPs forgo vault yield on the un-deposited amount until the next
    ///      cycle retries, but trading remains live.
    function _depositAllToVault(PoolId poolId, Currency currency) internal {
        (uint256 amount, bool ok, bytes memory reason) = _inventory.tryDepositAll(_partition(poolId, currency));
        if (!ok) emit VaultDepositSkipped(poolId, currency, amount, reason);
    }

    /// @dev Withdraw `amount` of `currency` from the pool's vault, crediting per-pool ERC-20.
    ///      Calls `vault.withdraw` optimistically: if the vault cannot satisfy the request
    ///      (paused, utilization-constrained, curated-allocation shortfall), the vault's own
    ///      revert bubbles up through `_pushAsset` → swap callback → `beforeSwap`. The
    ///      `CrossPoolShareLeak` defensive check stays to catch a vault that consumes more
    ///      shares than the pool owns.
    function _withdrawFromVault(PoolId poolId, Currency currency, uint256 amount) internal {
        _inventory.withdrawFromVault(_partition(poolId, currency), amount);
    }

    /// @dev Best-effort full withdrawal of the pool's vault position for `currency` back into
    ///      the per-pool raw ERC-20 ledger. Redeems exactly the pool's own `_vaultShares` (never
    ///      a sibling pool's), so cross-pool isolation is preserved.
    ///
    ///      Wrapped in try/catch by design: this is the rescue leg of an emergency response
    ///      against a suspect-but-still-cooperative vault. A bricked / paused vault that reverts
    ///      on `redeem` MUST NOT block the surrounding revocation + pause, so on failure this is
    ///      a no-op (assets stay in the vault, `_vaultShares` untouched) and emits
    ///      {VaultDrainSkipped}. On success the position moves to `s.erc20`: vault assets become
    ///      raw ERC-20, outside the suspect vault's reach.
    /// @param poolId   The pool whose vault position to drain.
    /// @param currency The currency to withdraw from the vault.
    function _drainVaultBestEffort(PoolId poolId, Currency currency) internal {
        (uint256 shares, uint256 assets, bool ok, bytes memory reason) =
            _inventory.tryDrain(_partition(poolId, currency));
        if (shares == 0) return;
        if (ok) emit VaultDrained(poolId, currency, shares, assets);
        else emit VaultDrainSkipped(poolId, currency, shares, reason);
    }

    /// @dev Ensure the pool's tracked ERC-20 balance is at least `amount`, then debit it.
    ///      Withdraws any shortfall from the configured vault by calling `vault.withdraw`
    ///      directly; on vault failure (paused, curated shortfall, etc.) the revert bubbles
    ///      up through `_pushAsset` → swap callback → `beforeSwap`. Routers / aggregators
    ///      see the vault-side error (e.g., Morpho's `NotEnoughLiquidity`) rather than a
    ///      uniform PoolVault sentinel.
    ///
    ///      For non-vaulted pools the `bal - amount` subtraction below panics on underflow
    ///      when the pool has no configured vault and insufficient ERC-20; there is no
    ///      separate sentinel revert.
    function _ensureERC20(PoolId poolId, Currency currency, uint256 amount) internal {
        _inventory.ensureERC20(_partition(poolId, currency), amount);
    }

    /// @dev Set max approval for a vault using OZ `forceApprove` (zeros out first for
    ///      USDT-style tokens). Subclasses MUST call this once per (currency, vault) pair
    ///      at pool initialization, before any vault deposit can occur.
    function _approveVault(Currency currency, address vault) internal {
        InventoryLib.approveVault(currency, vault);
    }

    /// @dev Zero the hook's standing approval to a vault: the emergency counterpart to
    ///      `_approveVault`. Uses `forceApprove(0)` (a non-zero→zero transition, safe for
    ///      USDT-style tokens) so a vault suspected compromised can no longer `transferFrom`
    ///      the hook's balance of `currency`. No-op for `address(0)` (non-vaulted currency).
    ///
    ///      Note: the LP deposit path re-arms the allowance via `_ensureVaultAllowance` on the
    ///      next `vault.deposit`. Callers MUST stop deposits (pause the pool and disable
    ///      external deposits) in the same transaction, or the revocation will not hold.
    function _revokeVaultApproval(Currency currency, address vault) internal {
        InventoryLib.revokeVaultApproval(currency, vault);
    }

    /// @dev Force `currency`'s vault allowance back to max regardless of its current value: the
    ///      owner-driven recovery counterpart to `_approveVault`, used after an emergency revoke or
    ///      to re-arm a USDT-style token whose allowance drifted. No-op for `address(0)`.
    function _refreshVaultApproval(Currency currency, address vault) internal {
        InventoryLib.refreshVaultApproval(currency, vault);
    }

    /// @dev Reject ERC-4626 vaults that apply entry or exit fees. Called once per vault at
    ///      pool initialization; no-ops for `address(0)` (non-vaulted currency).
    ///
    ///      Detection leverages the EIP-4626 contract that `convertToShares`/`convertToAssets`
    ///      MUST NOT factor in fees, while `previewDeposit`/`previewRedeem` MUST. For a feeless
    ///      vault:
    ///        - `previewDeposit(probe) == convertToShares(probe)` (both round down)
    ///        - `previewRedeem(probe)  == convertToAssets(probe)` (both round down)
    ///      Any divergence is an honest report of a fee. The probe is `10**vault.decimals()`
    ///      so any per-mille-or-larger fee shows up well above rounding noise.
    ///
    ///      A reverting `previewRedeem` probe is tolerated (the exit-side comparison is
    ///      skipped): liquidity-gated vaults (Spark savings vaults) revert it when idle
    ///      liquidity cannot cover the probe amount, which is a liquidity report, not a fee
    ///      disclosure. See `InventoryLib.requireFeelessVault`.
    ///
    ///      Note that this guard only catches honest fee disclosures. An adversarial vault
    ///      could lie at the preview level and charge fees only on actual deposit/withdraw;
    ///      the LP-side socialization documented in the contract-level `Vault Compatibility`
    ///      NatSpec would still apply in that case. Operators are trusted to pick curated
    ///      vaults whose preview functions reflect ground truth.
    function _requireFeelessVault(IERC4626 vault) internal view {
        InventoryLib.requireFeelessVault(vault);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          INTERNAL: CLAIM MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Redeem this pool's ERC-6909 claims to ERC-20 via the PoolManager. Only callable
    ///      within a v4 unlock context. Increments `_state.erc20` by the redeemed amount and
    ///      returns the post-redeem balance so callers don't need a follow-up SLOAD.
    ///
    ///      A claim is an accounting credit, backed by real tokens in the PoolManager only once
    ///      the corresponding swapper has settled. Claims minted by an earlier swap on this pool
    ///      within the same, still-unsettled transaction (multiple swaps on one pool inside a
    ///      single `unlock`) are therefore not yet physically backed: the swapper's input lands
    ///      at end-of-unlock, not now. Taking the full claim balance would attempt to transfer
    ///      tokens the PoolManager does not yet hold and revert the later swap.
    ///
    ///      Cap the physical `take` at the PoolManager's current balance of `currency` and burn
    ///      only that much; leave any remainder as recorded claims. The deployment shortfall is
    ///      sourced from the vault by the caller (`_deployJIT` withdraws `totalNeed - onHand`),
    ///      and the residual claims redeem on a later cycle once their backing has settled. The
    ///      common path (claims fully backed) is unchanged: `available >= claimBal`, so the full
    ///      balance is redeemed exactly as before.
    function _redeemPoolClaims(PoolId poolId, Currency currency) internal returns (uint256 erc20Bal) {
        return _inventory.redeemClaims(_partition(poolId, currency), currency, _poolManager());
    }

    /// @dev The portion of a pool's recorded claims that the PoolManager cannot physically
    ///      honor right now: claims whose backing settle is still pending in this transaction
    ///      (e.g. minted by an earlier same-pool swap inside one unlock). `_deployJIT` excludes
    ///      this from the deployable balance so it never sizes liquidity against funds it cannot
    ///      source this cycle: `_redeemPoolClaims` can only redeem the backed portion, and the
    ///      vault does not hold the claim portion, so counting it would over-draw the vault.
    ///      Returns 0 in the common case (claims fully backed), so steady-state sizing is
    ///      unaffected.
    function _unbackedClaims(PoolId poolId, Currency currency) internal view returns (uint256) {
        return _inventory.unbackedClaims(_partition(poolId, currency), currency, _poolManager());
    }

    /// @dev Record newly minted ERC-6909 claims for a pool. Called after `poolManager.mint()`
    ///      in the JIT delta resolution.
    function _recordClaims(PoolId poolId, Currency currency, uint256 amount) internal {
        _inventory.recordClaims(_partition(poolId, currency), amount);
    }

    /// @dev Debit `amount` from the pool's tracked ERC-20 balance after a PM settlement.
    ///      The actual `_settle` call is the subclass's responsibility; this function only
    ///      updates the per-pool counter.
    function _debitPoolERC20(PoolId poolId, Currency currency, uint256 amount) internal {
        _inventory.debitERC20(_partition(poolId, currency), amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          ABSTRACT: POOL MANAGER ACCESS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Subclasses must provide access to the v4 PoolManager. Required for claim
    ///      operations (`burn`, `take`) in `_redeemPoolClaims`.
    function _poolManager() internal view virtual returns (IPoolManager);
}
