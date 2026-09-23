// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3Pool} from "../../../../src/aggregator-hooks/implementations/UniswapV3/interfaces/IUniswapV3Pool.sol";
import {
    IUniswapV3SwapCallback
} from "../../../../src/aggregator-hooks/implementations/UniswapV3/interfaces/IUniswapV3SwapCallback.sol";

/// @notice Lightweight Uniswap V3–compatible pool for aggregator hook unit tests
contract MockUniV3Pool is IUniswapV3Pool {
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    int24 private immutable _tickSpacing;
    bool isUnderfill;

    constructor(address _token0, address _token1, uint24 _fee, int24 tickSpacing_) {
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
        _tickSpacing = tickSpacing_;
    }

    function tickSpacing() external view override returns (int24) {
        return _tickSpacing;
    }

    function setIsUnderfill(bool _isUnderfill) external {
        isUnderfill = _isUnderfill;
    }

    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external override returns (int256 amount0, int256 amount1) {
        sqrtPriceLimitX96;
        address hook = msg.sender;

        // Match canonical Uniswap V3 Pool `swap`: positive amountSpecified = exact input; negative = exact output.
        if (amountSpecified > 0) {
            uint256 amtIn = uint256(amountSpecified);
            if (zeroForOne) {
                uint256 amtOut = _computeOut(amtIn);
                IUniswapV3SwapCallback(hook).uniswapV3SwapCallback(int256(amtIn), -int256(amtOut), data);
                IERC20(token1).transfer(recipient, amtOut);
                return (int256(amtIn), -int256(amtOut));
            } else {
                uint256 amtOut = _computeOut(amtIn);
                IUniswapV3SwapCallback(hook).uniswapV3SwapCallback(-int256(amtOut), int256(amtIn), data);
                IERC20(token0).transfer(recipient, amtOut);
                return (-int256(amtOut), int256(amtIn));
            }
        } else {
            uint256 amtOut = uint256(-amountSpecified);
            if (isUnderfill) {
                amtOut = amtOut / 2;
            }
            if (zeroForOne) {
                uint256 amtIn = _computeInForExactOut(amtOut);
                IUniswapV3SwapCallback(hook).uniswapV3SwapCallback(int256(amtIn), -int256(amtOut), data);
                IERC20(token1).transfer(recipient, amtOut);
                return (int256(amtIn), -int256(amtOut));
            } else {
                uint256 amtIn = _computeInForExactOut(amtOut);
                IUniswapV3SwapCallback(hook).uniswapV3SwapCallback(-int256(amtOut), int256(amtIn), data);
                IERC20(token0).transfer(recipient, amtOut);
                return (-int256(amtOut), int256(amtIn));
            }
        }
    }

    function _computeOut(uint256 amtIn) internal pure returns (uint256) {
        return amtIn * 99 / 100;
    }

    function _computeInForExactOut(uint256 amtOut) internal pure returns (uint256) {
        return (amtOut * 100 + 98) / 99;
    }
}
