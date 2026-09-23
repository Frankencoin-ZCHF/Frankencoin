// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IFluidDexT1} from "../../../../src/aggregator-hooks/implementations/FluidDexT1/interfaces/IFluidDexT1.sol";
import {
    IFluidDexReservesResolver
} from "../../../../src/aggregator-hooks/implementations/FluidDexT1/interfaces/IFluidDexReservesResolver.sol";

/// @title MockFluidDexReservesResolver
/// @notice Mock Fluid DEX T1 reserves resolver with settable getDexTokens, getPoolReserves, estimateSwapIn/Out for unit tests.
contract MockFluidDexReservesResolver is IFluidDexReservesResolver {
    address public returnToken0;
    address public returnToken1;
    uint256 public returnToken0Reserves;
    uint256 public returnToken1Reserves;
    uint256 public returnEstimateSwapIn;
    uint256 public returnEstimateSwapOut;
    bool public revertGetDexTokens;
    bool public revertGetPoolReserves;
    bool public revertEstimateSwapIn;
    bool public revertEstimateSwapOut;

    error GetDexTokensRevert();
    error EstimateSwapInRevert();
    error EstimateSwapOutRevert();
    error GetPoolReservesRevert();

    function setDexTokens(address token0, address token1) external {
        returnToken0 = token0;
        returnToken1 = token1;
    }

    function setReserves(uint256 amount0, uint256 amount1) external {
        returnToken0Reserves = amount0;
        returnToken1Reserves = amount1;
    }

    function setReturnEstimateSwapIn(uint256 amount) external {
        returnEstimateSwapIn = amount;
    }

    function setReturnEstimateSwapOut(uint256 amount) external {
        returnEstimateSwapOut = amount;
    }

    function setRevertGetDexTokens(bool doRevert) external {
        revertGetDexTokens = doRevert;
    }

    function setRevertGetPoolReserves(bool doRevert) external {
        revertGetPoolReserves = doRevert;
    }

    function setRevertEstimateSwapIn(bool doRevert) external {
        revertEstimateSwapIn = doRevert;
    }

    function setRevertEstimateSwapOut(bool doRevert) external {
        revertEstimateSwapOut = doRevert;
    }

    function getDexTokens(address) external view returns (address token0_, address token1_) {
        if (revertGetDexTokens) revert GetDexTokensRevert();
        return (returnToken0, returnToken1);
    }

    function estimateSwapIn(address, bool, uint256, uint256) external payable returns (uint256 amountOut_) {
        if (revertEstimateSwapIn) revert EstimateSwapInRevert();
        return returnEstimateSwapIn;
    }

    function estimateSwapOut(address, bool, uint256, uint256) external payable returns (uint256 amountIn_) {
        if (revertEstimateSwapOut) revert EstimateSwapOutRevert();
        return returnEstimateSwapOut;
    }

    function getPoolReserves(address dex_) external view override returns (PoolWithReserves memory poolData_) {
        if (revertGetPoolReserves) revert GetPoolReservesRevert();
        poolData_.pool = dex_;
        poolData_.token0 = returnToken0;
        poolData_.token1 = returnToken1;
        poolData_.collateralReserves.token0RealReserves = returnToken0Reserves;
        poolData_.collateralReserves.token1RealReserves = returnToken1Reserves;
        poolData_.debtReserves.token0RealReserves = 0;
        poolData_.debtReserves.token1RealReserves = 0;
        return poolData_;
    }
}
