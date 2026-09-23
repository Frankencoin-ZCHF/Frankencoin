// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../../erc20/IERC20.sol";

interface IPositionV2 {
    function hub() external view returns (address);

    function collateral() external view returns (IERC20);

    function minimumCollateral() external view returns (uint256);

    function price() external view returns (uint256);

    function minted() external view returns (uint256);

    function challengedAmount() external view returns (uint256);

    function original() external view returns (address);

    function expiration() external view returns (uint40);

    function cooldown() external view returns (uint40);

    function limit() external view returns (uint256);

    function challengePeriod() external view returns (uint40);

    function start() external view returns (uint40);

    function riskPremiumPPM() external view returns (uint24);

    function reserveContribution() external view returns (uint24);

    function initialize(address parent, uint40 _expiration) external;

    function assertCloneable() external;

    function notifyMint(uint256 mint_) external;

    function notifyRepaid(uint256 repaid_) external;

    function availableForClones() external view returns (uint256);

    function availableForMinting() external view returns (uint256);

    function deny(address[] calldata helpers, string calldata message) external;

    function getUsableMint(uint256 totalMint, bool afterFees) external view returns (uint256);

    function getMintAmount(uint256 usableMint) external view returns (uint256);

    function adjust(uint256 newMinted, uint256 newCollateral, uint256 newPrice) external;

    function adjustPrice(uint256 newPrice) external;

    function mint(address target, uint256 amount) external;

    function calculateCurrentFee() external view returns (uint24);

    function annualInterestPPM() external view returns (uint24);

    function calculateFee(uint256 exp) external view returns (uint24);

    function repay(uint256 amount) external returns (uint256);

    function forceSale(address buyer, uint256 collAmount, uint256 proceeds) external;

    function withdraw(address token, address target, uint256 amount) external;

    function withdrawCollateral(address target, uint256 amount) external;

    function challengeData() external view returns (uint256 liqPrice, uint40 phase);

    function notifyChallengeStarted(uint256 size) external;

    function notifyChallengeAverted(uint256 size) external;

    function notifyChallengeSucceeded(address _bidder, uint256 _size) external returns (address, uint256, uint256, uint32);
}
