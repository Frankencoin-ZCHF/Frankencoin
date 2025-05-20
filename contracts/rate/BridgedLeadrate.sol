// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import "../erc20/IERC20.sol";
import "../stablecoin/IFrankencoin.sol";
import "../minting/IPosition.sol";
import "./AbstractLeadrate.sol";

/**
 * @title Leadrate (attempt at translating the nicely concise German term 'Leitzins')
 *
 * A module that can provide other modules with the lead interest rate for the system.
 *
 **/
contract BridgedLeadrate is AbstractLeadrate, CCIPReceiver {
    uint64 public immutable MAINNET_CHAIN_SELECTOR;
    address public immutable MAINNET_LEADRATE_ADDRESS;

    error InvalidSourceChain();
    error InvalidSender();

    constructor(address router, uint24 initialRatePPM, uint64 mainnetChainSelector, address mainnetLeadrate) AbstractLeadrate(initialRatePPM) CCIPReceiver(router) {
        MAINNET_CHAIN_SELECTOR = mainnetChainSelector;
        MAINNET_LEADRATE_ADDRESS = mainnetLeadrate;
    }

    /// @notice Update the lead rate.
    /// @param any2EvmMessage The message to process.
    function _ccipReceive(Client.Any2EVMMessage memory any2EvmMessage) internal override {
        if (any2EvmMessage.sourceChainSelector != MAINNET_CHAIN_SELECTOR) revert InvalidSourceChain();
        if (abi.decode(any2EvmMessage.sender, (address)) != MAINNET_LEADRATE_ADDRESS) revert InvalidSender();

        uint24 newRate = abi.decode(any2EvmMessage.data, (uint24));
        updateRate(newRate);
    }
}
