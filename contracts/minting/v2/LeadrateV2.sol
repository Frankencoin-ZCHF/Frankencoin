// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../../erc20/IERC20.sol";
import "../v1/IFrankencoin.sol";
import "../v1/IReserve.sol";

/**
 * @title Leadrate (attempt at translating the nicely concise German term 'Leitzins')
 *
 * A module that can provide other modules with the lead interest rate for the system.
 *
 **/
contract LeadrateV2 {
    IReserve public immutable equity;

    // the following five variables are less than 256 bit so they should be stored
    // in the same slot, making them cheap to access together, right?

    uint24 public currentRatePPM; // 24 bit allows rates of up to 1670% per year
    uint24 public nextRatePPM;
    uint40 public nextChange;

    uint40 private anchorTime; // 40 bits for time in seconds spans up to 1000 human generations
    uint64 private ticksAnchor; // in bips * seconds, uint88 allows up to

    event RateProposed(address who, uint24 nextRate, uint40 nextChange);
    event RateChanged(uint24 newRate);

    error NoPendingChange();
    error ChangeNotReady();

    constructor(IReserve equity_, uint24 initialRatePPM) {
        equity = equity_;
        nextRatePPM = initialRatePPM;
        currentRatePPM = initialRatePPM;
        nextChange = uint40(block.timestamp);
        anchorTime = nextChange;
        ticksAnchor = 0;
        emit RateChanged(initialRatePPM); // emit for init indexing, if wanted
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
        ticksAnchor += (timeNow - anchorTime) * currentRatePPM;
        anchorTime = timeNow;
        currentRatePPM = nextRatePPM;
        emit RateChanged(currentRatePPM);
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
