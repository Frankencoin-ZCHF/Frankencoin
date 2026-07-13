// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../equity/fps2/MainnetVotes.sol";
import "../equity/fps2/CCIPGovernance.sol";
import "../equity/fps2/MinterGovernance.sol";
import "../equity/fps2/InterestGovernance.sol";
import "../equity/IGovernance.sol";
import "../stablecoin/IFrankencoin.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {ICCIPAdmin} from "../bridge/ICCIPAdmin.sol";

/**
 * @title TestGovernanceFactory
 *
 * Test-only replacement for GovernanceFactory / InnerFactory. It wires the FPS2 governance cluster
 * (MainnetVotes + CCIPGovernance + MinterGovernance + InterestGovernance) to a locally deployed
 * Frankencoin / Equity instead of the hardcoded mainnet addresses, so FPS2 can be exercised on a
 * fresh, small FPS1 (needed to reach the "binding" state). The CCIP router, CCIP admin and leadrate
 * targets are left as the zero address; they are only stored, never called, during the FPS2 unit tests.
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

    function deploy(address fps2mainnet) external returns (address helper) {
        governance = new MainnetVotes(fps2mainnet, IRouterClient(address(0)));
        ccipGov = new CCIPGovernance(governance, fps2mainnet, ICCIPAdmin(address(0)));
        minterGov = new MinterGovernance(ZCHF, FPS1_VOTES, governance, address(ccipGov), fps2mainnet);
        interestGov = new InterestGovernance(
            FPS1_VOTES,
            governance,
            fps2mainnet,
            ILeadrateProposal(address(0)),
            ILeadrateProposal(address(0)),
            address(minterGov)
        );
        return address(interestGov);
    }
}
