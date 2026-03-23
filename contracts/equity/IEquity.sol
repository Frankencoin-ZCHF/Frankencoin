// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../erc20/IERC20.sol";
import "./IGovernance.sol";

interface IEquity is IERC20, IGovernance {

    function price() external view returns (uint256);

    function invest(uint256 amount, uint256 expectedShares) external returns (uint256);

    function redeem(address target, uint256 shares) external returns (uint256);

    function redeemExpected(address target, uint256 shares, uint256 expectedProceeds) external returns (uint256);

    function redeemFrom(address owner, address target, uint256 shares, uint256 expectedProceeds) external returns (uint256);

    function calculateShares(uint256 investment) external view returns (uint256);

    function calculateProceeds(uint256 shares) external view returns (uint256);

    function canRedeem(address owner) external view returns (bool);

    function holdingDuration(address holder) external view returns (uint256);

    function relativeVotes(address holder) external view returns (uint256);

    function restructureCapTable(address[] calldata helpers, address[] calldata addressesToWipe) external;

    function kamikaze(address[] calldata targets, uint256 votesToDestroy) external;
}
