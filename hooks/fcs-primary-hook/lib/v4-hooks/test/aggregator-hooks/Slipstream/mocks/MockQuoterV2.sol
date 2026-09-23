// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IQuoterV2} from "../../../../src/aggregator-hooks/implementations/Slipstream/interfaces/IQuoterV2.sol";

/// @notice Same math as UniswapV3 `MockQuoterV2` but Slipstream quoter ABI (`tickSpacing` field).
contract MockQuoterV2 is IQuoterV2 {
    function quoteExactInputSingle(IQuoterV2.QuoteExactInputSingleParams memory p)
        external
        pure
        returns (uint256 amountOut)
    {
        p.tickSpacing;
        amountOut = p.amountIn * 99 / 100;
    }

    function quoteExactOutputSingle(IQuoterV2.QuoteExactOutputSingleParams memory p)
        external
        pure
        returns (uint256 amountIn)
    {
        p.tickSpacing;
        amountIn = (p.amountOut * 100 + 98) / 99;
    }
}
