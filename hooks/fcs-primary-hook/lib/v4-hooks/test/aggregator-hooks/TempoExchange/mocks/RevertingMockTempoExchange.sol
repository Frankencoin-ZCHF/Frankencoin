// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    ITempoExchange
} from "../../../../src/aggregator-hooks/implementations/TempoExchange/interfaces/ITempoExchange.sol";

/// @title RevertingMockTempoExchange
/// @notice Mock that always reverts, used to test unsupported token handling
contract RevertingMockTempoExchange is ITempoExchange {
    error TokensNotSupported();

    function swapExactAmountIn(address, address, uint128, uint128) external pure override returns (uint128) {
        revert TokensNotSupported();
    }

    function swapExactAmountOut(address, address, uint128, uint128) external pure override returns (uint128) {
        revert TokensNotSupported();
    }

    function quoteSwapExactAmountIn(address, address, uint128) external pure override returns (uint128) {
        revert TokensNotSupported();
    }

    function quoteSwapExactAmountOut(address, address, uint128) external pure override returns (uint128) {
        revert TokensNotSupported();
    }
}
