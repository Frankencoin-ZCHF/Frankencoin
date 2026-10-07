// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal interface checked against Sourcify exact-match Ethereum deployment.
interface IFCS is IERC20 {
    function asset() external view returns (address);
    function ZCHF() external view returns (address);
    function FPS1() external view returns (address);
    function isBinding() external view returns (bool);
    function maxRedeem(address) external view returns (uint256);
    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
}

interface IFPS {
    function canRedeem(address owner) external view returns (bool);
}
