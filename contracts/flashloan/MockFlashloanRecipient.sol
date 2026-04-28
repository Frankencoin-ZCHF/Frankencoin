// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IFrankencoinFlashloanCallback} from './IFrankencoinFlashloanCallback.sol';
import {IFrankencoinFlashloan} from './IFrankencoinFlashloan.sol';

contract MockFlashloanRecipient is IFrankencoinFlashloanCallback {
	IFrankencoinFlashloan public immutable flashloan;

	event FlashloanReceived(address indexed caller, uint256 amount, bytes data);

	constructor(address _flashloan) {
		flashloan = IFrankencoinFlashloan(_flashloan);
	}

	function trigger(uint256 amount, bytes calldata data) external {
		flashloan.flashloan(amount, data);
	}

	function onFrankencoinFlashloan(uint256 amount, bytes calldata data) external override {
		require(msg.sender == address(flashloan), 'unauthorized');
		emit FlashloanReceived(msg.sender, amount, data);
		// FrankencoinFlashloan burns via minter privilege — no approval needed.
	}
}
