// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../erc20/IERC20.sol";
import "../stablecoin/IFrankencoin.sol";
import "../minting/IPosition.sol";
import "../equity/IGovernance.sol";
import "./AbstractLeadrate.sol";

/**
 * @title Leadrate (attempt at translating the nicely concise German term 'Leitzins')
 *
 * A module that can provide other modules with the lead interest rate for the system.
 *
 **/
contract Leadrate is AbstractLeadrate {

    IGovernance public immutable equity;

    // the following five variables are less than 256 bit so they should be stored
    // in the same slot, making them cheap to access together, right?

    uint24 public nextRatePPM;
    uint40 public nextChange;

    event RateProposed(address who, uint24 nextRate, uint40 nextChange);
    error NoPendingChange();
    error ChangeNotReady();

    constructor(IGovernance equity_, uint24 initialRatePPM) AbstractLeadrate(initialRatePPM) {
        equity = equity_;
        nextRatePPM = initialRatePPM;
        nextChange = uint40(block.timestamp);
    }

    /**
     * Proposes a new interest rate that will automatically be applied after seven days.
     * To cancel a proposal, just overwrite it with a new one proposing the current rate.
     */
    function proposeChange(uint24 newRatePPM_, address[] calldata helpers) external {
        equity.checkQualified(msg.sender, helpers);
        nextRatePPM = newRatePPM_;
        nextChange = uint40(block.timestamp + 7 days);
        emit RateProposed(msg.sender, nextRatePPM, nextChange);
    }

    /**
     * Setting a previously proposed interest rate change into force.
     */
    function applyChange() external {
        if (currentRatePPM == nextRatePPM) revert NoPendingChange();
        uint40 timeNow = uint40(block.timestamp);
        if (timeNow < nextChange) revert ChangeNotReady();
        super.updateRate(nextRatePPM);
    }

}
