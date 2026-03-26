// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./CCIPGovernance.sol";
import "../Governance.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {SyncVote, SyncMessage} from "../IGovernance.sol";

/**
 * @notice Bridged-chain FPS2 governance. Receives FPS2 holder votes from mainnet via CCIP
 * and acts as the IGovernance oracle for FPS2-level qualification checks on the bridged chain.
 *
 * This contract serves a dual role:
 * 1. It extends CCIPGovernance, providing minter suggestion/veto and CCIP admin governance.
 * 2. It extends Governance, storing received FPS2 votes and delegations so that
 *    checkQualified works locally based on bridged data.
 *
 * The FPS2 reference in MinterGovernance points to address(this), so all checkQualified
 * calls resolve to the bridged vote data stored here.
 *
 * For this contract to exercise governance on the bridged Frankencoin, someone must sync
 * the FPS1 voting power of the FPS2 contract (on mainnet) to the BridgedGovernance on
 * this chain, including the delegation to this contract's address. Since this contract
 * should be deployed at the same address as the MainnetFPS2Governance (via a factory),
 * the synced delegation is automatically valid.
 */
contract BridgedGovernance is CCIPGovernance, CCIPReceiver {

    uint64 public immutable MAINNET_CHAIN_SELECTOR;
    address public immutable MAINNET_SENDER;

    mapping(address => uint256) private _fps2Votes;
    uint256 private _fps2TotalVotes;

    event FPS2VotesReceived(bytes32 messageId, uint64 sourceChain, uint256 totalVotes, SyncVote[] syncedVotes);

    error InvalidSourceChain();
    error InvalidSender();

    constructor(
        address mainnetFPS2_,
        IFrankencoin zchf_,
        ICCIPAdmin ccipAdmin_,
        address router_,
        uint64 mainnetChainSelector_,
        address mainnetSender_
    ) CCIPGovernance(
        mainnetFPS2_,
        zchf_,
        ccipAdmin_
    ) CCIPReceiver(router_) {
        MAINNET_CHAIN_SELECTOR = mainnetChainSelector_;
        MAINNET_SENDER = mainnetSender_;
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
        if (abi.decode(any2EvmMessage.sender, (address)) != MAINNET_SENDER) revert InvalidSender();

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
