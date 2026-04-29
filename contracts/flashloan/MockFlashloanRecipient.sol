// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IFrankencoinFlashloanCallback} from "./IFrankencoinFlashloanCallback.sol";
import {IFrankencoinFlashloan} from "./IFrankencoinFlashloan.sol";

contract MockFlashloanRecipient is IFrankencoinFlashloanCallback {
    IFrankencoinFlashloan public immutable flashloan;

    error NotFlashloan(address caller);

    event FlashloanReceived(address indexed caller, uint256 amount, bytes data);

    constructor(address _flashloan) {
        flashloan = IFrankencoinFlashloan(_flashloan);
    }

    function trigger(uint256 amount, bytes calldata data) external {
        flashloan.flashloan(amount, data);
    }

    function onFrankencoinFlashloan(uint256 amount, bytes calldata data) external override {
        if (msg.sender != address(flashloan)) revert NotFlashloan(msg.sender);
        emit FlashloanReceived(msg.sender, amount, data);
        // FrankencoinFlashloan burns via registry minter privilege — no approval needed.
    }
}
