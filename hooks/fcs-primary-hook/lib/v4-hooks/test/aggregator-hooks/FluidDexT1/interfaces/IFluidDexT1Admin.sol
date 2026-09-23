// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DexAdminStructs} from "../libraries/DexAdminStructs.sol";

/// @notice Minimal interface for Fluid DexT1 Admin
interface IFluidDexT1Admin {
    function initialize(DexAdminStructs.InitializeVariables memory i_) external payable;
    function toggleOracleActivation(bool turnOn_) external;
}
