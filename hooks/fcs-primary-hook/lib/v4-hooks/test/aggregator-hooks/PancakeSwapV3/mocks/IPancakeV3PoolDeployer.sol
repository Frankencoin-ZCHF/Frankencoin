// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev `PancakeV3PoolDeployer#setFactoryAddress` is used in tests but is not declared on `IPancakeV3PoolDeployer`.
interface IPancakeV3PoolDeployer {
    function setFactoryAddress(address _factoryAddress) external;
}
