// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IModuleRegistry {
    enum ProposalCategory { New, Extension, Retirement }

    /**
     * @dev Slot 1: proposer (20 bytes) + fee (12 bytes) = 32 bytes
     *      Slot 2: expiration (8 bytes) + activateAt (8 bytes)
     */
    struct Proposal {
        address proposer;
        uint96  fee;
        uint64  expiration;
        uint64  activateAt;
    }

    event ModuleProposed(address indexed module, address indexed proposer, ProposalCategory category, uint64 expiration, uint64 activateAt, string message);
    event ModuleRevoked(address indexed module, string message);
    event ModuleAccepted(address indexed module, uint64 expiration);

    error AlreadyProposed();
    error NoProposal();
    error VetoPeriodOver();
    error VetoPeriodActive();
    error InvalidExpiration();
    error FeeTooLow();
    error NotActive();

    function propose(address module, uint96 fee, uint64 expiration, string calldata message) external;
    function revoke(address module, address[] calldata helpers, string calldata message) external;
    function accept(address module) external;
    function moduleMint(address target, uint256 amount) external;
    function moduleBurn(address owner, uint256 amount) external;
    function isActive(address module) external view returns (bool);
}
