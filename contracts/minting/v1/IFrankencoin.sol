// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../../erc20/IERC20.sol";
import "./IReserve.sol";

interface IFrankencoin is IERC20 {
    function MIN_FEE() external view returns (uint256);

    function MIN_APPLICATION_PERIOD() external view returns (uint256);

    function suggestMinter(address _minter, uint256 _applicationPeriod, uint256 _applicationFee, string calldata _message) external;

    function registerPosition(address position) external;

    function denyMinter(address minter, address[] calldata helpers, string calldata message) external;

    function reserve() external view returns (IReserve);

    function minterReserve() external view returns (uint256);

    function calculateAssignedReserve(uint256 mintedAmount, uint32 _reservePPM) external view returns (uint256);

    function calculateFreedAmount(uint256 amountExcludingReserve, uint32 reservePPM) external view returns (uint256);

    function equity() external view returns (uint256);

    function isMinter(address minter) external view returns (bool);

    function getPositionParent(address position) external view returns (address);

    function mint(address target, uint256 amount) external;

    function mintWithReserve(address target, uint256 amount, uint32 reservePPM, uint32 feePPM) external;

    function burnFrom(address target, uint256 amount) external;

    function burnWithoutReserve(uint256 amountIncludingReserve, uint32 reservePPM) external;

    function burnFromWithReserve(address payer, uint256 targetTotalBurnAmount, uint32 _reservePPM) external returns (uint256);

    function burnWithReserve(uint256 amountExcludingReserve, uint32 reservePPM) external returns (uint256);

    function coverLoss(address source, uint256 amount) external;

    function collectProfits(address source, uint256 _amount) external;
}
