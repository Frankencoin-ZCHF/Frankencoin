// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./FPS2.sol";
import "./MinterGovernance.sol";
import "../IGovernance.sol";
import "../../stablecoin/IFrankencoin.sol";
import "../../minting/IPosition.sol";
import {ITokenPool} from "../../bridge/ITokenPool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/RateLimiter.sol";

/**
 * @notice Governance contract for the FPS2 equity. It is used to check if an address has veto power.
 * Veto power is reached with 2% of the votes.
 */
contract FPS2Governance is MinterGovernance {

    // --- References to other contracts ---
    ICCIPAdmin public immutable CCIP_ADMIN;
    ILeadrateProposal public immutable BORROWING_LEADRATE;
    ILeadrateProposal public immutable SAVINGS_LEADRATE;

    constructor(FPS2 fps2_, IFrankencoin zchf_, ICCIPAdmin ccipAdmin_, ILeadrateProposal borrowingLeadrate_, ILeadrateProposal savingsLeadrate_) MinterGovernance(zchf_, fps2_) {
        CCIP_ADMIN = ccipAdmin_;
        BORROWING_LEADRATE = borrowingLeadrate_;
        SAVINGS_LEADRATE = savingsLeadrate_;
    }

    // ==================== Access to existing governance functions ====================

    /**
     * @notice Deny a v1 or v2 minting position on behalf of qualified FPS2 holders.
     * Wraps Position.deny, which checks qualification against the old Equity contract.
     * Since FPS2 holds FPS, it passes the old equity's qualification check.
     * @param position  The position contract to deny
     * @param helpers   FPS2 holders who delegate their votes to the caller
     * @param message   Reason for the denial
     */
    function denyPosition(address position, address[] calldata helpers, string calldata message) external {
        FPS2.checkQualified(msg.sender, helpers);
        IPosition(position).deny(helpers(), message);
    }

    /**
     * @notice Propose a borrowing rate change on behalf of qualified FPS2 holders.
     * @param newRatePPM    The proposed new rate in parts per million
     * @param helpers       FPS2 holders who delegate their votes to the caller
     */
    function proposeBorrowingRate(uint24 newRatePPM, address[] calldata helpers) external {
        FPS2.checkQualified(msg.sender, helpers);
        BORROWING_LEADRATE.proposeChange(newRatePPM, helpers());
    }

    /**
     * @notice Propose a savings rate change on behalf of qualified FPS2 holders.
     * @param newRatePPM    The proposed new rate in parts per million
     * @param helpers       FPS2 holders who delegate their votes to the caller
     */
    function proposeSavingsRate(uint24 newRatePPM, address[] calldata helpers) external {
        FPS2.checkQualified(msg.sender, helpers);
        SAVINGS_LEADRATE.proposeChange(newRatePPM, helpers());
    }

    // ==================== CCIPAdmin governance functions ====================

    /**
     * @notice Propose a remote pool update on the CCIPAdmin contract.
     * @param update  The remote pool update to propose
     * @param helpers FPS2 holders who delegate their votes to the caller
     */
    function ccipProposeRemotePoolUpdate(ICCIPAdmin.RemotePoolUpdate memory update, address[] calldata helpers) external {
        FPS2.checkQualified(msg.sender, helpers);
        CCIP_ADMIN.proposeRemotePoolUpdate(update, helpers());
    }

    /**
     * @notice Propose to remove a remote chain on the CCIPAdmin contract.
     * @param chainId  The chain to remove
     * @param helpers  FPS2 holders who delegate their votes to the caller
     */
    function ccipProposeRemoveChain(uint64 chainId, address[] calldata helpers) external {
        FPS2.checkQualified(msg.sender, helpers);
        CCIP_ADMIN.proposeRemoveChain(chainId, helpers());
    }

    /**
     * @notice Propose to add a remote chain on the CCIPAdmin contract.
     * @param config   The chain configuration to add
     * @param helpers  FPS2 holders who delegate their votes to the caller
     */
    function ccipProposeAddChain(ITokenPool.ChainUpdate calldata config, address[] calldata helpers) external {
        FPS2.checkQualified(msg.sender, helpers);
        CCIP_ADMIN.proposeAddChain(config, helpers());
    }

    /**
     * @notice Propose an admin transfer on the CCIPAdmin contract.
     * @param newAdmin  The proposed new admin address
     * @param helpers   FPS2 holders who delegate their votes to the caller
     */
    function ccipProposeAdminTransfer(address newAdmin, address[] calldata helpers) external {
        FPS2.checkQualified(msg.sender, helpers);
        CCIP_ADMIN.proposeAdminTransfer(newAdmin, helpers());
    }

    /**
     * @notice Apply rate limits on the CCIPAdmin contract. Used in emergencies (e.g. chain hacked).
     * @param chain     The chain to set rate limits for
     * @param inbound   Inbound rate limit config
     * @param outbound  Outbound rate limit config
     * @param helpers   FPS2 holders who delegate their votes to the caller
     */
    function ccipApplyRateLimit(uint64 chain, RateLimiter.Config calldata inbound, RateLimiter.Config calldata outbound, address[] calldata helpers) external {
        FPS2.checkQualified(msg.sender, helpers);
        CCIP_ADMIN.applyRateLimit(chain, inbound, outbound, helpers());
    }

    /**
     * @notice Deny a pending proposal on the CCIPAdmin contract.
     * @param hash     The proposal hash to deny
     * @param helpers  FPS2 holders who delegate their votes to the caller
     */
    function ccipDenyProposal(bytes32 hash, address[] calldata helpers) external {
        FPS2.checkQualified(msg.sender, helpers);
        CCIP_ADMIN.deny(hash, helpers());
    }

}

/**
 * @notice Minimal interface for calling proposeChange on a Leadrate contract.
 */
interface ILeadrateProposal {
    function proposeChange(uint24 newRatePPM_, address[] calldata helpers) external;
}

/**
 * @notice Minimal interface for calling governance functions on a CCIPAdmin contract.
 */
interface ICCIPAdmin {
    struct RemotePoolUpdate {
        bool add;
        uint64 chain;
        bytes poolAddress;
    }
    function proposeRemotePoolUpdate(RemotePoolUpdate memory update, address[] calldata helpers) external;
    function proposeRemoveChain(uint64 chainId, address[] calldata helpers) external;
    function proposeAddChain(ITokenPool.ChainUpdate calldata config, address[] calldata helpers) external;
    function proposeAdminTransfer(address newAdmin, address[] calldata helpers) external;
    function applyRateLimit(uint64 chain, RateLimiter.Config calldata inbound, RateLimiter.Config calldata outbound, address[] calldata helpers) external;
    function deny(bytes32 hash, address[] calldata helpers) external;
}
