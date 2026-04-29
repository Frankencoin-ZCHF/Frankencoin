// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IModuleRegistry} from "../registry/IModuleRegistry.sol";

/**
 * @title IGrants
 * @notice Interface for the Grants contract — a governance-gated decentralized compensation
 *         streamer that allows proposals for recurring ZCHF payments drawn from the reserve.
 *
 * @dev Lifecycle overview:
 *
 *   propose(0, params)  ──►  [veto window: 30 days]  ──►  accept()  → grant active
 *                                      │
 *                                   revoke()                          → deposit → reserve as profit
 *
 *   propose(grantId, ...)  ──►  [veto window: 30 days]  ──►  accept()  → grant stopped
 *   (stop: grantId > 0)
 *
 *   Active grants: anyone calls stream() to settle accumulated complete periods.
 *   ZCHF flows from the reserve via registry.moduleLoss() directly to the recipient.
 *   Periods are counted up to min(block.timestamp, grant.expiry) so final periods
 *   remain claimable after a grant is stopped or expires naturally.
 *
 *   The Grants contract must be registered as an active module in the ModuleRegistry.
 *   It does not need to be a direct ZCHF minter; all minter-privilege calls are
 *   proxied through the registry.
 */
interface IGrants {

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    /// @notice Classifies a proposal so off-chain tooling and events can filter by intent.
    enum ProposalType { New, Stop }

    /**
     * @notice A grant stream configuration and live settlement state.
     * @dev Storage layout — 2 slots:
     *        Slot 1: recipient (20 bytes) | streamAmount (12 bytes)
     *        Slot 2: streamPeriod (8 bytes) | latestSettlement (8 bytes) | expiry (8 bytes) | settlements (8 bytes)
     * @param recipient         Address that receives ZCHF on each settlement.
     * @param streamAmount      ZCHF (18 decimals) paid per complete period.
     * @param streamPeriod      Length of one period in seconds.
     * @param latestSettlement  Timestamp anchor for the next period calculation; initialised to
     *                          block.timestamp on accept() and advanced by whole periods on stream().
     * @param expiry            Timestamp after which no new periods accrue. Periods that accrued
     *                          before expiry are still claimable after this point.
     * @param settlements       Total number of stream() calls that settled at least one period.
     */
    struct Grant {
        address recipient;
        uint96  streamAmount;
        uint64  streamPeriod;
        uint64  latestSettlement;
        uint64  expiry;
        uint64  settlements;
    }

    /**
     * @notice A pending proposal to create or stop a grant.
     * @dev Storage layout — 3 slots:
     *        Slot 1: proposer (20 bytes) | fee (12 bytes)
     *        Slot 2: recipient (20 bytes) | streamAmount (12 bytes)
     *        Slot 3: streamPeriod (8 bytes) | activateAt (8 bytes) | grantExpiry (8 bytes) | ptype (1 byte)
     * @param proposer      Address that submitted the proposal; receives the fee refund on accept.
     * @param fee           ZCHF amount held in escrow; refunded on accept, forwarded to reserve on revoke.
     * @param recipient     Recipient of the grant stream (non-zero for New proposals only).
     * @param streamAmount  ZCHF per period (New proposals only).
     * @param streamPeriod  Seconds per period (New proposals only).
     * @param activateAt    Timestamp after which accept() may be called (block.timestamp + VETO_PERIOD).
     * @param grantExpiry   Expiry timestamp that will be written to the grant on accept.
     * @param ptype         New or Stop.
     */
    struct Proposal {
        address      proposer;
        uint96       fee;
        address      recipient;
        uint96       streamAmount;
        uint64       streamPeriod;
        uint64       activateAt;
        uint64       grantExpiry;
        ProposalType ptype;
    }

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /**
     * @notice Emitted when a proposal is submitted.
     * @param grantId     Grant ID being proposed (pre-assigned for New, existing for Stop).
     * @param proposer    Address that submitted and paid the fee.
     * @param ptype       New or Stop.
     * @param grantExpiry Proposed grant expiry timestamp (overridden to activateAt for Stop).
     * @param activateAt  Earliest timestamp at which accept() can be called.
     * @param message     Optional free-text message from the proposer.
     */
    event GrantProposed(
        uint256 indexed grantId,
        address indexed proposer,
        ProposalType    ptype,
        uint64          grantExpiry,
        uint64          activateAt,
        string          message
    );

    /**
     * @notice Emitted when a qualified FPS holder revokes a proposal within the veto window.
     * @param grantId  The grant ID whose proposal was revoked.
     * @param sender   The FPS holder who called revoke().
     * @param message  Optional free-text reason from the revoker.
     */
    event GrantRevoked(uint256 indexed grantId, address indexed sender, string message);

    /**
     * @notice Emitted when a proposal is accepted after the veto window closes.
     * @param grantId  The grant ID now active (New) or stopped (Stop).
     * @param sender   The address that called accept().
     * @param expiry   The expiry value that was applied to the grant.
     */
    event GrantAccepted(uint256 indexed grantId, address indexed sender, uint64 expiry);

