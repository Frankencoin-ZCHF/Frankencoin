// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    IFluidDexLite
} from "../../../../src/aggregator-hooks/implementations/FluidDexLite/interfaces/IFluidDexLite.sol";
import {
    IFluidDexLiteCallback
} from "../../../../src/aggregator-hooks/implementations/FluidDexLite/interfaces/IFluidDexLiteCallback.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ReentrancyAttacker
/// @notice Contract that attempts to re-enter during callback
contract ReentrancyAttacker {
    address public target;
    bytes public callData;

    function setAttack(address _target, bytes calldata _callData) external {
        target = _target;
        callData = _callData;
    }

    function attack() external {
        (bool success,) = target.call(callData);
        // We expect this to fail with Reentrancy error
        require(!success, "Reentrancy attack should fail");
    }
}

/// @title UnauthorizedCallbackCaller
/// @notice Contract that tries to call dexCallback when it's not the authorized pool
contract UnauthorizedCallbackCaller {
    function callDexCallback(address hook, address token, uint256 amount) external {
        IFluidDexLiteCallback(hook).dexCallback(token, amount, "");
    }
}

/// @title MockFluidDexLite
/// @notice Mock Fluid DEX Lite pool with settable swapSingle return for unit tests.
contract MockFluidDexLite is IFluidDexLite {
    uint256 public returnSwapSingle;
    bool public revertSwapSingle;
    bool public useNativeCurrencyInCallback;
    address private constant FLUID_NATIVE_CURRENCY = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // For reentrancy testing - call this contract during callback
    address public reentrancyAttacker;
    // For unauthorized caller testing - have this contract call dexCallback instead
    address public unauthorizedCaller;

    error SwapSingleRevert();

    function setReturnSwapSingle(uint256 amount) external {
        returnSwapSingle = amount;
    }

    function setRevertSwapSingle(bool doRevert) external {
        revertSwapSingle = doRevert;
    }

    function setUseNativeCurrencyInCallback(bool useNative) external {
        useNativeCurrencyInCallback = useNative;
    }

    function setReentrancyAttacker(address attacker) external {
        reentrancyAttacker = attacker;
    }

    function setUnauthorizedCaller(address caller) external {
        unauthorizedCaller = caller;
    }

    receive() external payable {}

    /// @inheritdoc IFluidDexLite
    function swapSingle(
        DexKey calldata dexKey_,
        bool swap0to1_,
        int256 amountSpecified_,
        uint256,
        address to_,
        bool isCallback_,
        bytes calldata,
        bytes calldata data_
    ) external payable override returns (uint256 amountUnspecified_) {
        if (revertSwapSingle) revert SwapSingleRevert();

        address tokenIn = swap0to1_ ? dexKey_.token0 : dexKey_.token1;
        address tokenOut = swap0to1_ ? dexKey_.token1 : dexKey_.token0;

        // For exact-in (positive amountSpecified_), amountIn = amountSpecified_
        // For exact-out (negative amountSpecified_), amountIn = returnSwapSingle
        uint256 amountIn = amountSpecified_ > 0 ? uint256(amountSpecified_) : returnSwapSingle;

        if (isCallback_) {
            // Call back the hook to pull tokens
            // Use FLUID_NATIVE_CURRENCY if flag is set (for testing native currency conversion)
            address callbackToken = useNativeCurrencyInCallback ? FLUID_NATIVE_CURRENCY : tokenIn;

            // If unauthorized caller is set, have them make the callback instead
            if (unauthorizedCaller != address(0)) {
                UnauthorizedCallbackCaller(unauthorizedCaller).callDexCallback(msg.sender, callbackToken, amountIn);
            } else {
                IFluidDexLiteCallback(msg.sender).dexCallback(callbackToken, amountIn, data_);
            }

            // If reentrancy attacker is set, try to re-enter after callback
            if (reentrancyAttacker != address(0)) {
                ReentrancyAttacker(reentrancyAttacker).attack();
            }
        }

        if (tokenOut == FLUID_NATIVE_CURRENCY || tokenOut == address(0)) {
            (bool success,) = to_.call{value: returnSwapSingle}("");
            require(success, "ETH transfer failed");
        } else {
            IERC20(tokenOut).transfer(to_, returnSwapSingle);
        }

        return returnSwapSingle;
    }
}
