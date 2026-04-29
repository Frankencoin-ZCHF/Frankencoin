// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../registry/IModuleRegistry.sol";
import "./IGrants.sol";

/**
 * @title Grants
 * @notice Governance-gated decentralized compensation streamer for recurring ZCHF grant payments.
 *
 * @dev The Grants contract operates as a module inside the ModuleRegistry. It does not hold
 *      direct ZCHF minter status; all minter-privilege calls (coverLoss, collectProfits) are
 *      routed through the registry via moduleLoss / moduleProfit.
 *
 *      Governance flow:
 *        1. Anyone calls propose(), paying a ZCHF deposit (>= MIN_PROPOSAL_FEE).
 *        2. FPS holders have VETO_PERIOD (30 days) to call revoke().
 *           If revoked, the deposit goes to the reserve as profit and the proposal is deleted.
 *        3. After VETO_PERIOD, anyone calls accept() to apply the grant and refund
 *           the deposit to the original proposer.
 *
 *      Two proposal types resolved in propose():
 *        - New:  grantId == 0; creates a new periodic grant stream, assigning the next ID.
 *        - Stop: grantId > 0; retires an active grant; expiry overridden to block.timestamp +
 *                VETO_PERIOD so the stream stops exactly one veto window after submission,
 *                giving a predictable wind-down window during which streaming still works.
 *
 *      Once a grant is active, anyone calls stream() to settle all elapsed complete periods.
 *      Elapsed time is capped at grant.expiry so final periods remain claimable after expiry.
 *
 *      This contract must be registered as an active module in the ModuleRegistry before
 *      stream() and revoke() will work. Registration goes through the registry's own
 *      propose → accept governance flow.
 */
