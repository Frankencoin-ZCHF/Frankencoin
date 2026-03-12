// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../Governance.sol";
import "../../stablecoin/IFrankencoin.sol";
import "../../minting/IPosition.sol";
import {ITokenPool} from "../../bridge/ITokenPool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/RateLimiter.sol";

/**
 * @notice Governance contract for the FPS2 equity. It is used to check if an address has veto power.
 * Veto power is reached with 2% of the votes.
 */
abstract contract FPS2Governance is IGovernance {

    // --- Announcement tracking for minters ---
    mapping(address minter => uint256 timestamp) public announcements;

    // --- Constants ---
    uint256 public constant MIN_APPLICATION_PERIOD = 90 days;

    // --- References to other contracts ---
    IFrankencoin public immutable zchf;
    ICCIPAdmin public immutable ccipAdmin;
    ILeadrateProposal public constant BORROWING_LEADRATE = ILeadrateProposal(0x3BF301B0e2003E75A3e86AB82bD1EFF6A9dFB2aE);
    ILeadrateProposal public constant SAVINGS_LEADRATE = ILeadrateProposal(0x27d9AD987BdE08a0d083ef7e0e4043C857A17B38);

    event MinterAnnounced(address indexed who, address indexed minter, uint256 timestamp);
    event MinterVetoed(address indexed minter, string message);

    error MinterCorrectlyAnnounced();
    error PeriodTooShort();

    constructor(IFrankencoin zchf_, ICCIPAdmin ccipAdmin_) {
        zchf = zchf_;
        ccipAdmin = ccipAdmin_;
    }

    // ==================== Minter Suggestion & Veto ====================

    /**
     * @notice Publicly accessible method to suggest a new way of minting Frankencoin.
     *
     * Wraps the existing functionality in Frankencoin to enforce a 90 days application period.
     * The fee is forwarded to Frankencoin. Minters suggested through this contract are recorded
     * and protected from being vetoed through denyMinter.
     */
    function suggestMinter(address _minter, uint256 _applicationPeriod, uint256 _applicationFee, string calldata _message) external {
        if (_applicationPeriod < MIN_APPLICATION_PERIOD) revert PeriodTooShort();
        zchf.transferFrom(msg.sender, address(this), _applicationFee);
        zchf.suggestMinter(_minter, _applicationPeriod, _applicationFee, _message);
        announcements[_minter] = block.timestamp;
        emit MinterAnnounced(msg.sender, _minter, block.timestamp);
    }

    /**
     * @notice Veto a minter that was not announced through FPS2. Anyone can call this.
     * Minters that were properly announced through suggestMinter are protected.
     * @param minter          The minter to veto
     */
    function denyUnannouncedMinter(address minter) external {
        if (announcements[minter] != 0) revert MinterCorrectlyAnnounced();
        zchf.denyMinter(minter, new address[](0), "Minters must be suggested through the FPS2 contract");
        emit MinterVetoed(minter, "Minters must be suggested through the FPS2 contract");
    }

    function denyMinter(address minter, address[] calldata helpers, string calldata message) external {
        this.checkQualified(msg.sender, helpers);
        zchf.denyMinter(minter, new address[](0), message);
    }

    // ==================== Access to existing governance functions ====================

    /**
     * @notice Deny a minting position on behalf of qualified FPS2 holders.
     * Wraps Position.deny, which checks qualification against the old Equity contract.
     * Since FPS2 holds FPS, it passes the old equity's qualification check.
     * @param position  The position contract to deny
     * @param helpers   FPS2 holders who delegate their votes to the caller
     * @param message   Reason for the denial
     */
    function denyPosition(address position, address[] calldata helpers, string calldata message) external {
        this.checkQualified(msg.sender, helpers);
        IPosition(position).deny(new address[](0), message);
    }

    /**
     * @notice Propose a borrowing rate change on behalf of qualified FPS2 holders.
     * @param newRatePPM    The proposed new rate in parts per million
     * @param helpers       FPS2 holders who delegate their votes to the caller
     */
    function proposeBorrowingRate(uint24 newRatePPM, address[] calldata helpers) external {
        this.checkQualified(msg.sender, helpers);
        BORROWING_LEADRATE.proposeChange(newRatePPM, new address[](0));
    }

    /**
     * @notice Propose a savings rate change on behalf of qualified FPS2 holders.
     * @param newRatePPM    The proposed new rate in parts per million
     * @param helpers       FPS2 holders who delegate their votes to the caller
     */
    function proposeSavingsRate(uint24 newRatePPM, address[] calldata helpers) external {
        this.checkQualified(msg.sender, helpers);
        SAVINGS_LEADRATE.proposeChange(newRatePPM, new address[](0));
    }

    /**
     * @notice Restructure the cap table of the old Equity contract when equity is critically low.
     * Wraps Equity.restructureCapTable, which checks qualification against the old Equity contract.
     * @param helpers          FPS2 holders who delegate their votes to the caller
     * @param addressesToWipe  Addresses whose FPS will be burned on the old Equity contract
     */
    function restructureCapTable(address[] calldata helpers, address[] calldata addressesToWipe) external {
        this.checkQualified(msg.sender, helpers);
        IEquityRestructure(address(zchf.reserve())).restructureCapTable(new address[](0), addressesToWipe);
    }

    // ==================== CCIPAdmin governance functions ====================

    /**
     * @notice Propose a remote pool update on the CCIPAdmin contract.
     * @param update  The remote pool update to propose
     * @param helpers FPS2 holders who delegate their votes to the caller
     */
    function ccipProposeRemotePoolUpdate(ICCIPAdmin.RemotePoolUpdate memory update, address[] calldata helpers) external {
        this.checkQualified(msg.sender, helpers);
        ccipAdmin.proposeRemotePoolUpdate(update, new address[](0));
    }

    /**
     * @notice Propose to remove a remote chain on the CCIPAdmin contract.
     * @param chainId  The chain to remove
     * @param helpers  FPS2 holders who delegate their votes to the caller
     */
    function ccipProposeRemoveChain(uint64 chainId, address[] calldata helpers) external {
        this.checkQualified(msg.sender, helpers);
        ccipAdmin.proposeRemoveChain(chainId, new address[](0));
    }

    /**
     * @notice Propose to add a remote chain on the CCIPAdmin contract.
     * @param config   The chain configuration to add
     * @param helpers  FPS2 holders who delegate their votes to the caller
     */
    function ccipProposeAddChain(ITokenPool.ChainUpdate calldata config, address[] calldata helpers) external {
        this.checkQualified(msg.sender, helpers);
        ccipAdmin.proposeAddChain(config, new address[](0));
    }

    /**
     * @notice Propose an admin transfer on the CCIPAdmin contract.
     * @param newAdmin  The proposed new admin address
     * @param helpers   FPS2 holders who delegate their votes to the caller
     */
    function ccipProposeAdminTransfer(address newAdmin, address[] calldata helpers) external {
        this.checkQualified(msg.sender, helpers);
        ccipAdmin.proposeAdminTransfer(newAdmin, new address[](0));
    }

    /**
     * @notice Apply rate limits on the CCIPAdmin contract. Used in emergencies (e.g. chain hacked).
     * @param chain     The chain to set rate limits for
     * @param inbound   Inbound rate limit config
     * @param outbound  Outbound rate limit config
     * @param helpers   FPS2 holders who delegate their votes to the caller
     */
    function ccipApplyRateLimit(uint64 chain, RateLimiter.Config calldata inbound, RateLimiter.Config calldata outbound, address[] calldata helpers) external {
        this.checkQualified(msg.sender, helpers);
        ccipAdmin.applyRateLimit(chain, inbound, outbound, new address[](0));
    }

    /**
     * @notice Deny a pending proposal on the CCIPAdmin contract.
     * @param hash     The proposal hash to deny
     * @param helpers  FPS2 holders who delegate their votes to the caller
     */
    function ccipDenyProposal(bytes32 hash, address[] calldata helpers) external {
        this.checkQualified(msg.sender, helpers);
        ccipAdmin.deny(hash, new address[](0));
    }

}

/**
 * @notice Minimal interface for calling proposeChange on a Leadrate contract.
 */
interface ILeadrateProposal {
    function proposeChange(uint24 newRatePPM_, address[] calldata helpers) external;
}

/**
 * @notice Minimal interface for calling restructureCapTable on the Equity contract.
 */
interface IEquityRestructure {
    function restructureCapTable(address[] calldata helpers, address[] calldata addressesToWipe) external;
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
