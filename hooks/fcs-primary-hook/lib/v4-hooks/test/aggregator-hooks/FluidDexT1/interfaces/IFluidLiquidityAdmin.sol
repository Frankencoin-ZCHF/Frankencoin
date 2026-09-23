// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AdminModuleStructs} from "../libraries/AdminModuleStructs.sol";

/// @notice Minimal interface for Fluid Liquidity Admin Module
interface IFluidLiquidityAdmin {
    function updateRateDataV1s(AdminModuleStructs.RateDataV1Params[] calldata rateDataV1Params_) external;
    function updateTokenConfigs(AdminModuleStructs.TokenConfig[] calldata tokenConfigs_) external;
    function updateUserSupplyConfigs(AdminModuleStructs.UserSupplyConfig[] calldata userSupplyConfigs_) external;
    function updateUserBorrowConfigs(AdminModuleStructs.UserBorrowConfig[] calldata userBorrowConfigs_) external;
}