    /**
     * @notice Emitted when stream() settles one or more complete periods.
     * @param grantId   The grant ID that was streamed.
     * @param recipient The address that received the ZCHF.
     * @param amount    Total ZCHF forwarded in this settlement.
     * @param periods   Number of complete periods settled in this single call.
     */
    event GrantStreamed(
        uint256 indexed grantId,
        address indexed recipient,
        uint256 amount,
        uint64  periods
    );

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown by propose() when a pending proposal already exists for the given grant ID.
    error AlreadyProposed();
    /// @notice Thrown by revoke() or accept() when no pending proposal exists for the given grant ID.
    error NoProposal();
    /// @notice Thrown by revoke() when the veto window has already closed.
    error VetoPeriodOver();
    /// @notice Thrown by accept() when the veto window has not yet closed.
    error VetoPeriodActive();
    /// @notice Thrown by propose() when the submitted fee is below MIN_PROPOSAL_FEE.
    error FeeTooLow();
    /// @notice Thrown by propose(New) when the expiry is outside the valid range.
    error InvalidExpiration();
    /// @notice Thrown by propose(New) when recipient, streamAmount, or streamPeriod is zero.
    error InvalidParameters();
    /// @notice Thrown by stream() when the grant ID has no accepted grant.
    error InvalidGrant();
    /// @notice Thrown by stream() when fewer than one complete period has elapsed.
    error NothingToStream();
    /// @notice Thrown by propose(Stop) when the target grant does not exist or is already expired.
    error GrantNotActive();

    // -------------------------------------------------------------------------
    // Functions
    // -------------------------------------------------------------------------

    /**
     * @notice Submit a proposal to create a new grant stream or stop an existing one.
     * @dev When grantId == 0, a new grant ID is assigned automatically (nextGrantId) and all
     *      grant parameters are recorded in the proposal.
     *      When grantId > 0, this is a Stop proposal; the target grant must be currently active.
     *      The expiry, recipient, streamAmount, and streamPeriod parameters are ignored for Stop
     *      proposals. The grant's expiry will be overridden to block.timestamp + VETO_PERIOD
     *      (activateAt) so the stream stops predictably one veto window after submission.
     *      The fee is held in escrow until accept() (refunded) or revoke() (forwarded to reserve).
     * @param grantId      0 = create new grant (ID assigned automatically); non-zero = stop this grant.
     * @param fee          ZCHF deposit, must be >= MIN_PROPOSAL_FEE.
     * @param expiry       Desired grant expiry timestamp (New proposals only; ignored for Stop).
     * @param recipient    Grant recipient address (New proposals only).
     * @param streamAmount ZCHF per period, 18-decimal (New proposals only).
     * @param streamPeriod Seconds per period (New proposals only).
     * @param message      Optional human-readable note, e.g. a link to a governance document.
     */
    function propose(
        uint256 grantId,
        uint96  fee,
        uint64  expiry,
        address recipient,
        uint96  streamAmount,
        uint64  streamPeriod,
        string calldata message
    ) external;

    /**
     * @notice Revoke a pending proposal within the 30-day veto window.
     * @dev Caller must be a qualified FPS holder (checked via reserve.checkQualified).
     *      The escrowed fee is forwarded to the ZCHF reserve as profit.
     * @param grantId  The grant ID whose proposal should be revoked.
     * @param helpers  Additional FPS holder addresses to reach the vote threshold.
     * @param message  Optional free-text reason for the revocation.
     */
    function revoke(uint256 grantId, address[] calldata helpers, string calldata message) external;

    /**
     * @notice Accept a proposal after the 30-day veto window has closed.
     * @dev Permissionless — anyone may call once activateAt has passed.
     *      For New proposals: writes the grant to storage with latestSettlement = block.timestamp.
     *      For Stop proposals: sets the grant's expiry to the stored grantExpiry (activateAt, already
     *      past or equal to block.timestamp), terminating future period accrual.
     *      In both cases the escrowed fee is refunded to the original proposer.
     * @param grantId The grant ID to activate or stop.
     */
    function accept(uint256 grantId) external;

    /**
     * @notice Settle all complete periods that have accrued since the last settlement.
     * @dev Permissionless — anyone may call on behalf of any grant.
     *      Elapsed time is capped at grant.expiry so periods that accrued before a grant stopped
     *      remain claimable even after block.timestamp exceeds expiry.
     *      Calls zchf.coverLoss to pull ZCHF from the reserve directly to the recipient.
     *      Reverts NothingToStream if no complete period has elapsed since latestSettlement
     *      (up to expiry).
     * @param grantId The grant ID to stream.
     */
    function stream(uint256 grantId) external;

    /**
     * @notice Returns true when the grant exists and its expiry is in the future.
     * @param grantId The grant ID to query.
     */
    function isActive(uint256 grantId) external view returns (bool);

    /**
     * @notice Returns the ModuleRegistry this contract routes minter-privilege calls through.
     */
    function registry() external view returns (IModuleRegistry);
}