contract Grants is IGrants {

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice Duration of the veto window within which FPS holders may revoke a proposal.
    uint256 public constant VETO_PERIOD = 30 days;

    /// @notice Maximum grant lifetime that can be requested in a New proposal.
    uint256 public constant MAX_GRANT_LIFETIME = 10 * 365 days;

    /// @notice Minimum ZCHF deposit required to submit any proposal.
    uint96 public constant MIN_PROPOSAL_FEE = 1000 * 10 ** 18;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /// @notice The ModuleRegistry this contract is registered in; routes all minter-privilege calls.
    IModuleRegistry public immutable registry;

    /// @notice The Frankencoin contract, derived from the registry.
    IBasicFrankencoin public immutable zchf;

    /// @notice The next grant ID to assign on a New proposal. Starts at 1; 0 is the sentinel for New.
    uint256 public nextGrantId = 1;

    /// @notice Accepted grant streams, indexed by grant ID. recipient == address(0) means no grant.
    mapping(uint256 => Grant) public grants;

    /// @notice Pending proposals, indexed by grant ID. activateAt == 0 means no proposal.
    mapping(uint256 => Proposal) public proposals;

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    /**
     * @notice Guards revoke() and accept() — requires a pending proposal to exist (mustExist = true)
     *         or not exist (mustExist = false) for the given grant ID.
     * @dev Uses activateAt as the existence sentinel: 0 means no proposal.
     */
    modifier proposal(uint256 grantId, bool mustExist) {
        if ((proposals[grantId].activateAt != 0) != mustExist) {
            if (mustExist) revert NoProposal();
            else revert AlreadyProposed();
        }
        _;
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @param registry_ The ModuleRegistry that this Grants contract will be registered in.
    constructor(IModuleRegistry registry_) {
        registry = registry_;
        zchf     = registry_.zchf();
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @inheritdoc IGrants
    function isActive(uint256 grantId) public view override returns (bool) {
        Grant storage g = grants[grantId];
        return g.recipient != address(0) && g.expiry > block.timestamp;
    }

    // -------------------------------------------------------------------------
    // Core governance
    // -------------------------------------------------------------------------

    /// @inheritdoc IGrants
    function propose(
        uint256 grantId,
        uint96  fee,
        uint64  expiry,
        address recipient,
        uint96  streamAmount,
        uint64  streamPeriod,
        string calldata message
    ) external override {
        if (fee < MIN_PROPOSAL_FEE) revert FeeTooLow();

        uint64 activateAt = uint64(block.timestamp + VETO_PERIOD);
        ProposalType ptype;
        uint64 grantExpiry;

        if (grantId == 0) {
            // New grant: validate parameters and assign a fresh ID.
            if (recipient == address(0) || streamAmount == 0 || streamPeriod == 0) revert InvalidParameters();
            if (expiry <= activateAt || expiry > uint64(block.timestamp + MAX_GRANT_LIFETIME)) revert InvalidExpiration();

            grantId     = nextGrantId++;
            grantExpiry = expiry;
            ptype       = ProposalType.New;

            proposals[grantId] = Proposal(msg.sender, fee, recipient, streamAmount, streamPeriod, activateAt, grantExpiry, ptype);
        } else {
            // Stop: target grant must be active; no pending proposal may exist.
            if (!isActive(grantId))                revert GrantNotActive();
            if (proposals[grantId].activateAt != 0) revert AlreadyProposed();

            // Override expiry to now + VETO_PERIOD so the grant stops predictably exactly one
            // veto window after submission, giving a wind-down window for final settlements.
            grantExpiry = activateAt;
            ptype       = ProposalType.Stop;

            proposals[grantId] = Proposal(msg.sender, fee, address(0), 0, 0, activateAt, grantExpiry, ptype);
        }

        zchf.transferFrom(msg.sender, address(this), fee);
        emit GrantProposed(grantId, msg.sender, ptype, grantExpiry, activateAt, message);
    }

    /// @inheritdoc IGrants
    function revoke(uint256 grantId, address[] calldata helpers, string calldata message)
        external override proposal(grantId, true)
    {
        if (block.timestamp >= proposals[grantId].activateAt) revert VetoPeriodOver();
        zchf.reserve().checkQualified(msg.sender, helpers);
        uint96 fee = proposals[grantId].fee;
        delete proposals[grantId];
        registry.moduleProfit(address(this), fee);
        emit GrantRevoked(grantId, msg.sender, message);
    }

    /// @inheritdoc IGrants
    function accept(uint256 grantId) external override proposal(grantId, true) {
        Proposal memory p = proposals[grantId];
        if (block.timestamp < p.activateAt) revert VetoPeriodActive();
        delete proposals[grantId];

        if (p.ptype == ProposalType.New) {
            grants[grantId] = Grant({
                recipient:        p.recipient,
                streamAmount:     p.streamAmount,
                streamPeriod:     p.streamPeriod,
                latestSettlement: uint64(block.timestamp),
                expiry:           p.grantExpiry,
                settlements:      0
            });
        } else {
            // Stop: set expiry to grantExpiry (== activateAt, already past or equal to now).
            // Any periods that accrued before this point remain claimable via stream().
            grants[grantId].expiry = p.grantExpiry;
        }

        zchf.transfer(p.proposer, p.fee);
        emit GrantAccepted(grantId, msg.sender, p.grantExpiry);
    }

    // -------------------------------------------------------------------------
    // Streaming
    // -------------------------------------------------------------------------

    /// @inheritdoc IGrants
    function stream(uint256 grantId) external override {
        Grant storage g = grants[grantId];
        if (g.recipient == address(0)) revert InvalidGrant();

        // Cap elapsed time at grant.expiry so periods that accrued before a stop remain claimable.
        uint64 until = uint64(block.timestamp) < g.expiry ? uint64(block.timestamp) : g.expiry;
        if (until <= g.latestSettlement) revert NothingToStream();

        uint64 periods = (until - g.latestSettlement) / g.streamPeriod;
        if (periods == 0) revert NothingToStream();

        g.latestSettlement += periods * g.streamPeriod;
        g.settlements      += 1;

        uint256 amount = uint256(periods) * uint256(g.streamAmount);
        registry.moduleLoss(g.recipient, amount);

        emit GrantStreamed(grantId, g.recipient, amount, periods);
    }
}
