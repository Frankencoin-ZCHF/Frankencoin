// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../equity/IGovernance.sol";
import "./IBasicFrankencoin.sol";

interface IFrankencoin is IBasicFrankencoin {

    function minterReserve() external view returns (uint256);

    function calculateAssignedReserve(uint256 mintedAmount, uint32 _reservePPM) external view returns (uint256);

    function calculateFreedAmount(uint256 amountExcludingReserve, uint32 reservePPM) external view returns (uint256);

    function equity() external view returns (uint256);

    function mintWithReserve(address target, uint256 amount, uint32 reservePPM, uint32 feePPM) external;

    function burnWithoutReserve(uint256 amountIncludingReserve, uint32 reservePPM) external;

    function burnFromWithReserve(address payer, uint256 targetTotalBurnAmount, uint32 _reservePPM) external returns (uint256);

    function burnWithReserve(uint256 amountExcludingReserve, uint32 reservePPM) external returns (uint256);

}
