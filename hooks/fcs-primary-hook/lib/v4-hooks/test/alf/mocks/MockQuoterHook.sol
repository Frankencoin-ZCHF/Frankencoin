// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseALFHook} from "../../../src/alf/base/BaseALFHook.sol";

/// @title MockQuoterHook
/// @notice Minimal concrete implementation of BaseALFHook for testing the base class.
contract MockQuoterHook is BaseALFHook {
    uint256 public priceReturn;
    uint256 public attestedPriceReturn;
    bool public live;

    // Settable effective liquidity so tests can decouple the (possibly inflated) indicative from
    // honestly-reported deliverable reserves — exercises the multiplexer's reserve-bounded
    // strict-tolerance baseline. Defaults to (0, 0), matching BaseALFHook (no off-pool reserves).
    uint256 public effLiq0;
    uint256 public effLiq1;

    // Track calls for assertions
    bool public lastCallAttested;
    address public lastCallAttester;

    constructor(IPoolManager _poolManager, uint32 maxGas_) BaseALFHook(_poolManager, maxGas_) {
        live = true;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function isLive() external view override returns (bool) {
        return live;
    }

    function setPrice(uint256 price_, uint256 attestedPrice_) external {
        priceReturn = price_;
        attestedPriceReturn = attestedPrice_;
    }

    function setLive(bool _live) external {
        live = _live;
    }

    function setEffectiveLiquidity(uint256 e0, uint256 e1) external {
        effLiq0 = e0;
        effLiq1 = e1;
    }

    function getEffectiveLiquidity(PoolKey calldata) external view override returns (uint256, uint256) {
        return (effLiq0, effLiq1);
    }

    function _price(PoolKey calldata, bool, int256, bool isAttested, address) internal view override returns (uint256) {
        return isAttested ? attestedPriceReturn : priceReturn;
    }

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
