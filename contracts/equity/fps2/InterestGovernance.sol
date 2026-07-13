// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./GovernanceModule.sol";

/**
 * Allows qualified FPS2 holders to sync FPS1-based interest rates to other chains.
 */
contract InterestGovernance is GovernanceModule {

    ILeadrateProposal public immutable BORROWING_LEADRATE;
    ILeadrateProposal public immutable SAVINGS_LEADRATE;

    constructor(IGovernance fps1Gov, IGovernance fps2Gov, address fps2mainnet,
        ILeadrateProposal borrowingLeadrate_,
        ILeadrateProposal savingsLeadrate_,
        address delegate
    ) GovernanceModule(fps2Gov, fps2mainnet) {
        BORROWING_LEADRATE = borrowingLeadrate_;
        SAVINGS_LEADRATE = savingsLeadrate_;
        fps1Gov.delegateVoteTo(delegate);
    }

    // ==================== Leadrate proposals (mainnet only) ====================

    /**
     * @notice Propose a borrowing rate change on behalf of qualified FPS2 holders.
     * @param newRatePPM    The proposed new rate in parts per million
     * @param helpers       FPS2 holders who delegate their votes to the caller
     */
    function proposeBorrowingRate(uint24 newRatePPM, address[] calldata helpers) external onlyQualified(helpers) {
        BORROWING_LEADRATE.proposeChange(newRatePPM, defaultHelper());
    }

    /**
     * @notice Propose a savings rate change on behalf of qualified FPS2 holders.
     * @param newRatePPM    The proposed new rate in parts per million
     * @param helpers       FPS2 holders who delegate their votes to the caller
     */
    function proposeSavingsRate(uint24 newRatePPM, address[] calldata helpers) external onlyQualified(helpers) {
        SAVINGS_LEADRATE.proposeChange(newRatePPM, defaultHelper());
    }

}

interface ILeadrateProposal {
    function proposeChange(uint24 newRatePPM_, address[] calldata helpers) external;
}
