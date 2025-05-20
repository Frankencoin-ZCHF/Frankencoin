// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../erc20/IERC20.sol";
import "../equity/IGovernance.sol";

interface IBasicFrankencoin is IERC20 {
    function MIN_FEE() external view returns (uint256);

    function MIN_APPLICATION_PERIOD() external view returns (uint256);

    function suggestMinter(
        address _minter,
        uint256 _applicationPeriod,
        uint256 _applicationFee,
        string calldata _message
    ) external;

    function registerPosition(address position) external;

    function denyMinter(address minter, address[] calldata helpers, string calldata message) external;

    function reserve() external view returns (IGovernance);

    function isMinter(address minter) external view returns (bool);

    function getPositionParent(address position) external view returns (address);

    function mint(address target, uint256 amount) external;

    function burnFrom(address target, uint256 amount) external;

    function burn(uint256 amount) external;

    function coverLoss(address source, uint256 amount) external;

    function collectProfits(address source, uint256 _amount) external;
}
