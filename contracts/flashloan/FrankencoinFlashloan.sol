// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IFrankencoin} from "../stablecoin/IFrankencoin.sol";
import {IFrankencoinFlashloanCallback} from "./IFrankencoinFlashloanCallback.sol";

/**
 * @title FrankencoinFlashloan
 * @notice Native-minter ZCHF flash-loan provider.
 *
 * Must be registered as a minter via IBasicFrankencoin.suggestMinter before use.
 *
 * Flow per loan:
 *  1. zchf.mint(recipient, amount) — create ZCHF for the duration of the transaction.
 *  2. Invoke recipient.onFrankencoinFlashloan(amount, data).
 *  3. zchf.burnFrom(recipient, amount) — destroy the same amount, restoring supply.
 */
contract FrankencoinFlashloan is ReentrancyGuard {
    IFrankencoin public immutable zchf;

    error InvalidAmount();

    event Flashloan(address indexed recipient, uint256 amount);

    constructor(address _zchf) {
        zchf = IFrankencoin(_zchf);
    }

    function flashloan(uint256 amount, bytes calldata data) external nonReentrant {
        if (amount == 0 || amount > zchf.minterReserve()) revert InvalidAmount();

        address recipient = msg.sender;

        zchf.mint(recipient, amount);
        IFrankencoinFlashloanCallback(recipient).onFrankencoinFlashloan(amount, data);
        zchf.burnFrom(recipient, amount);

        emit Flashloan(recipient, amount);
    }
}
