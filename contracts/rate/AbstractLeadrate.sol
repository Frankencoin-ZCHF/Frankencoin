// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../erc20/IERC20.sol";
import "../stablecoin/IFrankencoin.sol";
import "../minting/IPosition.sol";

/**
 * @title Leadrate (attempt at translating the nicely concise German term 'Leitzins')
 *
 * A module that can provide other modules with the lead interest rate for the system.
 * 
 * This is an abstract module that is agnostic about the way the lead rate is updated.
 *
 **/
abstract contract AbstractLeadrate {

    // the following five variables are less than 256 bit so they should be stored
    // in the same slot, making them cheap to access together, right?

    uint24 public currentRatePPM; // 24 bit allows rates of up to 1670% per year

    uint40 private anchorTime; // 40 bits for time in seconds spans up to 1000 human generations
    uint64 private ticksAnchor; // in bips * seconds, uint88 allows up to

    event RateChanged(uint24 newRate);

    constructor(uint24 initialRatePPM) {
        currentRatePPM = initialRatePPM;
        anchorTime = uint40(block.timestamp);
        ticksAnchor = 0;
        emit RateChanged(initialRatePPM); // emit for init indexing, if wanted
    }

    /**
     * Setting a previously proposed interest rate change into force.
     */
    function updateRate(uint24 rate) internal {
        uint40 timeNow = uint40(block.timestamp);
        ticksAnchor += (timeNow - anchorTime) * currentRatePPM;
        anchorTime = timeNow;
        currentRatePPM = rate;
        emit RateChanged(rate);
    }

    /**
     * Total accumulated 'interest ticks' since this contract was deployed.
     * One 'tick' is a ppm-second, so one months of 12% annual interest is
     *   120000*30*24*3600 = 311040000000 ticks.
     * Two months of 6% annual interest would result in the same number of
     * ticks. For simplicity, this is linear, so there is no "interest on interest".
     */
    function currentTicks() public view returns (uint64) {
        return ticks(block.timestamp);
    }

    function ticks(uint256 timestamp) public view returns (uint64) {
        return ticksAnchor + (uint64(timestamp) - anchorTime) * currentRatePPM;
    }

}
