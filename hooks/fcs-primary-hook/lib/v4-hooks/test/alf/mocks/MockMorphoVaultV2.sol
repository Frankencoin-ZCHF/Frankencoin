// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @notice ERC-4626-shaped mock that emulates the externally observable behaviour of a
///         Morpho VaultV2 deployment for testing PoolVault integrations.
///
///         Two divergences from a "textbook" 1:1 ERC-4626 are reproduced:
///
///         1. `maxWithdraw(address)` always returns `0`. VaultV2 cannot honestly bound a
///            single-block withdrawal cap across its internal allocations, so it returns
///            zero by construction. Callers that rely on `maxWithdraw` as a pre-flight
///            cap will silently degrade to zero deployable liquidity.
///         2. `withdraw` may be armed to revert -- emulates a curated/gated vault that
///            cannot satisfy the request from its current allocation. Use
///            `setWithdrawShortfall(true)` to arm.
///
///         Optional knobs:
///           - `setExitFeeBps(bps)` -- applies an exit-fee to `previewRedeem` (so
///             `previewRedeem < convertToAssets` is testable). `convertToAssets` is
///             unchanged so callers can verify the asymmetry between the LP share-math
///             view and the deployable-now view.
contract MockMorphoVaultV2 is ERC20 {
    /// @notice The underlying asset wrapped by this vault.
    ERC20 public immutable asset;

    uint256 internal _yieldAccrued;
    bool internal _withdrawShortfall;
    bool internal _depositShortfall;
    /// @notice Per-redeem exit fee in basis points (max 10_000). Applies only to
    ///         `previewRedeem`; `convertToAssets` returns the gross value unchanged.
    uint16 public exitFeeBps;
    /// @notice Per-deposit entry fee in basis points (max 10_000). Applies only to
    ///         `previewDeposit`; `convertToShares` returns the gross value unchanged.
    uint16 public entryFeeBps;
    /// @notice When > 0, `withdraw` reverts if `assets > maxWithdrawable`. Emulates a curated
    ///         vault whose idle reserves are smaller than its accounting `totalAssets`
    ///         (because the rest is allocated out to non-idle positions). `0` disables the cap.
    uint256 public maxWithdrawable;

    error WithdrawShortfall();
    error DepositShortfall();
    error WithdrawExceedsIdleReserves(uint256 requested, uint256 maxWithdrawable);
    error ExitFeeTooLarge();
    error EntryFeeTooLarge();

    constructor(ERC20 _asset)
        ERC20(
            string.concat("Mock Morpho V2 ", _asset.name()), string.concat("mmv2", _asset.symbol()), _asset.decimals()
        )
    {
        asset = _asset;
    }

    // ─── Configuration knobs (test-only) ────────────────────────────────────────

    /// @notice Arm or disarm the `withdraw`-shortfall revert (unconditional).
    function setWithdrawShortfall(bool armed) external {
        _withdrawShortfall = armed;
    }

    /// @notice Arm or disarm the `deposit`-shortfall revert (unconditional). Emulates a vault
    ///         that has hit its `maxDeposit` cap or whose curated allocator rejects the deposit.
    function setDepositShortfall(bool armed) external {
        _depositShortfall = armed;
    }

    /// @notice Cap the per-call withdrawable amount. When non-zero, `withdraw(assets, ...)`
    ///         reverts with `WithdrawExceedsIdleReserves` if `assets > maxWithdrawable`.
    function setMaxWithdrawable(uint256 cap) external {
        maxWithdrawable = cap;
    }

    /// @notice Set the per-redeem exit fee in basis points. Capped at 10_000.
    function setExitFeeBps(uint16 bps) external {
        if (bps > 10_000) revert ExitFeeTooLarge();
        exitFeeBps = bps;
    }

    /// @notice Set the per-deposit entry fee in basis points. Capped at 10_000.
    function setEntryFeeBps(uint16 bps) external {
        if (bps > 10_000) revert EntryFeeTooLarge();
        entryFeeBps = bps;
    }

    /// @notice Mint additional underlying directly into the vault, simulating yield accrual.
    function simulateYield(uint256 amount) external {
        MockMintable(address(asset)).mint(address(this), amount);
    }

    // ─── ERC-4626 surface ───────────────────────────────────────────────────────

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        if (_depositShortfall) revert DepositShortfall();
        shares = convertToShares(assets);
        asset.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner_) external returns (uint256 shares) {
        if (_withdrawShortfall) revert WithdrawShortfall();
        if (maxWithdrawable > 0 && assets > maxWithdrawable) {
            revert WithdrawExceedsIdleReserves(assets, maxWithdrawable);
        }
        shares = convertToShares(assets);
        if (msg.sender != owner_) {
            uint256 allowed = allowance[owner_][msg.sender];
            if (allowed != type(uint256).max) {
                allowance[owner_][msg.sender] = allowed - shares;
            }
        }
        _burn(owner_, shares);
        asset.transfer(receiver, assets);
    }

    function redeem(uint256 shares, address receiver, address owner_) external returns (uint256 assets) {
        if (_withdrawShortfall) revert WithdrawShortfall();
        assets = previewRedeem(shares);
        if (maxWithdrawable > 0 && assets > maxWithdrawable) {
            revert WithdrawExceedsIdleReserves(assets, maxWithdrawable);
        }
        if (msg.sender != owner_) {
            uint256 allowed = allowance[owner_][msg.sender];
            if (allowed != type(uint256).max) {
                allowance[owner_][msg.sender] = allowed - shares;
            }
        }
        _burn(owner_, shares);
        asset.transfer(receiver, assets);
    }

    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this)) + _yieldAccrued;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply;
        return supply == 0 ? assets : (assets * supply) / totalAssets();
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply;
        return supply == 0 ? shares : (shares * totalAssets()) / supply;
    }

    /// @notice `previewRedeem` reports the net amount after applying `exitFeeBps`, so
    ///         `previewRedeem <= convertToAssets`. Used by PoolVault for deployable-now sizing.
    function previewRedeem(uint256 shares) public view returns (uint256) {
        uint256 gross = convertToAssets(shares);
        if (exitFeeBps == 0) return gross;
        return gross - (gross * exitFeeBps) / 10_000;
    }

    /// @notice `previewDeposit` reports the net shares minted after applying `entryFeeBps`,
    ///         so `previewDeposit <= convertToShares`. Used by PoolVault's feeless-vault probe.
    function previewDeposit(uint256 assets) public view returns (uint256) {
        uint256 gross = convertToShares(assets);
        if (entryFeeBps == 0) return gross;
        return gross - (gross * entryFeeBps) / 10_000;
    }

    function previewWithdraw(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    /// @notice VaultV2 divergence: `maxWithdraw` is hard-zero regardless of underlying state.
    function maxWithdraw(address) external pure returns (uint256) {
        return 0;
    }

    function maxRedeem(address owner_) external view returns (uint256) {
        return balanceOf[owner_];
    }
}

interface MockMintable {
    function mint(address to, uint256 amount) external;
}
