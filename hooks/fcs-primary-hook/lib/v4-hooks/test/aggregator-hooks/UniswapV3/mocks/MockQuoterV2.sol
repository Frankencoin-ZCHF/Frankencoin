// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IQuoterV2} from "../../../../src/aggregator-hooks/implementations/UniswapV3/interfaces/IQuoterV2.sol";

/// @notice Matches MockUniV3Pool math (99/100 out on exact in; inverse on exact out)
contract MockQuoterV2 is IQuoterV2 {
    function quoteExactInputSingle(QuoteExactInputSingleParams memory p) external pure returns (uint256 amountOut) {
        p.fee;
        amountOut = p.amountIn * 99 / 100;
    }

    function quoteExactOutputSingle(QuoteExactOutputSingleParams memory p) external pure returns (uint256 amountIn) {
        p.fee;
        amountIn = (p.amountOut * 100 + 98) / 99;
    }
}
