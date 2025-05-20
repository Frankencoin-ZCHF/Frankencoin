// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {SyncVote, SyncMessage} from "./IGovernance.sol";
import {Governance} from "./Governance.sol";

contract BridgedGovernance is CCIPReceiver, Governance {
    uint64 public immutable MAINNET_CHAIN_SELECTOR;
    address public immutable MAINNET_GOVERNANCE_ADDRESS;

    mapping(address => uint256) private _votes;
    uint256 private _totalVotes;

    event MessageReceived(bytes32 messageId, uint64 sourceChain, uint256 totalVotes, SyncVote[] syncedVotes);

    error InvalidSourceChain();
    error InvalidSender();

    constructor(address router, uint64 mainnetChainSelector, address mainnetGovernanceAddress) CCIPReceiver(router) {
        MAINNET_CHAIN_SELECTOR = mainnetChainSelector;
        MAINNET_GOVERNANCE_ADDRESS = mainnetGovernanceAddress;
    }

    /// @notice Get the number of votes held by a holder.
    /// @param holder The address to check.
    function votes(address holder) public view override returns (uint256) {
        return _votes[holder];
    }

    /// @notice Get the total number of votes.
    function totalVotes() public view override returns (uint256) {
        return _totalVotes;
    }

    /// @notice Process a sync message.
    /// @param any2EvmMessage The message to process.
    function _ccipReceive(Client.Any2EVMMessage memory any2EvmMessage) internal override {
        if (any2EvmMessage.sourceChainSelector != MAINNET_CHAIN_SELECTOR) revert InvalidSourceChain();
        if (abi.decode(any2EvmMessage.sender, (address)) != MAINNET_GOVERNANCE_ADDRESS) revert InvalidSender();

        SyncMessage memory syncMessage = abi.decode(any2EvmMessage.data, (SyncMessage)); // abi-decoding of the sent text

        _processSyncMessage(syncMessage);

        emit MessageReceived(any2EvmMessage.messageId, any2EvmMessage.sourceChainSelector, syncMessage.totalVotes, syncMessage.votes);
    }

    /// @notice Updates internal state with received message
    /// @param syncMessage The message to process.
    function _processSyncMessage(SyncMessage memory syncMessage) internal {
        _totalVotes = syncMessage.totalVotes;

        // omitted unchecked optimization for readability
        for (uint64 i = 0; i < syncMessage.votes.length; i++) {
            SyncVote memory syncVote = syncMessage.votes[i];
            _votes[syncVote.voter] = syncVote.votes;
            delegate(syncVote.voter, syncVote.delegatee);
        }
    }
}
