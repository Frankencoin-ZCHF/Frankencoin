// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";

contract CCIPWrapper is CCIPReceiver {
    using SafeERC20 for IERC20;

    ERC4626 public immutable svZCHF;
    IERC20 public immutable zCHF;

    event Wrapped(address indexed recipient, uint256 amount, uint256 shares);

    error InvalidRecipient();
    error InvalidToken();
    error InvalidTokenCount();

    constructor(ERC4626 svzchf, IERC20 zchf, address router) CCIPReceiver(router) {
        svZCHF = svzchf;
        zCHF = zchf;
        zCHF.forceApprove(address(svZCHF), type(uint256).max);
    }

    /// @notice Handles the profit and loss messages
    /// @param any2EvmMessage The message
    function _ccipReceive(Client.Any2EVMMessage memory any2EvmMessage) internal override {
        if (any2EvmMessage.destTokenAmounts.length != 1) {
            revert InvalidTokenCount();
        }

        address token = any2EvmMessage.destTokenAmounts[0].token;
        uint256 amount = any2EvmMessage.destTokenAmounts[0].amount;
        if (token != address(zCHF)) revert InvalidToken();

        address recipient = abi.decode(any2EvmMessage.data, (address));
        if (recipient == address(0)) revert InvalidRecipient();

        uint256 shares = svZCHF.deposit(amount, recipient);

        emit Wrapped(recipient, amount, shares);
    }
}
