// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal interface for Fluid DexFactory
interface IFluidDexFactory {
    function setDeployer(address deployer_, bool allowed_) external;
    function deployDex(address dexDeploymentLogic_, bytes calldata dexDeploymentData_) external returns (address dex_);
    function setGlobalAuth(address auth_, bool allowed_) external;
}
