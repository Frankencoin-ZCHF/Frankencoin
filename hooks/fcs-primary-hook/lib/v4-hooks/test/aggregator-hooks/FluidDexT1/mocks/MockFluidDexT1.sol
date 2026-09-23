// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IFluidDexT1} from "../../../../src/aggregator-hooks/implementations/FluidDexT1/interfaces/IFluidDexT1.sol";
import {IDexCallback} from "../../../../src/aggregator-hooks/implementations/FluidDexT1/interfaces/IDexCallback.sol";
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
        IDexCallback(hook).dexCallback(token, amount);
    }
}

/// @title MockFluidDexT1
/// @notice Mock Fluid DEX T1 pool with settable swap return values for unit tests.
contract MockFluidDexT1 is IFluidDexT1 {
    uint256 public returnSwapIn;
    uint256 public returnSwapOut;
    uint256 public returnSwapInWithCallback;
    uint256 public returnSwapOutWithCallback;
    bool public revertSwapIn;
    bool public revertSwapOut;
    bool public revertSwapInWithCallback;
    bool public revertSwapOutWithCallback;

    // Tokens for callback simulation
    address public token0;
    address public token1;

    // For native currency testing - when true, use FLUID_NATIVE_CURRENCY in callback
    bool public useNativeCurrencyInCallback;
    address private constant FLUID_NATIVE_CURRENCY = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // For reentrancy testing - call this contract during callback
    address public reentrancyAttacker;
    // For unauthorized caller testing - have this contract call dexCallback instead
    address public unauthorizedCaller;

    error SwapInRevert();
    error SwapOutRevert();
    error SwapInWithCallbackRevert();
    error SwapOutWithCallbackRevert();

    function setReturnSwapIn(uint256 amount) external {
        returnSwapIn = amount;
    }

    function setReturnSwapOut(uint256 amount) external {
        returnSwapOut = amount;
    }

    function setReturnSwapInWithCallback(uint256 amount) external {
        returnSwapInWithCallback = amount;
    }

    function setReturnSwapOutWithCallback(uint256 amount) external {
        returnSwapOutWithCallback = amount;
    }

    function setRevertSwapIn(bool doRevert) external {
        revertSwapIn = doRevert;
    }

    function setRevertSwapOut(bool doRevert) external {
        revertSwapOut = doRevert;
    }

    function setRevertSwapInWithCallback(bool doRevert) external {
        revertSwapInWithCallback = doRevert;
    }

    function setRevertSwapOutWithCallback(bool doRevert) external {
        revertSwapOutWithCallback = doRevert;
    }

    function setTokens(address _token0, address _token1) external {
        token0 = _token0;
        token1 = _token1;
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

    function swapIn(bool swap0to1_, uint256, uint256, address to_)
        external
        payable
        override
        returns (uint256 amountOut_)
    {
        if (revertSwapIn) revert SwapInRevert();
        // Transfer output tokens to recipient
        address tokenOut = swap0to1_ ? token1 : token0;
        if (tokenOut != address(0)) {
            IERC20(tokenOut).transfer(to_, returnSwapIn);
        } else {
            // Native currency output
            (bool success,) = to_.call{value: returnSwapIn}("");
            require(success, "ETH transfer failed");
        }
        return returnSwapIn;
    }

    receive() external payable {}

    function swapOut(bool, uint256, uint256, address to_) external payable override returns (uint256 amountIn_) {
        if (revertSwapOut) revert SwapOutRevert();
        (to_);
        return returnSwapOut;
    }

    function swapInWithCallback(bool swap0to1_, uint256 amountIn_, uint256, address to_)
        external
        payable
        override
        returns (uint256 amountOut_)
    {
        if (revertSwapInWithCallback) revert SwapInWithCallbackRevert();
        // Determine tokenIn based on swap direction
        address tokenIn = swap0to1_ ? token0 : token1;
        address tokenOut = swap0to1_ ? token1 : token0;
        // Call back the hook to pull tokens (simulating Fluid's callback)
        // If useNativeCurrencyInCallback is set, use FLUID_NATIVE_CURRENCY address
        address callbackToken = useNativeCurrencyInCallback ? FLUID_NATIVE_CURRENCY : tokenIn;

        // If unauthorized caller is set, have them make the callback instead
        if (unauthorizedCaller != address(0)) {
            UnauthorizedCallbackCaller(unauthorizedCaller).callDexCallback(msg.sender, callbackToken, amountIn_);
        } else {
            IDexCallback(msg.sender).dexCallback(callbackToken, amountIn_);
        }

        // If reentrancy attacker is set, try to re-enter after callback
        if (reentrancyAttacker != address(0)) {
            ReentrancyAttacker(reentrancyAttacker).attack();
        }

        // Transfer output tokens to recipient
        if (tokenOut == address(0)) {
            // Native currency output
            (bool success,) = to_.call{value: returnSwapInWithCallback}("");
            require(success, "ETH transfer failed");
        } else {
            IERC20(tokenOut).transfer(to_, returnSwapInWithCallback);
        }
        return returnSwapInWithCallback;
    }

    function swapOutWithCallback(bool swap0to1_, uint256 amountOut_, uint256, address to_)
        external
        payable
        override
        returns (uint256 amountIn_)
    {
        if (revertSwapOutWithCallback) revert SwapOutWithCallbackRevert();
        // Determine tokenIn based on swap direction
        address tokenIn = swap0to1_ ? token0 : token1;
        address tokenOut = swap0to1_ ? token1 : token0;
        // Call back the hook to pull tokens (simulating Fluid's callback)
        IDexCallback(msg.sender).dexCallback(tokenIn, returnSwapOutWithCallback);
        // Transfer output tokens to recipient
        IERC20(tokenOut).transfer(to_, amountOut_);
        return returnSwapOutWithCallback;
    }
}
