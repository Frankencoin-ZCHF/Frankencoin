// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @title SafeCurrencySettler
/// @notice Library used to interact with PoolManager.sol to settle any open deltas.
/// @dev This version uses SafeERC20 to handle non-standard ERC20 tokens like USDT.
library SafeCurrencySettler {
    using SafeERC20 for IERC20;

    /// @notice Settle (pay) a currency to the PoolManager
    /// @param currency Currency to settle
    /// @param manager IPoolManager to settle to
    /// @param payer Address of the payer, the token sender
    /// @param amount Amount to send
    /// @param burn If true, burn the ERC-6909 token, otherwise ERC20-transfer to the PoolManager
    function settle(Currency currency, IPoolManager manager, address payer, uint256 amount, bool burn) internal {
        // for native currencies or burns, calling sync is not required
        // short circuit for ERC-6909 burns to support ERC-6909-wrapped native tokens
        if (burn) {
            manager.burn(payer, currency.toId(), amount);
        } else if (currency.isAddressZero()) {
            manager.settle{value: amount}();
        } else {
            manager.sync(currency);
            if (payer != address(this)) {
                // Use SafeERC20 for non-standard tokens like USDT
                IERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(manager), amount);
            } else {
                IERC20(Currency.unwrap(currency)).safeTransfer(address(manager), amount);
            }
            manager.settle();
        }
    }

    /// @notice Take (receive) a currency from the PoolManager
    /// @param currency Currency to take
    /// @param manager IPoolManager to take from
    /// @param recipient Address of the recipient, the token receiver
    /// @param amount Amount to receive
    /// @param claims If true, mint the ERC-6909 token, otherwise ERC20-transfer from the PoolManager to recipient
    function take(Currency currency, IPoolManager manager, address recipient, uint256 amount, bool claims) internal {
        claims ? manager.mint(recipient, currency.toId(), amount) : manager.take(currency, recipient, amount);
    }
}
