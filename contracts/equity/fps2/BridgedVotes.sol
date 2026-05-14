// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../Governance.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {SyncVote, SyncMessage} from "../IGovernance.sol";

/**
 * @notice Bridged-chain FPS2 governance. Receives FPS2 holder votes from mainnet via CCIP
 * and acts as the IGovernance oracle for FPS2-level qualification checks on the bridged chain.
 */
contract BridgedVotes is Governance, CCIPReceiver {

    uint64 public constant MAINNET_CHAIN_SELECTOR = 5009297550715157269;

    mapping(address => uint256) private _fps2Votes;
    uint256 private _fps2TotalVotes;

    event FPS2VotesReceived(bytes32 messageId, uint64 sourceChain, uint256 totalVotes, SyncVote[] syncedVotes);

    error InvalidSourceChain();
    error InvalidSender();

    constructor(
        address router_
    ) CCIPReceiver(router_) {
    }

    // ==================== Governance overrides (bridged FPS2 votes) ====================

    function votes(address holder) public view override returns (uint256) {
        return _fps2Votes[holder];
    }

    function totalVotes() public view override returns (uint256) {
        return _fps2TotalVotes;
    }

    // ==================== CCIP reception ====================

    function _ccipReceive(Client.Any2EVMMessage memory any2EvmMessage) internal override {
        if (any2EvmMessage.sourceChainSelector != MAINNET_CHAIN_SELECTOR) revert InvalidSourceChain();

        // Mainnet governance contract is the only valid sender and it should have the same address as this contract (deployed via factory), so we can just check if the sender is address(this)
        if (abi.decode(any2EvmMessage.sender, (address)) != address(this)) revert InvalidSender();

        SyncMessage memory syncMessage = abi.decode(any2EvmMessage.data, (SyncMessage));

        _fps2TotalVotes = syncMessage.totalVotes;
        for (uint64 i = 0; i < syncMessage.votes.length; i++) {
            SyncVote memory syncVote = syncMessage.votes[i];
            _fps2Votes[syncVote.voter] = syncVote.votes;
            delegate(syncVote.voter, syncVote.delegatee);
        }

        emit FPS2VotesReceived(any2EvmMessage.messageId, any2EvmMessage.sourceChainSelector, syncMessage.totalVotes, syncMessage.votes);
    }

}
