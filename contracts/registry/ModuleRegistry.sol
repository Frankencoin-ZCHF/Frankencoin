// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../stablecoin/IBasicFrankencoin.sol";
import "./IModuleRegistry.sol";
import "./IModule.sol";

/**
 * @title ModuleRegistry
 * @notice Governance-gated registry that controls which contracts may mint and burn ZCHF.
 *
 * @dev The registry is itself a ZCHF minter module. Active sub-modules call moduleMint /
 *      moduleBurn on this contract, which proxies to ZCHF. This creates a single governance
 *      choke-point: only modules approved through this registry gain minting access.
 *
 *      Governance flow:
 *        1. Anyone calls propose(), paying a ZCHF deposit (>= MIN_PROPOSAL_FEE).
 *        2. FPS holders have VETO_PERIOD (30 days) to call revoke().
 *           If revoked, the deposit goes to the reserve as profit and the proposal is deleted.
 *        3. After VETO_PERIOD, anyone calls accept() to apply the new expiration and refund
 *           the deposit to the original proposer.
 *
 *      Three proposal categories are resolved automatically in propose():
 *        - New:        no existing (or expired) registration for the module address.
 *        - Extension:  expiration > current moduleExpiry (extend an active module's TTL).
 *        - Retirement: expiration < current moduleExpiry; the stored expiration is overridden
 *                      to block.timestamp + VETO_PERIOD so the module sunsets predictably
 *                      exactly one veto window after the proposal is submitted.
 *
 *      This contract must be registered as a minter on the Frankencoin contract before
 *      moduleMint, moduleBurn, and collectProfits will work. Registration is handled
 *      by the deployer via zchf.suggestMinter() after deployment.
 */
contract ModuleRegistry is IModuleRegistry {
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice Duration of the veto window within which FPS holders may revoke a proposal.
    uint256 public constant VETO_PERIOD = 30 days;

    /// @notice Maximum lifetime that can be requested for any single proposal (New or Extension).
    uint256 public constant MAX_MODULE_LIFETIME = 100 * 365 days;

    /// @notice Minimum ZCHF deposit required to submit any proposal.
    uint96 public constant MIN_PROPOSAL_FEE = 1000 * 10 ** 18;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /// @notice The Frankencoin contract used for minting, burning, and profit collection.
    IBasicFrankencoin public immutable zchf;

    /// @notice Maps a module address to its authorization expiry timestamp.
    ///         0 means the module has never been registered or has been retired.
    mapping(address => uint64) public moduleExpiry;

    /// @notice Pending proposals indexed by module address.
    ///         An entry exists only while a proposal is awaiting revocation or acceptance.
    ///         Entries are deleted by revoke() and accept().
    mapping(address => Proposal) public proposals;

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    /**
     * @notice Guards functions that require a proposal to exist (mustExist = true) or
     *         to not exist (mustExist = false) for the given module.
     * @dev Uses activateAt as the existence sentinel: 0 means no proposal.
     */
    modifier proposal(address module, bool mustExist) {
        if ((proposals[module].activateAt != 0) != mustExist) {
            if (mustExist) revert NoProposal();
            else revert AlreadyProposed();
        }
        _;
    }

    /**
     * @notice Restricts a function to callers that are currently active modules.
     * @dev Used on moduleMint and moduleBurn so only registered, non-expired modules
     *      can trigger ZCHF minting or burning through this registry.
     */
    modifier onlyRegisteredModule() {
        if (!isActive(msg.sender)) revert NotActive();
        _;
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @param zchf_ Address of the Frankencoin (ZCHF) contract.
    constructor(IBasicFrankencoin zchf_) {
        zchf = zchf_;
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @inheritdoc IModuleRegistry
    function isActive(address module) public view override returns (bool) {
        return moduleExpiry[module] > block.timestamp;
    }

    // -------------------------------------------------------------------------
    // Core governance
    // -------------------------------------------------------------------------

    /// @inheritdoc IModuleRegistry
    function propose(address module, uint96 fee, uint64 expiration, string calldata message) external proposal(module, false) {
        if (fee < MIN_PROPOSAL_FEE) revert FeeTooLow();

        uint64 activateAt = uint64(block.timestamp + VETO_PERIOD);
        uint64 maxExpiry = uint64(block.timestamp + MAX_MODULE_LIFETIME);
        uint64 currentExpiry = moduleExpiry[module];
        ProposalCategory category;

        if (currentExpiry == 0 || block.timestamp >= currentExpiry) {
            // New or re-proposal for an expired module.
            if (expiration <= activateAt || expiration > maxExpiry) revert InvalidExpiration();
            category = ProposalCategory.New;
        } else if (expiration > currentExpiry) {
            // Extend the TTL of an active module.
            if (expiration > maxExpiry) revert InvalidExpiration();
            category = ProposalCategory.Extension;
        } else {
            // Early retirement: override expiration to now + VETO_PERIOD so the module
            // sunsets exactly when the veto window closes, giving a predictable transition.
            expiration = activateAt;
            if (expiration >= currentExpiry) revert InvalidExpiration();
            category = ProposalCategory.Retirement;
        }

        zchf.transferFrom(msg.sender, address(this), fee);
        proposals[module] = Proposal(msg.sender, fee, expiration, activateAt);
        emit ModuleProposed(module, msg.sender, category, expiration, activateAt, message);
    }

    /// @inheritdoc IModuleRegistry
    function revoke(address module, address[] calldata helpers, string calldata message) external proposal(module, true) {
        if (block.timestamp >= proposals[module].activateAt) revert VetoPeriodOver();
        zchf.reserve().checkQualified(msg.sender, helpers);
        uint96 fee = proposals[module].fee;
        delete proposals[module];
        zchf.collectProfits(address(this), fee);
        emit ModuleRevoked(module, msg.sender, message);
    }

    /// @inheritdoc IModuleRegistry
    function accept(address module) external proposal(module, true) {
        if (block.timestamp < proposals[module].activateAt) revert VetoPeriodActive();
        Proposal memory p = proposals[module];
        delete proposals[module];
        moduleExpiry[module] = p.expiration;
        zchf.transfer(p.proposer, p.fee);
        emit ModuleAccepted(module, msg.sender, p.expiration);
    }

    // -------------------------------------------------------------------------
    // Minting proxy
    // -------------------------------------------------------------------------

    /// @inheritdoc IModuleRegistry
    function moduleMint(address target, uint256 amount) external onlyRegisteredModule {
        zchf.mint(target, amount);
    }

    /// @inheritdoc IModuleRegistry
    function moduleBurn(address owner, uint256 amount) external onlyRegisteredModule {
        zchf.burnFrom(owner, amount);
    }

    /// @inheritdoc IModuleRegistry
    function moduleTransfer(address target, uint256 amount) external onlyRegisteredModule {
        zchf.transfer(target, amount);
    }

    /// @inheritdoc IModuleRegistry
    function moduleProfit(address source, uint256 amount) external onlyRegisteredModule {
        zchf.collectProfits(source, amount);
    }

    /// @inheritdoc IModuleRegistry
    function moduleLoss(address source, uint256 amount) external onlyRegisteredModule {
        zchf.coverLoss(source, amount);
    }
}
