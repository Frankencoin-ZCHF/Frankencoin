// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "../../../erc20/IERC20.sol";
import {IFrankencoin} from "../../../stablecoin/IFrankencoin.sol";
import {ITwocrypto} from "./ITwocrypto.sol";

interface IAmplifierCurve {
    // --- Errors ---
    error AccessDenied();
    error AmplifierExpired();
    error CloneFailed();
    error ZCHFNotInPool();
    error InvalidDecimals();
    error InvalidExpiration();
    error InvalidLimit();
    error LimitExceeded(uint256 newValue, uint256 limit);
    error PriceDeviatedTooMuch(uint256 current, uint256 anchor);
    error InsufficientCollateral(uint256 required, uint256 provided);

    // --- Events ---
    event AmplifiedPositionCreated(address indexed position, address indexed owner);
    event Borrowed(address indexed position, uint256 amount, uint256 totalBorrowed);
    event Repaid(address indexed position, uint256 amount, uint256 totalBorrowed);

    // --- Immutables ---
    function CURVE_POOL() external view returns (ITwocrypto);

    function ZCHF() external view returns (IFrankencoin);

    function COLLATERAL() external view returns (IERC20);

    function ZCHF_INDEX() external view returns (uint256);

    function PRICE_ANCHOR() external view returns (uint256);

    function EXPIRATION() external view returns (uint40);

    function LIMIT() external view returns (uint256);

    function POSITION_IMPLEMENTATION() external view returns (address);

    // --- State ---
    function totalBorrowed() external view returns (uint256);

    function isPosition(address position) external view returns (bool);

    // --- View ---
    function getMinimumCollateral(uint256 zchfAmount) external view returns (uint256);

    function getMaximumMint(uint256 collateralAmount) external view returns (uint256);

    function checkPrice() external view;

    // --- Position-only (not for direct calls) ---
    function borrowIntoPosition(address owner, uint256 zchfAmount, uint256 collateralAmount) external;

    function repay(address owner, uint256 zchfAmount) external;

    // --- Public ---
    function createAmplifiedPosition() external returns (address position);
}
