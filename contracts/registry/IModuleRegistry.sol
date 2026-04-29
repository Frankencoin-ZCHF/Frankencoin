// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IBasicFrankencoin} from "../stablecoin/IBasicFrankencoin.sol";

/**
 * @title IModuleRegistry
 * @notice Interface for the ModuleRegistry — a governance-gated minting proxy that manages
 *         the lifecycle of ZCHF minting modules.
 *
 * @dev Lifecycle overview:
 *
 *   propose()  ──►  [veto window: 30 days]  ──►  accept()   → module active
 *                          │
 *                       revoke()                             → deposit → reserve as profit
 *
 *   Three proposal categories are inferred automatically from the expiration argument:
 *     - New:        module has no active registration (moduleExpiry == 0 or expired)
 *     - Extension:  expiration > current moduleExpiry (extend an active module's TTL)
 *     - Retirement: expiration < current moduleExpiry; stored expiration is overridden to
 *                   block.timestamp + VETO_PERIOD so retirement is always exactly one veto
 *                   window away, giving a predictable off-boarding transition.
 *
 *   Active modules call moduleMint / moduleBurn on the registry, which proxies to ZCHF.
 *   The registry itself must be a registered ZCHF minter for these calls to succeed.
 */
interface IModuleRegistry {
    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    /// @notice Classifies a proposal so off-chain tooling and events can filter by intent.
    enum ProposalCategory { New, Extension, Retirement }

    /**
     * @notice Pending proposal for a module address.
     * @dev Storage layout — 2 slots:
     *        Slot 1: proposer (20 bytes) | fee (12 bytes)
     *        Slot 2: expiration (8 bytes) | activateAt (8 bytes)
     * @param proposer   Address that submitted the proposal; receives the fee refund on accept.
     * @param fee        ZCHF amount held in escrow; refunded on accept, sent to reserve on revoke.
     * @param expiration The moduleExpiry value that will be written if the proposal is accepted.
     * @param activateAt Timestamp after which accept() may be called (block.timestamp + VETO_PERIOD).
     */
    struct Proposal {
        address proposer;
        uint96  fee;
        uint64  expiration;
        uint64  activateAt;
    }

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /**
     * @notice Emitted when a proposal is submitted.
     * @param module      The module address being proposed.
     * @param proposer    Address that submitted and paid the fee.
     * @param category    New, Extension, or Retirement.
     * @param expiration  Proposed moduleExpiry value (already overridden for Retirement).
     * @param activateAt  Earliest timestamp at which accept() can be called.
     * @param message     Optional free-text message from the proposer (e.g. a link to docs).
     */
    event ModuleProposed(
        address indexed module,
        address indexed proposer,
        ProposalCategory category,
        uint64 expiration,
        uint64 activateAt,
        string message
    );

    /**
     * @notice Emitted when a qualified FPS holder revokes a proposal within the veto window.
     * @param module   The module address whose proposal was revoked.
     * @param sender   The FPS holder who called revoke().
     * @param message  Optional free-text reason from the revoker.
     */
    event ModuleRevoked(address indexed module, address indexed sender, string message);

    /**
     * @notice Emitted when a proposal is accepted after the veto window closes.
     * @param module      The module address now registered (or updated).
     * @param sender      The address that called accept().
     * @param expiration  The moduleExpiry value that was applied.
     */
    event ModuleAccepted(address indexed module, address indexed sender, uint64 expiration);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown by propose() when a pending proposal already exists for the module.
    error AlreadyProposed();
    /// @notice Thrown by revoke() or accept() when no pending proposal exists for the module.
    error NoProposal();
    /// @notice Thrown by revoke() when the 30-day veto window has already closed.
    error VetoPeriodOver();
    /// @notice Thrown by accept() when the 30-day veto window has not yet closed.
    error VetoPeriodActive();
    /// @notice Thrown by propose() when the supplied expiration is inconsistent with the category
    ///         rules (e.g. too soon for a New proposal, or retirement window would extend the TTL).
    error InvalidExpiration();
    /// @notice Thrown by propose() when the supplied fee is below MIN_PROPOSAL_FEE.
    error FeeTooLow();
    /// @notice Thrown by moduleMint(), moduleBurn(), moduleProfit(), moduleLoss(), or moduleTransfer() when the caller is not an active module.
    error NotActive();

    // -------------------------------------------------------------------------
    // Functions
    // -------------------------------------------------------------------------

