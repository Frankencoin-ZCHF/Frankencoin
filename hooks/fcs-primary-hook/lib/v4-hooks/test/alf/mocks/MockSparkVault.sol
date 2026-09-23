// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @notice ERC-4626-shaped mock that emulates the externally observable behavior of a Spark
///         savings vault (SparkVault) for testing PoolVault integrations.
///
///         Two divergences from a "textbook" ERC-4626 are reproduced, both consequences of the
///         vault deploying most of its underlying into non-idle allocations:
///
///         1. `previewRedeem(shares)` is liquidity-gated: it computes `convertToAssets(shares)`
///            and then reverts with "SparkVault/insufficient-liquidity" when the vault's idle
///            underlying balance cannot cover that amount. This deviates from EIP-4626 (previews
///            MUST NOT account for redemption limits) and means `previewRedeem` cannot be called
///            unconditionally whenever the owner's position exceeds idle liquidity.
///         2. `maxWithdraw(owner)` returns `min(idle liquidity, assetsOf(owner))`: the honest
///            per-owner atomic-withdrawal cap, and the view SparkVault expects integrators to
///            size against.
///
///         `withdraw`/`redeem` enforce the same idle-liquidity gate at execution time. Use
///         {allocate} to move underlying out of the vault (emulating capital deployment) without
///         changing `totalAssets`, so `idle < assetsOf(owner)` states are constructible.
contract MockSparkVault is ERC20 {
    /// @notice The underlying asset wrapped by this vault.
    ERC20 public immutable asset;

    /// @notice Underlying moved out of the vault into (simulated) yield allocations. Still part
    ///         of `totalAssets`, but not idle, so it cannot back an atomic withdrawal.
    uint256 public allocatedOut;

    constructor(ERC20 _asset)
        ERC20(
            string.concat("Mock Spark Vault ", _asset.name()), string.concat("msv", _asset.symbol()), _asset.decimals()
        )
    {
        asset = _asset;
    }

    // ─── Configuration knobs (test-only) ────────────────────────────────────────

    /// @notice Move `amount` of idle underlying out to `sink`, emulating the vault deploying
    ///         capital into a yield allocation. `totalAssets` is unchanged; idle liquidity drops.
    function allocate(address sink, uint256 amount) external {
        allocatedOut += amount;
        asset.transfer(sink, amount);
    }

    /// @notice Return `amount` of previously allocated underlying to the vault's idle balance.
    ///         The caller must have approved this vault for `amount`.
    function recall(address from, uint256 amount) external {
        allocatedOut -= amount;
        asset.transferFrom(from, address(this), amount);
    }

    // ─── ERC-4626 surface ───────────────────────────────────────────────────────

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = convertToShares(assets);
        asset.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner_) external returns (uint256 shares) {
        require(asset.balanceOf(address(this)) >= assets, "SparkVault/insufficient-liquidity");
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
        assets = convertToAssets(shares);
        require(asset.balanceOf(address(this)) >= assets, "SparkVault/insufficient-liquidity");
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
        return asset.balanceOf(address(this)) + allocatedOut;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply;
        return supply == 0 ? assets : (assets * supply) / totalAssets();
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply;
        return supply == 0 ? shares : (shares * totalAssets()) / supply;
    }

    /// @notice The gross asset value of `owner_`'s share position, ungated by idle liquidity.
    function assetsOf(address owner_) public view returns (uint256) {
        return convertToAssets(balanceOf[owner_]);
    }

    /// @notice SparkVault divergence: liquidity-gated preview. Reverts whenever the vault's idle
    ///         balance cannot cover the redemption value.
    function previewRedeem(uint256 shares) external view returns (uint256 amount) {
        amount = convertToAssets(shares);
        require(asset.balanceOf(address(this)) >= amount, "SparkVault/insufficient-liquidity");
    }

    function previewDeposit(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    function previewWithdraw(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    /// @notice SparkVault semantics: the per-owner atomic-withdrawal cap,
    ///         `min(idle liquidity, assetsOf(owner))`.
    function maxWithdraw(address owner_) external view returns (uint256) {
        uint256 liquidity = asset.balanceOf(address(this));
        uint256 userAssets = assetsOf(owner_);
        return liquidity > userAssets ? userAssets : liquidity;
    }

    function maxRedeem(address owner_) external view returns (uint256) {
        uint256 liquidity = asset.balanceOf(address(this));
        uint256 userAssets = assetsOf(owner_);
        return convertToShares(liquidity > userAssets ? userAssets : liquidity);
    }
}
