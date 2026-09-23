// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @notice Minimal ERC4626 mock for testing. 1:1 share ratio with configurable yield simulation.
contract MockERC4626 is ERC20 {
    ERC20 public immutable asset;
    uint256 internal _yieldAccrued;

    constructor(ERC20 _asset)
        ERC20(string.concat("Mock Vault ", _asset.name()), string.concat("mv", _asset.symbol()), _asset.decimals())
    {
        asset = _asset;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = convertToShares(assets);
        asset.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner_) external returns (uint256 shares) {
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

    function maxRedeem(address owner_) external view returns (uint256) {
        return balanceOf[owner_];
    }

    function maxWithdraw(address owner_) external view returns (uint256) {
        return convertToAssets(balanceOf[owner_]);
    }

    function previewDeposit(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    function previewWithdraw(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return convertToAssets(shares);
    }

    /// @notice Simulate yield accrual by minting additional underlying to the vault.
    function simulateYield(uint256 amount) external {
        // Mint extra underlying to the vault to increase share value
        // The asset is a MockERC20 so we call mint on it
        MockMintable(address(asset)).mint(address(this), amount);
    }
}

interface MockMintable {
    function mint(address to, uint256 amount) external;
}
