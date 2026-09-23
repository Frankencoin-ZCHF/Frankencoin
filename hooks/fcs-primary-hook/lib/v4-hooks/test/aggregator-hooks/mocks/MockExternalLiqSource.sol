// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title MockExternalLiqSource
/// @notice Mock "external" liquidity source for ExternalLiqSourceHook unit tests.
/// @dev Returns settable (amountSettle, amountTake, hasSettled) for pullTokens.
contract MockExternalLiqSource {
    uint256 public returnAmountSettle;
    uint256 public returnAmountTake;
    bool public returnHasSettled;
    bool public revertNextCall;

    error RevertNextCall();

    function setReturns(uint256 amountSettle, uint256 amountTake, bool hasSettled) external {
        returnAmountSettle = amountSettle;
        returnAmountTake = amountTake;
        returnHasSettled = hasSettled;
    }

    function setRevertNextCall(bool doRevert) external {
        revertNextCall = doRevert;
    }

    /// @notice Simulates pulling tokens from external source; returns configurable tuple.
    function pullTokens(Currency, Currency, uint256)
        external
        view
        returns (uint256 amountSettle, uint256 amountTake, bool hasSettled)
    {
        if (revertNextCall) revert RevertNextCall();
        return (returnAmountSettle, returnAmountTake, returnHasSettled);
    }
}
