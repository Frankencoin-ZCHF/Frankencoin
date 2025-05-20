// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IGovernance {
   function checkQualified(address sender, address[] calldata helpers) external view;
}

struct SyncVote {
    address voter;
    uint256 votes;
    address delegatee;
}

struct SyncMessage {
    SyncVote[] votes;
    uint256 totalVotes;
}
