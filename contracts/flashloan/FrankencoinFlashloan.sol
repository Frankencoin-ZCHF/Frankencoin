// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IModuleRegistry, IBasicFrankencoin} from "../registry/IModuleRegistry.sol";
import {IFrankencoinFlashloanCallback} from "./IFrankencoinFlashloanCallback.sol";

/**
 * @title FrankencoinFlashloan
 * @notice Native-minter ZCHF flash-loan provider backed by the ModuleRegistry.
 *
 * Must be registered as an active module in the ModuleRegistry before use.
 * Mint and burn are proxied through the registry (moduleMint / moduleBurn),
 * so this contract requires no direct ZCHF minter status.
 *
 * Flow per loan:
 *  1. registry.moduleMint(recipient, amount) — create ZCHF for the duration of the tx.
 *  2. Invoke recipient.onFrankencoinFlashloan(amount, data).
 *  3. registry.moduleBurn(recipient, amount) — destroy the same amount, restoring supply.
 */
contract FrankencoinFlashloan is ReentrancyGuard {
    IModuleRegistry public immutable registry;
    IBasicFrankencoin public immutable zchf;

    error InvalidAmount();

    event Flashloan(address indexed recipient, uint256 amount);

    constructor(IModuleRegistry registry_) {
        registry = registry_;
        zchf = registry_.zchf();
    }

    function flashloan(uint256 amount, bytes calldata data) external nonReentrant {
        if (amount == 0) revert InvalidAmount();

        address recipient = msg.sender;

        registry.moduleMint(recipient, amount);
        IFrankencoinFlashloanCallback(recipient).onFrankencoinFlashloan(amount, data);
        registry.moduleBurn(recipient, amount);

        emit Flashloan(recipient, amount);
    }
}
