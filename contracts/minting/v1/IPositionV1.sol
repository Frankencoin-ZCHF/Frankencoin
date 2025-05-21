// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../../erc20/IERC20.sol";
import "./IReserve.sol";
import "./IFrankencoin.sol";

interface IPositionV1 {
    function original() external returns (address);

    function collateral() external returns (IERC20);

    function minimumCollateral() external returns (uint256);

    function challengePeriod() external returns (uint64);

    function expiration() external returns (uint256);

    function price() external returns (uint256);

    function reduceLimitForClone(uint256 amount) external;

    function initializeClone(address owner, uint256 _price, uint256 _coll, uint256 _mint, uint256 expiration) external;

    function deny(address[] calldata helpers, string calldata message) external;

    function mint(address target, uint256 amount) external;

    function minted() external returns (uint256);

    function reserveContribution() external returns (uint32);

    function getUsableMint(uint256 totalMint, bool beforeFees) external view returns (uint256);

    function challengeData(uint256 challengeStart) external view returns (uint256 liqPrice, uint64 phase1, uint64 phase2);

    function notifyChallengeStarted(uint256 size) external;

    function notifyChallengeAverted(uint256 size) external;

    function notifyChallengeSucceeded(address _bidder, uint256 _size) external returns (address, uint256, uint256, uint32);
}
