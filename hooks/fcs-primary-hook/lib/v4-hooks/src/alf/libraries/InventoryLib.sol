// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {Inventory, CurrencyState} from "../types/Inventory.sol";

/// @title InventoryLib
/// @author Uniswap Labs
/// @notice The token-custody half of the `Inventory` capability: the operations that need the
///         consuming contract's execution context, either to move tokens or to size against the
///         consumer's vault position. Internal library functions inline into the consumer, so
///         `address(this)` (the token custodian), vault `deposit`/`withdraw`/`redeem`,
///         `maxWithdraw` sizing, PoolManager `take`/`burn`, and allowance checks all resolve
///         against the consumer. The pure, context-free `Inventory` operations (accessors,
///         balance views, claim accounting) are file-level free functions in
///         `types/Inventory.sol`; a consumer binds this library with `using InventoryLib for
///         Inventory` so both halves are invoked uniformly as `_inventory.method(...)`.
/// @dev The vault-fee guards' errors ({VaultChargesEntryFee}/{VaultChargesExitFee}) live here so
///      callers that match on them keep a stable qualified reference.
/// @custom:security-contact security@uniswap.org
library InventoryLib {
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @dev A vault redemption returned more shares than the partition owns. Defensive; should
    ///      never trigger if `vaultShares` accounting is consistent.
    error CrossPoolShareLeak();
    /// @dev `vault.deposit` returned zero shares for a non-zero asset deposit. Reverting fail-fast
    ///      prevents asset loss into a vault that gives no claim back.
    error ZeroSharesMinted();
    /// @dev The configured ERC-4626 vault applies an entry fee (`previewDeposit < convertToShares`).
    error VaultChargesEntryFee();
    /// @dev The configured ERC-4626 vault applies an exit fee (`previewRedeem < convertToAssets`).
    error VaultChargesExitFee();

    // ─────────────────────────────────────── Vault operations ──────────────────────────────────────

    /// @notice Deposit `amount` of `currency` (already held by the consumer) into `partition`'s
    ///         vault, or credit raw ERC-20 if no vault is bound.
    /// @dev LP-path semantics: a vault rejection bubbles up to the caller (no try/catch). Reverts
    ///      {ZeroSharesMinted} if a non-zero deposit mints no shares.
    /// @param self     Capability storage.
    /// @param partition   The accounting partition to credit.
    /// @param currency The underlying asset being deposited.
    /// @param amount   The asset amount to deposit (token's native decimals).
    function depositToVault(Inventory storage self, bytes32 partition, Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        IERC4626 vault = self.vault[partition];
        if (address(vault) == address(0)) {
            CurrencyState storage s = self.state[partition];
            s.erc20 = (uint256(s.erc20) + amount).toUint128();
            return;
        }

        ensureVaultAllowance(currency, address(vault), amount);
        uint256 sharesActual = vault.deposit(amount, address(this));

        if (sharesActual == 0) revert ZeroSharesMinted();
        self.vaultShares[partition] += sharesActual;
    }

    /// @notice Best-effort deposit of the partition's tracked raw ERC-20 into its vault.
    /// @dev No-ops (no vault / zero raw) return `ok = true`. The vault-deposit failure is caught; a
    ///      successful-but-zero-share deposit still reverts {ZeroSharesMinted}. When `ok` is false
    ///      and `amount > 0` the consumer SHOULD emit its own deposit-skipped event with `reason`.
    /// @param self   Capability storage.
    /// @param partition The accounting partition whose raw balance to sweep.
    /// @return amount The raw amount the deposit attempted (token's native decimals).
    /// @return ok     True if the deposit succeeded or was a no-op; false if the vault reverted.
    /// @return reason The raw revert data from `vault.deposit` when `ok` is false; empty otherwise.
    function tryDepositAll(Inventory storage self, bytes32 partition)
        internal
        returns (uint256 amount, bool ok, bytes memory reason)
    {
        IERC4626 vault = self.vault[partition];
        if (address(vault) == address(0)) return (0, true, "");
        CurrencyState storage s = self.state[partition];
        amount = s.erc20;
        if (amount == 0) return (0, true, "");

        try vault.deposit(amount, address(this)) returns (uint256 sharesActual) {
            if (sharesActual == 0) revert ZeroSharesMinted();
            s.erc20 = 0;
            self.vaultShares[partition] += sharesActual;
            ok = true;
        } catch (bytes memory r) {
            reason = r;
        }
    }

    /// @notice Withdraw `amount` of the partition's vaulted assets back to raw ERC-20, optimistically.
    /// @dev No-op if no vault is bound. A vault revert bubbles up to the caller.
    ///      {CrossPoolShareLeak} guards against a vault consuming more shares than the partition owns.
    /// @param self   Capability storage.
    /// @param partition The accounting partition to withdraw for.
    /// @param amount The asset amount to pull from the vault (token's native decimals).
    function withdrawFromVault(Inventory storage self, bytes32 partition, uint256 amount) internal {
        if (amount == 0) return;
        IERC4626 vault = self.vault[partition];
        if (address(vault) == address(0)) return;

        uint256 sharesUsed = vault.withdraw(amount, address(this), address(this));
        uint256 poolShares = self.vaultShares[partition];
        if (sharesUsed > poolShares) revert CrossPoolShareLeak();
        self.vaultShares[partition] = poolShares - sharesUsed;
        CurrencyState storage s = self.state[partition];
        s.erc20 = (uint256(s.erc20) + amount).toUint128();
    }

    /// @notice Best-effort full redemption of the partition's vault position back to raw ERC-20.
    /// @dev `shares == 0` means nothing to drain (the consumer emits no event); otherwise `ok` true
    ///      ⇒ consumer emits drained(shares, assets), false ⇒ consumer emits
    ///      drain-skipped(shares, reason). Redeems exactly the partition's own shares, preserving
    ///      cross-partition isolation.
    /// @param self   Capability storage.
    /// @param partition The accounting partition to drain.
    /// @return shares The vault shares the drain operated on (`0` if nothing to drain).
    /// @return assets The asset amount received and credited to raw ERC-20 on success.
    /// @return ok     True if the redeem succeeded; false if the vault reverted.
    /// @return reason The raw revert data from `vault.redeem` when `ok` is false; empty otherwise.
    function tryDrain(Inventory storage self, bytes32 partition)
        internal
        returns (uint256 shares, uint256 assets, bool ok, bytes memory reason)
    {
        IERC4626 vault = self.vault[partition];
        if (address(vault) == address(0)) return (0, 0, false, "");
        shares = self.vaultShares[partition];
        if (shares == 0) return (0, 0, false, "");

        try vault.redeem(shares, address(this), address(this)) returns (uint256 a) {
            self.vaultShares[partition] = 0;
            CurrencyState storage s = self.state[partition];
            s.erc20 = (uint256(s.erc20) + a).toUint128();
            assets = a;
            ok = true;
        } catch (bytes memory r) {
            reason = r;
        }
    }

    /// @notice Net realizable balance: raw + claims + the vault leg's immediately-withdrawable
    ///         value.
    /// @dev Used for JIT-deployment sizing and indicative quotes so a cycle never sizes against
    ///      funds it cannot source. Lives here rather than with the other balance views in
    ///      `types/Inventory.sol` because the vault leg reads `maxWithdraw(address(this))` (see
    ///      {realizableVaultAssets}), and free functions cannot access `this`. Contrast
    ///      `assetBalance` (types/Inventory.sol), which values the vault leg at the partition's
    ///      full economic stake via `convertToAssets`.
    /// @param self   Capability storage.
    /// @param partition The accounting partition to value.
    /// @return bal The immediately-realizable balance (token's native decimals).
    function effectiveBalance(Inventory storage self, bytes32 partition) internal view returns (uint256 bal) {
        CurrencyState storage s = self.state[partition];
        bal = uint256(s.erc20) + uint256(s.claims);
        IERC4626 vault = self.vault[partition];
        if (address(vault) != address(0)) {
            uint256 shares = self.vaultShares[partition];
            if (shares > 0) bal += realizableVaultAssets(vault, shares);
        }
    }

    /// @notice The immediately-withdrawable value of the consumer's `shares` in `vault`:
    ///         `maxWithdraw` first, `previewRedeem` as the fallback.
    /// @dev Tolerates the two known ways production vaults deviate from a textbook ERC-4626 on
    ///      the sizing views:
    ///
    ///        1. Liquidity-gated previews (Spark savings vaults): `previewRedeem` reverts
    ///           whenever the vault's idle balance cannot cover the redemption, so it cannot be
    ///           the primary read on a hot path; it would revert sizing exactly when the vault
    ///           has capital deployed, which is its normal operating state. `maxWithdraw` is the
    ///           honest cap there: `min(idle liquidity, owner assets)`.
    ///        2. Unbounded-cap sentinels (Morpho VaultV2): `maxWithdraw` returns `0` by
    ///           construction because the vault cannot bound a single-block withdrawal across
    ///           its internal allocations. `previewRedeem` is the honest value there.
    ///
    ///      A non-zero `maxWithdraw` is clamped to the partition's own gross share value
    ///      (`convertToAssets(shares)`): `maxWithdraw` is owner-scoped, so on a vault shared by
    ///      several partitions it counts sibling positions, and an unclamped read would let one
    ///      partition size against another's stake. The feeless-vault gate at bind time makes
    ///      `convertToAssets` match the honest exit value, so the clamp loses nothing.
    ///
    ///      A zero cap is ambiguous (VaultV2-style sentinel, or genuinely nothing idle), so it
    ///      falls back to `previewRedeem(shares)`. There the try/catch disambiguates: success is
    ///      the sentinel case (the preview is the honest value); a revert alongside a successful
    ///      zero `maxWithdraw` identifies a liquidity-gated vault with nothing idle, where zero
    ///      is the honest answer.
    ///
    ///      A `maxWithdraw` that itself reverts (forbidden by ERC-4626) signals a broken or
    ///      paused vault, not a liquidity report. That falls through to a bare `previewRedeem`
    ///      whose revert bubbles up, preserving the documented vault-outage behavior: a
    ///      fully-paused vault fails swaps explicitly rather than silently sizing the pool to
    ///      zero (see the PoolVault `Vault Compatibility` NatSpec).
    /// @param vault  The ERC-4626 vault to size against.
    /// @param shares The partition's share balance in `vault`.
    /// @return The asset value (token's native decimals) the consumer can withdraw right now.
    function realizableVaultAssets(IERC4626 vault, uint256 shares) internal view returns (uint256) {
        try vault.maxWithdraw(address(this)) returns (uint256 cap) {
            if (cap > 0) {
                uint256 value = vault.convertToAssets(shares);
                return value < cap ? value : cap;
            }
            try vault.previewRedeem(shares) returns (uint256 assets) {
                return assets;
            } catch {
                return 0;
            }
        } catch {
            return vault.previewRedeem(shares);
        }
    }

    /// @notice Ensure the partition's raw ERC-20 holds at least `amount`, withdrawing the shortfall
    ///         from the vault, then debit it.
    /// @dev For a non-vaulted partition with insufficient raw, the `bal - amount` subtraction panics
    ///      on underflow (no sentinel). {CrossPoolShareLeak} guards the vaulted path.
    /// @dev On the vaulted-shortfall path the partition is set to `0` rather than computed: it
    ///      withdraws exactly `shortfall = amount - bal`, so after crediting the withdrawal and
    ///      debiting `amount` the partition nets to zero (`bal + shortfall == amount`). Do not
    ///      "fix" this into an arithmetic expression; the literal zero is the correct result.
    /// @param self   Capability storage.
    /// @param partition The accounting partition to debit.
    /// @param amount The asset amount to make available and debit (token's native decimals).
    function ensureERC20(Inventory storage self, bytes32 partition, uint256 amount) internal {
        if (amount == 0) return;
        CurrencyState storage s = self.state[partition];
        uint256 bal = s.erc20;
        if (bal >= amount) {
            s.erc20 = uint128(bal - amount);
            return;
        }

        IERC4626 vault = self.vault[partition];
        if (address(vault) == address(0)) {
            s.erc20 = uint128(bal - amount);
            return;
        }

        uint256 shortfall = amount - bal;
        uint256 sharesUsed = vault.withdraw(shortfall, address(this), address(this));
        uint256 poolShares = self.vaultShares[partition];
        if (sharesUsed > poolShares) revert CrossPoolShareLeak();
        self.vaultShares[partition] = poolShares - sharesUsed;
        s.erc20 = 0;
    }

    /// @notice Redeem the partition's ERC-6909 claims to raw ERC-20 via `pm` (only inside an unlock).
    /// @dev Caps the physical `take` at the PoolManager's current balance, since claims minted by
    ///      an earlier same-partition swap in the same unsettled tx are not yet backed, and retains
    ///      any unbacked remainder as claims.
    /// @param self     Capability storage.
    /// @param partition   The accounting partition whose claims to redeem.
    /// @param currency The underlying asset of the claims.
    /// @param pm       The v4 PoolManager to burn the ERC-6909 claims on and `take` from.
    /// @return erc20Bal The partition's raw ERC-20 balance after redemption (token's native decimals).
    function redeemClaims(Inventory storage self, bytes32 partition, Currency currency, IPoolManager pm)
        internal
        returns (uint256 erc20Bal)
    {
        CurrencyState memory snapshot = self.state[partition];
        uint256 claimBal = snapshot.claims;
        erc20Bal = snapshot.erc20;
        if (claimBal > 0) {
            uint256 available = currency.balanceOf(address(pm));
            uint256 takeAmount = claimBal < available ? claimBal : available;
            if (takeAmount > 0) {
                pm.burn(address(this), currency.toId(), takeAmount);
                pm.take(currency, address(this), takeAmount);
                erc20Bal += takeAmount;
            }
            self.state[partition] =
                CurrencyState({erc20: erc20Bal.toUint128(), claims: (claimBal - takeAmount).toUint128()});
        }
    }

    // ───────────────────────────────────────── Allowances ──────────────────────────────────────────

    /// @notice Grant max allowance to `vault` for `currency` (idempotent).
    /// @dev `forceApprove` zeros first for USDT-style tokens. Consumers call once per
    ///      (currency, vault) at bind. No-op for `address(0)` vault.
    /// @param currency The underlying asset to approve.
    /// @param vault    The ERC-4626 vault to grant allowance to.
    function approveVault(Currency currency, address vault) internal {
        if (vault == address(0)) return;
        IERC20 token = IERC20(Currency.unwrap(currency));
        if (token.allowance(address(this), vault) == 0) {
            token.forceApprove(vault, type(uint256).max);
        }
    }

    /// @notice Zero the consumer's standing approval to `vault`. The emergency counterpart to
    ///         {approveVault}.
    /// @dev Caller MUST also stop deposits, or the LP path re-arms it via {ensureVaultAllowance}.
    ///      No-op for `address(0)` vault.
    /// @param currency The underlying asset whose approval to revoke.
    /// @param vault    The ERC-4626 vault to revoke allowance from.
    function revokeVaultApproval(Currency currency, address vault) internal {
        if (vault == address(0)) return;
        IERC20(Currency.unwrap(currency)).forceApprove(vault, 0);
    }

    /// @notice Refresh allowance to `>= amount` (recovery for USDT-style tokens whose max
    ///         allowance is decremented on transfer).
    /// @dev No-op for the common non-decrementing case.
    /// @param currency The underlying asset to approve.
    /// @param vault    The ERC-4626 vault to grant allowance to.
    /// @param amount   The minimum allowance required for the current operation (native decimals).
    function ensureVaultAllowance(Currency currency, address vault, uint256 amount) internal {
        IERC20 token = IERC20(Currency.unwrap(currency));
        if (token.allowance(address(this), vault) < amount) {
            token.forceApprove(vault, type(uint256).max);
        }
    }

    /// @notice Force `currency`'s allowance to `vault` back to max, regardless of the current
    ///         value. The manual, owner-driven counterpart to bind-time {approveVault} and
    ///         just-in-time {ensureVaultAllowance}.
    /// @dev `forceApprove` zeroes-then-sets internally, so a single call covers USDT-style tokens
    ///      that reject a non-zero-to-non-zero `approve`. No-op for `address(0)` vault.
    /// @param currency The underlying asset to re-approve.
    /// @param vault    The ERC-4626 vault to grant allowance to.
    function refreshVaultApproval(Currency currency, address vault) internal {
        if (vault == address(0)) return;
        IERC20(Currency.unwrap(currency)).forceApprove(vault, type(uint256).max);
    }

    /// @notice Reject ERC-4626 vaults that apply entry or exit fees.
    /// @dev Leverages the EIP-4626 rule that `convertTo*` MUST NOT factor fees while `preview*`
    ///      MUST. No-op for an unset vault. Catches honest fee disclosures only (see PoolVault
    ///      `Vault Compatibility` for the adversarial-vault socialization that remains). Reverts
    ///      {VaultChargesEntryFee} / {VaultChargesExitFee} on divergence.
    ///
    ///      The exit-side probe tolerates a reverting `previewRedeem`: liquidity-gated vaults
    ///      (Spark savings vaults) revert it whenever idle liquidity cannot cover the amount,
    ///      which is a liquidity report, not a fee disclosure. Skipping the comparison keeps
    ///      pool initialization from bricking against such a vault in a low-idle state; the
    ///      entry-side check still runs, and a vault that hides a fee behind a reverting
    ///      preview is already covered by the vault-trust model.
    /// @param vault The ERC-4626 vault to probe.
    function requireFeelessVault(IERC4626 vault) internal view {
        if (address(vault) == address(0)) return;
        uint256 probe = 10 ** uint256(vault.decimals());
        if (vault.previewDeposit(probe) != vault.convertToShares(probe)) revert VaultChargesEntryFee();
        try vault.previewRedeem(probe) returns (uint256 redeemable) {
            if (redeemable != vault.convertToAssets(probe)) revert VaultChargesExitFee();
        } catch {}
    }
}
