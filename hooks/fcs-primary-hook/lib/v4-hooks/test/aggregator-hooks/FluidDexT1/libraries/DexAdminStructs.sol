// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Structs for Fluid DexT1 Admin Module (defined locally to avoid pragma conflicts)
library DexAdminStructs {
    struct InitializeVariables {
        bool smartCol;
        uint256 token0ColAmt;
        bool smartDebt;
        uint256 token0DebtAmt;
        uint256 centerPrice;
        uint256 fee;
        uint256 revenueCut;
        uint256 upperPercent;
        uint256 lowerPercent;
        uint256 upperShiftThreshold;
        uint256 lowerShiftThreshold;
        uint256 thresholdShiftTime;
        uint256 centerPriceAddress;
        uint256 hookAddress;
        uint256 maxCenterPrice;
        uint256 minCenterPrice;
    }
}
