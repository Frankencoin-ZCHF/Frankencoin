// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal interface for Fluid DexT1 Deployment Logic
interface IFluidDexT1DeploymentLogic {
    function dexT1(address token0_, address token1_, uint256 oracleMapping_) external returns (bytes memory);
}
