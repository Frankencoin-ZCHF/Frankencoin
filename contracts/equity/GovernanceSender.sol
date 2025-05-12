// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {SyncVote, SyncMessage} from "./IGovernance.sol";
import {Governance} from "./Governance.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {IERC20} from "../erc20/IERC20.sol";
import {CCIPSender} from "../bridge/CCIPSender.sol";

contract GovernanceSender is CCIPSender {
    Governance public immutable GOVERNANCE;

    event VotesSynced(
        uint64 indexed chain, // The chain selector of the destination chain.
        bytes receiver,
        address[] syncedVoters
    );

    constructor(Governance _governance, IRouterClient _router, address _linkToken) CCIPSender(_router, _linkToken) {
        GOVERNANCE = _governance;
    }

    /// @notice Sync governance votes to destination
    /// @param chain The chain selector of the destination chain.
    /// @param receiver The address of the recipient on the destination chain.
    /// @param voters The voters to sync.
    function pushVotes(uint64 chain, address receiver, address[] calldata voters) external payable {
        pushVotes(chain, _toReceiver(receiver), voters, "");
    }

    /// @notice Sync governance votes to destination
    /// @param chain The chain selector of the destination chain.
    /// @param receiver The address of the recipient on the destination chain.
    /// @param voters The voters to sync.
    /// @param extraArgs Extra arguments for CCIP
    function pushVotes(uint64 chain, address receiver, address[] calldata voters, Client.EVMExtraArgsV2 calldata extraArgs) public payable {
        pushVotes(chain, _toReceiver(receiver), voters, Client._argsToBytes(extraArgs));
    }

    /// @notice Sync governance votes to destination paying with native token
    /// @dev extraArgs for CCIP can be provided such as gasLimit or out-of-order execution
    /// @param receiver Address of the recipient on the destination chain
    /// @param chain Chain selector of the destination chain
    /// @param voters Collection of addresses which votes and delegation should be synced
    /// @param extraArgs Extra arguments for CCIP
    function pushVotes(uint64 chain, bytes memory receiver, address[] calldata voters, bytes memory extraArgs) public payable {
        SyncMessage memory syncMessage = _buildSyncMessage(voters);
        Client.EVM2AnyMessage memory message = _constructMessage(receiver, abi.encode(syncMessage), new Client.EVMTokenAmount[](0), extraArgs);
        _send(chain, message);
        emit VotesSynced(chain, receiver, voters);
    }

    /// @notice Returns the fee required to send the sync message.
    /// @param chain The selector of the destination chain.
    /// @param receiver The address of the recipient on the destination chain.
    /// @param voters The voters to sync.
    /// @param useNativeToken Whether to use native token or LINK
    /// @return The fee required to send the sync message.
    function getCCIPFee(uint64 chain, address receiver, address[] calldata voters, bool useNativeToken) external view returns (uint256) {
        return getCCIPFee(chain, _toReceiver(receiver), voters, useNativeToken, "");
    }

    /// @notice Returns the fee required to send the sync message.
    /// @param chain The selector of the destination chain.
    /// @param receiver The address of the recipient on the destination chain.
    /// @param voters The voters to sync.
    /// @param useNativeToken Whether to use native token or LINK
    /// @param extraArgs Extra arguments for CCIP
    /// @return The fee required to send the sync message.
    function getCCIPFee(uint64 chain, address receiver, address[] calldata voters, bool useNativeToken, Client.EVMExtraArgsV2 calldata extraArgs) external view returns (uint256) {
        return getCCIPFee(chain, _toReceiver(receiver), voters, useNativeToken, Client._argsToBytes(extraArgs));
    }

    /// @notice Returns the fee required to send the sync message.
    /// @param chain The selector of the destination chain.
    /// @param receiver The address of the recipient on the destination chain.
    /// @param voters The voters to sync.
    /// @param nativeToken Whether to use native token or LINK
    /// @param extraArgs Extra arguments for CCIP
    /// @return The fee required to send the sync message.
    function getCCIPFee(uint64 chain, bytes memory receiver, address[] calldata voters, bool nativeToken, bytes memory extraArgs) public view returns (uint256) {
        SyncMessage memory syncMessage = _buildSyncMessage(voters);
        Client.EVM2AnyMessage memory message = _constructMessage(receiver, abi.encode(syncMessage), new Client.EVMTokenAmount[](0), nativeToken, extraArgs);
        return _calculateFee(chain, message);
    }

    /// @notice Returns the sync message.
    /// @param voters The voters to sync.
    /// @return The sync message.
    function _buildSyncMessage(address[] calldata voters) private view returns (SyncMessage memory) {
        SyncVote[] memory _pushVotes = new SyncVote[](voters.length);

        // omitted unchecked optimization for readability
        for (uint256 i = 0; i < voters.length; i++) {
            _pushVotes[i] = SyncVote(voters[i], GOVERNANCE.votes(voters[i]), GOVERNANCE.delegates(voters[i]));
        }

        return SyncMessage(_pushVotes, GOVERNANCE.totalVotes());
    }
}
