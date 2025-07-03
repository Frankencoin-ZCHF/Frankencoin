// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../stablecoin/IFrankencoin.sol";
import "../rate/Leadrate.sol";
import "./AbstractSavings.sol";

/**
 * @title Savings
 *
 * Module to enable savings based on a Leadrate ("Leitzins") module on mainnet.
 */
contract Savings is Leadrate, AbstractSavings {

    constructor(IFrankencoin zchf_, uint24 initialRatePPM) AbstractSavings(zchf_) Leadrate(zchf_.reserve(), initialRatePPM) {
    }

}
