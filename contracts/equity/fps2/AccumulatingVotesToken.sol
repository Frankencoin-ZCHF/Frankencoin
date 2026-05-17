// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../../erc20/ERC20.sol";
import "../../utils/MathUtil.sol";

/**
 * This contract adds time- and balance-based vote accumulation to the basic ERC20 functionality.
 * Addresses that reach a cap can be cut down to the cap by anyone.
 * This code is mostly copied from Equity.sol .
 */
abstract contract AccumulatingVotesToken is ERC20, MathUtil {

    uint8 private constant TIME_RESOLUTION_BITS = 20;
    uint256 public constant HOLDING_DURATION_CAP = 365 days;

    // --- Vote tracking (same pattern as Equity) ---
    uint192 private totalVotesAtAnchor;
    uint64 private totalVotesAnchorTime;
    mapping(address owner => uint64 timestamp) private voteAnchor;

    event MutualDestruction(address indexed initiator, address indexed target, uint256 votesDestroyed);
    event VotesCapped(address indexed holder, uint256 votesBefore, uint256 votesAfter);

    // ==================== Vote Tracking ====================

    constructor() ERC20(18) {
    }

    /**
     * Caps the votes of a holder after one year.
     * This can help prevent infinite vote accumulation for lost addresses.
     */
    function cap(address holder) external {
        if (holdingDuration(holder) > HOLDING_DURATION_CAP) {
            uint256 votesBefore = votes(holder);
            voteAnchor[holder] = uint64(_anchorTime() - (HOLDING_DURATION_CAP << TIME_RESOLUTION_BITS));
            uint256 votesAfter = votes(holder);
            setTotalVotes(totalVotes() - (votesBefore - votesAfter));
            emit VotesCapped(holder, votesBefore, votesAfter);
        }
    }

    function setTotalVotes(uint256 amount) internal {
        totalVotesAtAnchor = uint192(amount);
        totalVotesAnchorTime = _anchorTime();
    }

    function _anchorTime() internal view returns (uint64) {
        return uint64(block.timestamp << TIME_RESOLUTION_BITS);
    }

    function votes(address holder) public view returns (uint256) {
        return balanceOf(holder) * (_anchorTime() - voteAnchor[holder]);
    }

    function totalVotes() public view returns (uint256) {
        return totalVotesAtAnchor + totalSupply() * (_anchorTime() - totalVotesAnchorTime);
    }

    function relativeVotes(address holder) external view returns (uint256) {
        return (ONE_DEC18 * votes(holder)) / totalVotes();
    }

    function holdingDuration(address holder) public view returns (uint256) {
        return (_anchorTime() - voteAnchor[holder]) >> TIME_RESOLUTION_BITS;
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual override {
        super._beforeTokenTransfer(from, to, amount);
        if (amount > 0) {
            uint256 roundingLoss = _adjustRecipientVoteAnchor(to, amount);
            _adjustTotalVotes(from, amount, roundingLoss);
        }
    }

    function _adjustTotalVotes(address from, uint256 amount, uint256 roundingLoss) internal {
        uint64 time = _anchorTime();
        uint256 lostVotes = from == address(0x0) ? 0 : (time - voteAnchor[from]) * amount;
        setTotalVotes(totalVotes() - roundingLoss - lostVotes);
    }

    function creditVotes(address holder, uint256 additionalVotes) internal {
        uint256 recipientVotesBefore = votes(holder);
        uint256 balance = balanceOf(holder);
        voteAnchor[holder] = uint64(_anchorTime() - (recipientVotesBefore + additionalVotes) / balance);
        uint256 recipientVotesAfter = votes(holder); // calculate again to account for rounding
        uint256 voteIncrease = recipientVotesAfter - recipientVotesBefore;
        setTotalVotes(totalVotes() + voteIncrease);
    }

    /**
     * Allows a holder to sacrifice their own votes to destroy the votes of targets.
     * The caller's votes are reduced first, then used as a budget to reduce targets' votes.
     * 
     * This function is previously called "kamikaze" in FPS1 / Equity.
     */
    function attack(address[] calldata targets, uint256 votesToDestroy) external {
        uint256 budget = _reduceVotes(msg.sender, votesToDestroy);
        uint256 destroyedVotes = 0;
        for (uint256 i = 0; i < targets.length && destroyedVotes < budget; i++) {
            destroyedVotes += _reduceVotes(targets[i], budget - destroyedVotes);
            emit MutualDestruction(msg.sender, targets[i], destroyedVotes);
        }
        require(destroyedVotes > 0);
        setTotalVotes(totalVotes() - destroyedVotes - budget);
    }

    function _reduceVotes(address target, uint256 amount) internal returns (uint256) {
        uint256 votesBefore = votes(target);
        if (amount >= votesBefore) {
            voteAnchor[target] = _anchorTime();
            return votesBefore;
        } else {
            voteAnchor[target] = uint64(_anchorTime() - (votesBefore - amount) / balanceOf(target));
            return votesBefore - votes(target);
        }
    }

    function _adjustRecipientVoteAnchor(address to, uint256 amount) internal returns (uint256) {
        if (to != address(0x0)) {
            uint256 recipientVotes = votes(to);
            uint256 newbalance = balanceOf(to) + amount;
            voteAnchor[to] = uint64(_anchorTime() - recipientVotes / newbalance);
            return recipientVotes % newbalance;
        } else {
            return 0;
        }
    }

}