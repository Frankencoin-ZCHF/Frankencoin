// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IERC4626 - Tokenized Vault Standard
 * @dev See https://eips.ethereum.org/EIPS/eip-4626
 * The ERC-20 methods are omitted here as the implementing contract already inherits ERC20.
 */
interface IERC4626 {

    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);

    function asset() external view returns (address assetTokenAddress);

    function totalAssets() external view returns (uint256 totalManagedAssets);

    function convertToShares(uint256 assets) external view returns (uint256 shares);

    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    function maxDeposit(address receiver) external view returns (uint256 maxAssets);

    function maxMint(address receiver) external view returns (uint256 maxShares);

    function maxWithdraw(address owner) external view returns (uint256 maxAssets);

    function maxRedeem(address owner) external view returns (uint256 maxShares);

    function previewDeposit(uint256 assets) external view returns (uint256 shares);

    function previewMint(uint256 shares) external view returns (uint256 assets);

    function previewRedeem(uint256 shares) external view returns (uint256 assets);

    function previewWithdraw(uint256 assets) external view returns (uint256 shares);

    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    function mint(uint256 shares, address receiver) external returns (uint256 assets);

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}
