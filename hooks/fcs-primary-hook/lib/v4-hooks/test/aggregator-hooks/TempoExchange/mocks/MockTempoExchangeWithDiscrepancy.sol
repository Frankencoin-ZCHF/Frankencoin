// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    ITempoExchange
} from "../../../../src/aggregator-hooks/implementations/TempoExchange/interfaces/ITempoExchange.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockTempoExchangeWithDiscrepancy
/// @notice Mock that simulates per-tick vs per-order rounding discrepancy in exact-out swaps
/// @dev quoteSwapExactAmountOut returns a lower value than swapExactAmountOut actually charges
contract MockTempoExchangeWithDiscrepancy is ITempoExchange {
    using SafeERC20 for IERC20;

    uint128 public constant FEE_BPS = 10; // 0.1% fee
    uint128 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Extra amount (in absolute units) that execution charges over the quote
    uint128 public discrepancy;

    error InsufficientOutput();
    error ExcessiveInput();
    error UnsupportedPair(address tokenA, address tokenB);

    mapping(address => mapping(address => bool)) public supportedPairs;

    constructor(uint128 _discrepancy) {
        discrepancy = _discrepancy;
    }

    function setDiscrepancy(uint128 _discrepancy) external {
        discrepancy = _discrepancy;
    }

    function addSupportedPair(address tokenA, address tokenB) external {
        supportedPairs[tokenA][tokenB] = true;
        supportedPairs[tokenB][tokenA] = true;
    }

    function swapExactAmountIn(address tokenIn, address tokenOut, uint128 amountIn, uint128 minAmountOut)
        external
        override
        returns (uint128 amountOut)
    {
        _requireSupportedPair(tokenIn, tokenOut);
        amountOut = _calculateOutputFromInput(amountIn);
        if (amountOut < minAmountOut) revert InsufficientOutput();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }

    function swapExactAmountOut(address tokenIn, address tokenOut, uint128 amountOut, uint128 maxAmountIn)
        external
        override
        returns (uint128 amountIn)
    {
        _requireSupportedPair(tokenIn, tokenOut);
        // Execution charges MORE than the quote due to per-order rounding
        amountIn = _calculateInputFromOutput(amountOut) + discrepancy;
        if (amountIn > maxAmountIn) revert ExcessiveInput();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }

    function quoteSwapExactAmountIn(address tokenIn, address tokenOut, uint128 amountIn)
        external
        view
        override
        returns (uint128 amountOut)
    {
        _requireSupportedPair(tokenIn, tokenOut);
        return _calculateOutputFromInput(amountIn);
    }

    function quoteSwapExactAmountOut(address tokenIn, address tokenOut, uint128 amountOut)
        external
        view
        override
        returns (uint128 amountIn)
    {
        _requireSupportedPair(tokenIn, tokenOut);
        // Quote returns the LOWER value (no discrepancy added)
        return _calculateInputFromOutput(amountOut);
    }

    function _requireSupportedPair(address tokenA, address tokenB) internal view {
        if (!supportedPairs[tokenA][tokenB]) revert UnsupportedPair(tokenA, tokenB);
    }

    function _calculateOutputFromInput(uint128 amountIn) internal pure returns (uint128) {
        return uint128((uint256(amountIn) * (BPS_DENOMINATOR - FEE_BPS)) / BPS_DENOMINATOR);
    }

    function _calculateInputFromOutput(uint128 amountOut) internal pure returns (uint128) {
        return
            uint128(
                (uint256(amountOut) * BPS_DENOMINATOR + BPS_DENOMINATOR - FEE_BPS - 1) / (BPS_DENOMINATOR - FEE_BPS)
            );
    }
}
