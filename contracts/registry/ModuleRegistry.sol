// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../stablecoin/IBasicFrankencoin.sol";
import "./IModuleRegistry.sol";
import "./IModule.sol";

contract ModuleRegistry is IModuleRegistry {
    uint256 public constant VETO_PERIOD = 30 days;
    uint96 public constant MIN_PROPOSAL_FEE = 1000 * 10 ** 18;

    IBasicFrankencoin public immutable zchf;

    mapping(address => uint256) public moduleExpiry;
    mapping(address => Proposal) public proposals;

    modifier proposal(address module, bool mustExist) {
        if ((proposals[module].activateAt != 0) != mustExist) {
            if (mustExist) revert NoProposal();
            else revert AlreadyProposed();
        }
        _;
    }

    modifier onlyRegisteredModule() {
        if (!isActive(msg.sender)) revert NotActive();
        _;
    }

    constructor(IBasicFrankencoin zchf_) {
        zchf = zchf_;
    }

    function isActive(address module) public view override returns (bool) {
        return moduleExpiry[module] > block.timestamp;
    }

    /**
     * @notice Propose a new module, an extension, or an early retirement.
     * @dev Category is inferred from expiration vs current moduleExpiry:
     *   - New/re-proposal: moduleExpiry == 0 or expired
     *   - Extension:       expiration > moduleExpiry
     *   - Retirement:      expiration < moduleExpiry; overridden to now + VETO_PERIOD for a
     *                      predictable 30-day transition window
     */
    function propose(address module, uint96 fee, uint64 expiration, string calldata message) external proposal(module, false) {
        if (fee < MIN_PROPOSAL_FEE) revert FeeTooLow();
        uint64 activateAt = uint64(block.timestamp + VETO_PERIOD);
        uint64 currentExpiry = uint64(moduleExpiry[module]);
        ProposalCategory category;

        if (currentExpiry == 0 || block.timestamp >= currentExpiry) {
            if (expiration <= activateAt) revert InvalidExpiration();
            category = ProposalCategory.New;
        } else if (expiration > currentExpiry) {
            category = ProposalCategory.Extension;
        } else {
            expiration = activateAt;
            if (expiration >= currentExpiry) revert InvalidExpiration();
            category = ProposalCategory.Retirement;
        }

        zchf.transferFrom(msg.sender, address(this), fee);
        proposals[module] = Proposal(msg.sender, fee, expiration, activateAt);
        emit ModuleProposed(module, msg.sender, category, expiration, activateAt, message);
    }

    /**
     * @notice Qualified FPS holders can revoke a proposal during the veto window.
     *         The deposit is forwarded to the reserve as profit.
     */
    function revoke(address module, address[] calldata helpers, string calldata message) external proposal(module, true) {
        if (block.timestamp >= proposals[module].activateAt) revert VetoPeriodOver();
        zchf.reserve().checkQualified(msg.sender, helpers);
        uint96 fee = proposals[module].fee;
        delete proposals[module];
        zchf.collectProfits(address(this), fee);
        emit ModuleRevoked(module, message);
    }

    /**
     * @notice Accept a proposal after the veto window has closed.
     *         Applies the new expiration and refunds the deposit to the proposer.
     */
    function accept(address module) external proposal(module, true) {
        if (block.timestamp < proposals[module].activateAt) revert VetoPeriodActive();
        Proposal memory p = proposals[module];
        delete proposals[module];
        moduleExpiry[module] = p.expiration;
        zchf.transfer(p.proposer, p.fee);
        emit ModuleAccepted(module, p.expiration);
    }

    function moduleMint(address target, uint256 amount) external onlyRegisteredModule {
        zchf.mint(target, amount);
    }

    function moduleBurn(address owner, uint256 amount) external onlyRegisteredModule {
        zchf.burnFrom(owner, amount);
    }
}
