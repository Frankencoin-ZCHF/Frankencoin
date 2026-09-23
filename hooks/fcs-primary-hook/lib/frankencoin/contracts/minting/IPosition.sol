// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../erc20/IERC20.sol";
import "../stablecoin/IFrankencoin.sol";

interface IPosition {

    function initialize(address parent, uint40 _expiration) external;

    function hub() external view returns(address);

    function original() external view returns (address);

    function collateral() external view returns (IERC20);

    function minimumCollateral() external view returns (uint256);

    function challengePeriod() external view returns (uint40);

    function expiration() external view returns (uint40);

    function price() external view returns (uint256);

    function deny(address[] calldata helpers, string calldata message) external;

    function mint(address target, uint256 amount) external;

    function repay(uint256 amount) external returns (uint256);

    function adjust(uint256 newMinted, uint256 newCollateral, uint256 newPrice) external;

    function minted() external view returns (uint256);

    function availableForMinting() external view returns (uint256);

    function reserveContribution() external view returns (uint24);

    function withdrawCollateral(address target, uint256 amount) external;

    function getUsableMint(uint256 totalMint, bool beforeFees) external view returns (uint256);

    function getMintAmount(uint256 usableMint) external view returns (uint256);

    function challengeData() external view returns (uint256 liqPrice, uint40 phase);

    function notifyChallengeStarted(uint256 size) external;

    function notifyChallengeAverted(uint256 size) external;

    function notifyChallengeSucceeded(address _bidder, uint256 _size) external returns (address, uint256, uint256, uint32);

    function forceSale(address buyer, uint256 collAmount, uint256 proceeds) external;

}