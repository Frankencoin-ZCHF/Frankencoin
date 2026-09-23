// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseALFHook} from "../../../src/alf/base/BaseALFHook.sol";

/// @title FillableALFQuoter
/// @notice Tier-1 (IALFHook) test quoter whose pool actually fills swaps: `beforeSwap` is a
///         no-op, so nested multiplexer fills execute against the pool's ordinary v4 LP while
///         the ERC-165 surface advertises IALFHook. This decouples the three signals the
///         multiplexer consumes from one another so each can be steered independently:
///
///           - `setPrice` fixes the indicative quote (allowing an over- or under-stated
///             ranking signal relative to real execution),
///           - `setEffectiveLiquidity` fixes the declared deliverable reserves (bounding the
///             strict-tolerance baseline),
///           - `setRevertOnEffectiveLiquidity` arms the reserve read to revert (exercising the
///             baseline's soft-fail catch).
contract FillableALFQuoter is BaseALFHook {
    uint256 public priceReturn;
    uint256 public effLiq0;
    uint256 public effLiq1;
    bool public revertOnEffectiveLiquidity;
    bool public live = true;

    error EffectiveLiquidityReverted();

    constructor(IPoolManager _poolManager, uint32 maxGas_) BaseALFHook(_poolManager, maxGas_) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function setPrice(uint256 v) external {
        priceReturn = v;
    }

    function setEffectiveLiquidity(uint256 e0, uint256 e1) external {
        effLiq0 = e0;
        effLiq1 = e1;
    }

    function setRevertOnEffectiveLiquidity(bool v) external {
        revertOnEffectiveLiquidity = v;
    }

    function setLive(bool v) external {
        live = v;
    }

    function isLive() external view override returns (bool) {
        return live;
    }

    function getEffectiveLiquidity(PoolKey calldata) external view override returns (uint256, uint256) {
        if (revertOnEffectiveLiquidity) revert EffectiveLiquidityReverted();
        return (effLiq0, effLiq1);
    }

    function _price(PoolKey calldata, bool, int256, bool, address) internal view override returns (uint256) {
        return priceReturn;
    }

    /// @dev No-op: the swap executes against the pool's native v4 liquidity.
    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
