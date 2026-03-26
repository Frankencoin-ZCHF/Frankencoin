// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./CCIPGovernance.sol";
import "./FPS2.sol";
import {CCIPSender} from "../../bridge/CCIPSender.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {SyncVote, SyncMessage} from "../IGovernance.sol";

/**
 * @notice Mainnet-only FPS2 governance. Adds leadrate proposals and CCIP vote syncing
 * to push FPS2 holder votes to bridged chains.
 */
contract MainnetGovernance is CCIPGovernance, CCIPSender {

    ILeadrateProposal public immutable BORROWING_LEADRATE;
    ILeadrateProposal public immutable SAVINGS_LEADRATE;

    event FPS2VotesSynced(uint64 indexed chain, address receiver, address[] syncedVoters);

    constructor(
        FPS2 fps2_,
        IFrankencoin zchf_,
        ICCIPAdmin ccipAdmin_,
        ILeadrateProposal borrowingLeadrate_,
        ILeadrateProposal savingsLeadrate_,
        IRouterClient router_,
        address linkToken_
    ) CCIPGovernance(address(fps2_), zchf_, ccipAdmin_) CCIPSender(router_, linkToken_) {
        BORROWING_LEADRATE = borrowingLeadrate_;
        SAVINGS_LEADRATE = savingsLeadrate_;
    }

    /**
     * @notice The votes of the holder, excluding votes from delegates.
     */
    function votes(address holder) public override view returns (uint256){
        return FPS2(address(FPS2)).votes(holder);
    }

    /**
     * @notice Total number of votes in the system.
     */
    function totalVotes() public override view returns (uint256) {
        return FPS2(address(FPS2)).totalVotes();
    }

    // ==================== Position governance ====================

    /**
     * @notice Deny a v1 or v2 minting position on behalf of qualified FPS2 holders.
     * @param position  The position contract to deny
     * @param helpers   FPS2 holders who delegate their votes to the caller
     * @param message   Reason for the denial
     */
    function denyPosition(address position, address[] calldata helpers, string calldata message) external {
        checkQualified(msg.sender, helpers);
        IPosition(position).deny(fps2AsHelper(), message);
    }

    // ==================== Leadrate proposals (mainnet only) ====================

    /**
     * @notice Propose a borrowing rate change on behalf of qualified FPS2 holders.
     * @param newRatePPM    The proposed new rate in parts per million
     * @param helpers       FPS2 holders who delegate their votes to the caller
     */
    function proposeBorrowingRate(uint24 newRatePPM, address[] calldata helpers) external {
        checkQualified(msg.sender, helpers);
        BORROWING_LEADRATE.proposeChange(newRatePPM, fps2AsHelper());
    }

    /**
     * @notice Propose a savings rate change on behalf of qualified FPS2 holders.
     * @param newRatePPM    The proposed new rate in parts per million
     * @param helpers       FPS2 holders who delegate their votes to the caller
     */
    function proposeSavingsRate(uint24 newRatePPM, address[] calldata helpers) external {
        checkQualified(msg.sender, helpers);
        SAVINGS_LEADRATE.proposeChange(newRatePPM, fps2AsHelper());
    }

    // ==================== FPS2 vote syncing ====================

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
            syncVotes[i] = SyncVote(voters[i], VOTES.votes(voters[i]), VOTES.delegates(voters[i]));
        }
        return SyncMessage(syncVotes, VOTES.totalVotes());
    }

}

interface ILeadrateProposal {
    function proposeChange(uint24 newRatePPM_, address[] calldata helpers) external;
}
