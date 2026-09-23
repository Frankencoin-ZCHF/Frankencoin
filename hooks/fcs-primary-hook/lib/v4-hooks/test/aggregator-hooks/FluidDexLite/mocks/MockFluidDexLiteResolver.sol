// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    IFluidDexLite
} from "../../../../src/aggregator-hooks/implementations/FluidDexLite/interfaces/IFluidDexLite.sol";
import {
    IFluidDexLiteResolver
} from "../../../../src/aggregator-hooks/implementations/FluidDexLite/interfaces/IFluidDexLiteResolver.sol";

/// @title MockFluidDexLiteResolver
/// @notice Mock Fluid DEX Lite resolver with settable getDexState, getPricesAndReserves, estimateSwapSingle for unit tests.
contract MockFluidDexLiteResolver is IFluidDexLiteResolver {
    bool public returnEmptyDexState; // if true, return state that isEmpty() => true
    uint256 public returnToken0Reserves;
    uint256 public returnToken1Reserves;
    uint256 public returnEstimateSwapSingle;
    bool public revertGetDexState;
    bool public revertEstimateSwapSingle;

    error GetDexStateRevert();
    error EstimateSwapSingleRevert();

    function setReturnEmptyDexState(bool empty) external {
        returnEmptyDexState = empty;
    }

    function setReturnReserves(uint256 amount0, uint256 amount1) external {
        returnToken0Reserves = amount0;
        returnToken1Reserves = amount1;
    }

    function setReturnEstimateSwapSingle(uint256 amount) external {
        returnEstimateSwapSingle = amount;
    }

    function setRevertGetDexState(bool doRevert) external {
        revertGetDexState = doRevert;
    }

    function setRevertEstimateSwapSingle(bool doRevert) external {
        revertEstimateSwapSingle = doRevert;
    }

    function getAllDexes() external pure override returns (IFluidDexLite.DexKey[] memory) {
        return new IFluidDexLite.DexKey[](0);
    }

    function getDexState(IFluidDexLite.DexKey memory)
        external
        view
        override
        returns (IFluidDexLite.DexState memory state)
    {
        if (revertGetDexState) revert GetDexStateRevert();
        // Non-empty: at least one of fee, token0Decimals, token1Decimals non-zero
        state.dexVariables.fee = returnEmptyDexState ? 0 : 1;
        state.dexVariables.token0Decimals = returnEmptyDexState ? 0 : 18;
        state.dexVariables.token1Decimals = returnEmptyDexState ? 0 : 18;
        return state;
    }

    function getDexEntireData(IFluidDexLite.DexKey memory dexKey)
        external
        view
        override
        returns (IFluidDexLite.DexEntireData memory)
    {
        (dexKey);
        IFluidDexLite.DexEntireData memory data;
        data.dexKey = dexKey;
        data.reserves.token0RealReserves = returnToken0Reserves;
        data.reserves.token1RealReserves = returnToken1Reserves;
        return data;
    }

    function getPricesAndReserves(IFluidDexLite.DexKey memory)
        external
        view
        override
        returns (IFluidDexLite.Prices memory, IFluidDexLite.Reserves memory reserves)
    {
        reserves.token0RealReserves = returnToken0Reserves;
        reserves.token1RealReserves = returnToken1Reserves;
        return (IFluidDexLite.Prices(0, 0, 0, 0, 0, 0), reserves);
    }

    function estimateSwapSingle(IFluidDexLite.DexKey calldata, bool, int256) external view override returns (uint256) {
        if (revertEstimateSwapSingle) revert EstimateSwapSingleRevert();
        return returnEstimateSwapSingle;
    }

    function estimateSwapHop(address[] calldata, IFluidDexLite.DexKey[] calldata, int256)
        external
        pure
        override
        returns (uint256)
    {
        return 0;
    }
}
