// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../Governance.sol";
import {CCIPSender} from "../../bridge/CCIPSender.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {SyncVote, SyncMessage} from "../IGovernance.sol";

interface IFPS2Votes {
    function votes(address holder) external view returns (uint256);
    function totalVotes() external view returns (uint256);
}

/**
 * Mainnet FPS2 vote registry and CCIP sender to sync votes and delegates to other chains.
 */
contract MainnetVotes is Governance, CCIPSender {

    IFPS2Votes public immutable VOTES;

    address private constant LINK_TOKEN = 0x514910771AF9Ca656af840dff83E8264EcF986CA;

    event FPS2VotesSynced(uint64 chain, address indexed receiver, address[] syncedVoters);

    constructor(
        address fps2_,
        IRouterClient router_
    ) CCIPSender(router_, LINK_TOKEN) {
        VOTES = IFPS2Votes(fps2_);
    }

    /**
     * @notice The votes of the holder, excluding votes from delegates.
     */
    function votes(address holder) public override view returns (uint256){
        return VOTES.votes(holder);
    }

    /**
     * @notice Total number of votes in the system.
     */
    function totalVotes() public override view returns (uint256) {
        return VOTES.totalVotes();
    }

    /**
     * @notice Sync FPS2 holder votes and delegations to a bridged chain.
     * @param chain     The CCIP chain selector of the destination chain
     * @param receiver  The BridgedFPS2Governance address on the destination chain
     * @param voters    The FPS2 holders whose votes to sync
     */
    function pushFPS2Votes(uint64 chain, address receiver, address[] calldata voters) external payable {
        pushFPS2Votes(chain, _toReceiver(receiver), voters, "");
    }

    function pushFPS2Votes(uint64 chain, address receiver, address[] calldata voters, Client.EVMExtraArgsV2 calldata extraArgs) external payable {
        pushFPS2Votes(chain, _toReceiver(receiver), voters, Client._argsToBytes(extraArgs));
    }

    function pushFPS2Votes(uint64 chain, bytes memory receiver, address[] calldata voters, bytes memory extraArgs) public payable {
        SyncMessage memory syncMessage = _buildFPS2SyncMessage(voters);
        Client.EVM2AnyMessage memory message = _constructMessage(receiver, abi.encode(syncMessage), new Client.EVMTokenAmount[](0), extraArgs);
        _send(chain, message);
        emit FPS2VotesSynced(chain, abi.decode(receiver, (address)), voters);
    }

    function getFPS2SyncFee(uint64 chain, address receiver, address[] calldata voters, bool useNativeToken) external view returns (uint256) {
        return getFPS2SyncFee(chain, _toReceiver(receiver), voters, useNativeToken, "");
    }

    function getFPS2SyncFee(uint64 chain, bytes memory receiver, address[] calldata voters, bool nativeToken, bytes memory extraArgs) public view returns (uint256) {
        SyncMessage memory syncMessage = _buildFPS2SyncMessage(voters);
        Client.EVM2AnyMessage memory message = _constructMessage(receiver, abi.encode(syncMessage), new Client.EVMTokenAmount[](0), nativeToken, extraArgs);
        return _calculateFee(chain, message);
    }

    function _buildFPS2SyncMessage(address[] calldata voters) private view returns (SyncMessage memory) {
        SyncVote[] memory syncVotes = new SyncVote[](voters.length);
        for (uint256 i = 0; i < voters.length; i++) {
            syncVotes[i] = SyncVote(voters[i], votes(voters[i]), delegates[voters[i]]);
        }
        return SyncMessage(syncVotes, totalVotes());
    }

}