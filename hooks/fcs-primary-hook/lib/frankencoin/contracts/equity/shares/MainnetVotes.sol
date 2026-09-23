// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../Governance.sol";
import {CCIPSender} from "../../bridge/CCIPSender.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {SyncVote, SyncMessage} from "../IGovernance.sol";

interface IFCSVotes {
    function votes(address holder) external view returns (uint256);
    function totalVotes() external view returns (uint256);
}

/**
 * Mainnet FCS vote registry and CCIP sender to sync votes and delegates to other chains.
 */
contract MainnetVotes is Governance, CCIPSender {

    IFCSVotes public immutable VOTES;

    address private constant LINK_TOKEN = 0x514910771AF9Ca656af840dff83E8264EcF986CA;

    event FCSVotesSynced(uint64 chain, address indexed receiver, address[] syncedVoters);

    constructor(
        address fcs_,
        IRouterClient router_
    ) CCIPSender(router_, LINK_TOKEN) {
        VOTES = IFCSVotes(fcs_);
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
     * @notice Sync FCS holder votes and delegations to a bridged chain.
     * @param chain     The CCIP chain selector of the destination chain
     * @param receiver  The BridgedFCSGovernance address on the destination chain
     * @param voters    The FCS holders whose votes to sync
     */
    function pushFCSVotes(uint64 chain, address receiver, address[] calldata voters) external payable {
        pushFCSVotes(chain, _toReceiver(receiver), voters, "");
    }

    function pushFCSVotes(uint64 chain, address receiver, address[] calldata voters, Client.EVMExtraArgsV2 calldata extraArgs) external payable {
        pushFCSVotes(chain, _toReceiver(receiver), voters, Client._argsToBytes(extraArgs));
    }

    function pushFCSVotes(uint64 chain, bytes memory receiver, address[] calldata voters, bytes memory extraArgs) public payable {
        SyncMessage memory syncMessage = _buildFCSSyncMessage(voters);
        Client.EVM2AnyMessage memory message = _constructMessage(receiver, abi.encode(syncMessage), new Client.EVMTokenAmount[](0), extraArgs);
        _send(chain, message);
        emit FCSVotesSynced(chain, abi.decode(receiver, (address)), voters);
    }

    function getFCSSyncFee(uint64 chain, address receiver, address[] calldata voters, bool useNativeToken) external view returns (uint256) {
        return getFCSSyncFee(chain, _toReceiver(receiver), voters, useNativeToken, "");
    }

    function getFCSSyncFee(uint64 chain, bytes memory receiver, address[] calldata voters, bool nativeToken, bytes memory extraArgs) public view returns (uint256) {
        SyncMessage memory syncMessage = _buildFCSSyncMessage(voters);
        Client.EVM2AnyMessage memory message = _constructMessage(receiver, abi.encode(syncMessage), new Client.EVMTokenAmount[](0), nativeToken, extraArgs);
        return _calculateFee(chain, message);
    }

    function _buildFCSSyncMessage(address[] calldata voters) private view returns (SyncMessage memory) {
        SyncVote[] memory syncVotes = new SyncVote[](voters.length);
        for (uint256 i = 0; i < voters.length; i++) {
            syncVotes[i] = SyncVote(voters[i], votes(voters[i]), delegates[voters[i]]);
        }
        return SyncMessage(syncVotes, totalVotes());
    }

}