    /**
     * @notice Submit a proposal to register, extend, or retire a module.
     * @dev The proposal category is inferred from `expiration` vs `moduleExpiry[module]`:
     *        - New:        no active registration exists; expiration must be > now + VETO_PERIOD.
     *        - Extension:  expiration > current moduleExpiry.
     *        - Retirement: expiration < current moduleExpiry; the stored value is overridden to
     *                      block.timestamp + VETO_PERIOD regardless of what is passed.
     *      `fee` is held in escrow by the registry until accept() (refunded) or revoke() (→ reserve).
     * @param module     The module contract address being proposed.
     * @param fee        ZCHF deposit, must be >= MIN_PROPOSAL_FEE.
     * @param expiration Desired new moduleExpiry timestamp. Ignored for Retirement (overridden).
     * @param message    Optional human-readable message, e.g. a link to a proposal document.
     */
    function propose(address module, uint96 fee, uint64 expiration, string calldata message) external;

    /**
     * @notice Revoke a pending proposal within the 30-day veto window.
     * @dev Caller must be a qualified FPS holder (checked via reserve.checkQualified).
     *      The escrowed fee is forwarded to the ZCHF reserve as profit.
     * @param module   The module address whose proposal should be revoked.
     * @param helpers  Additional FPS holder addresses used to reach the vote threshold.
     * @param message  Optional free-text reason for the revocation.
     */
    function revoke(address module, address[] calldata helpers, string calldata message) external;

    /**
     * @notice Accept a proposal after the 30-day veto window has closed.
     * @dev Permissionless — anyone may call once activateAt has passed.
     *      Writes the new expiration to moduleExpiry and refunds the escrowed fee to the proposer.
     * @param module The module address to activate or update.
     */
    function accept(address module) external;

    /**
     * @notice Mint ZCHF to `target` on behalf of the calling module.
     * @dev Only callable by an address whose moduleExpiry is in the future.
     *      The registry must be a registered ZCHF minter for this to succeed.
     * @param target  Recipient of the newly minted ZCHF.
     * @param amount  Amount of ZCHF to mint (18 decimals).
     */
    function moduleMint(address target, uint256 amount) external;

    /**
     * @notice Burn `amount` ZCHF from `owner` on behalf of the calling module.
     * @dev Only callable by an address whose moduleExpiry is in the future.
     *      The registry must be a registered ZCHF minter for this to succeed.
     * @param owner   Address whose ZCHF balance is burned.
     * @param amount  Amount of ZCHF to burn (18 decimals).
     */
    function moduleBurn(address owner, uint256 amount) external;

    /**
     * @notice Collect `amount` ZCHF from `source` into the reserve as profit on behalf of the calling module.
     * @dev Only callable by an address whose moduleExpiry is in the future.
     *      Proxies to zchf.collectProfits(source, amount). The registry must be a registered
     *      ZCHF minter for this to succeed.
     * @param source  Address whose ZCHF is transferred to the reserve.
     * @param amount  Amount of ZCHF to collect (18 decimals).
     */
    function moduleProfit(address source, uint256 amount) external;

    /**
     * @notice Cover `amount` ZCHF loss from the reserve, sending it to `source`, on behalf of the calling module.
     * @dev Only callable by an address whose moduleExpiry is in the future.
     *      Proxies to zchf.coverLoss(source, amount). The registry must be a registered
     *      ZCHF minter for this to succeed.
     * @param source  Address that receives the ZCHF loss coverage.
     * @param amount  Amount of ZCHF to cover (18 decimals).
     */
    function moduleLoss(address source, uint256 amount) external;

    /**
     * @notice Transfer `amount` ZCHF from `source` to `target` on behalf of the calling module.
     * @dev Only callable by an address whose moduleExpiry is in the future.
     *      Proxies to zchf.transferFrom(source, target, amount). Because the registry is a registered
     *      ZCHF minter, Frankencoin grants it infinite allowance on all addresses (see _allowance()),
     *      so no explicit approval from `source` is required.
     * @param source  Address whose ZCHF balance is debited.
     * @param target  Address that receives the ZCHF.
     * @param amount  Amount of ZCHF to transfer (18 decimals).
     */
    function moduleTransfer(address source, address target, uint256 amount) external;

    /**
     * @notice Returns true if `module` has a non-expired registration.
     * @param module The address to check.
     * @return True when moduleExpiry[module] > block.timestamp.
     */
    function isActive(address module) external view returns (bool);

    /**
     * @notice Returns the timestamp at which `module`'s registration expires.
     * @dev Returns 0 if the module has never been registered or has been retired.
     * @param module The address to check.
     */
    function moduleExpiry(address module) external view returns (uint64);

    /**
     * @notice Returns the Frankencoin contract this registry proxies minting through.
     */
    function zchf() external view returns (IBasicFrankencoin);
}
