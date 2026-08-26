// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../equity/shares/MainnetVotes.sol";
import "../equity/shares/CCIPGovernance.sol";
import "../equity/shares/MinterGovernance.sol";
import "../equity/shares/InterestGovernance.sol";
import "../equity/IGovernance.sol";
import "../stablecoin/IFrankencoin.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {ICCIPAdmin} from "../bridge/ICCIPAdmin.sol";

/**
 * @title TestGovernanceFactory
 *
 * Test-only replacement for GovernanceFactory / InnerFactory. It wires the FCS governance cluster
 * (MainnetVotes + CCIPGovernance + MinterGovernance + InterestGovernance) to a locally deployed
 * Frankencoin / Equity instead of the hardcoded mainnet addresses, so FCS can be exercised on a
 * fresh, small FPS1 (needed to reach the "binding" state). The CCIP router, CCIP admin and leadrate
 * targets are left as the zero address; they are only stored, never called, during the FCS unit tests.
 *
 * The deployed cluster contracts are exposed publicly so tests can reach the specific module
 * (e.g. minterGov for suggestMinter/denyMinter).
 */
contract TestGovernanceFactory {

    IFrankencoin public immutable ZCHF;
    IGovernance public immutable FPS1_VOTES;

    MainnetVotes public governance;
    CCIPGovernance public ccipGov;
    MinterGovernance public minterGov;
    InterestGovernance public interestGov;

    constructor(IFrankencoin zchf_, IGovernance fps1Votes_) {
        ZCHF = zchf_;
        FPS1_VOTES = fps1Votes_;
    }

    function deploy(address fcsmainnet) external returns (address helper) {
        governance = new MainnetVotes(fcsmainnet, IRouterClient(address(0)));
        ccipGov = new CCIPGovernance(governance, fcsmainnet, ICCIPAdmin(address(0)));
        minterGov = new MinterGovernance(ZCHF, FPS1_VOTES, governance, address(ccipGov), fcsmainnet);
        interestGov = new InterestGovernance(
            FPS1_VOTES,
            governance,
            fcsmainnet,
            ILeadrateProposal(address(0)),
            ILeadrateProposal(address(0)),
            address(minterGov)
        );
        return address(interestGov);
    }
}
