// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IQuoterV2
/// @notice Uniswap V3 Periphery QuoterV2-compatible quoting
interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    struct QuoteExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountOut;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Simulates a single-hop exact-input swap and returns the output amount without state changes
    /// @param params Single-hop exact-input quote parameters
    /// @return amountOut Amount of `tokenOut` that would be received for `params.amountIn`
    function quoteExactInputSingle(QuoteExactInputSingleParams memory params) external returns (uint256 amountOut);

    /// @notice Simulates a single-hop exact-output swap and returns the required input without state changes
    /// @param params Single-hop exact-output quote parameters
    /// @return amountIn Amount of `tokenIn` required to receive `params.amountOut`
    function quoteExactOutputSingle(QuoteExactOutputSingleParams memory params) external returns (uint256 amountIn);
}
