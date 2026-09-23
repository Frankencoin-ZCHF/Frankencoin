// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal interface for Fluid Liquidity operate
interface IFluidLiquidity {
    function operate(
        address token_,
        int256 supplyAmount_,
        int256 borrowAmount_,
        address withdrawTo_,
        address borrowTo_,
        bytes calldata callbackData_
    ) external payable returns (uint256, uint256);
}
