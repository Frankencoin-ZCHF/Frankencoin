// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../Governance.sol";
import "../Equity.sol";

/**
 * @notice Governance contract for the FPS2 equity. It is used to check if an address has veto power.
 * Veto power is reached with 2% of the votes.
 */
abstract contract AccumulatingVotesToken is Governance, ERC20, MathUtil {

    uint8 private constant TIME_RESOLUTION_BITS = 20;
    uint256 public constant HOLDING_DURATION_CAP = 365 days;

    // --- Vote tracking (same pattern as Equity) ---
    uint192 private totalVotesAtAnchor;
    uint64 private totalVotesAnchorTime;
    mapping(address owner => uint64 timestamp) private voteAnchor;

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
            voteAnchor[holder] = uint64(_anchorTime() - HOLDING_DURATION_CAP);
            uint256 votesAfter = votes(holder);
            totalVotesAtAnchor = uint192(totalVotes() - (votesAfter - votesBefore));
            totalVotesAnchorTime = _anchorTime();
        }
    }

    function _anchorTime() internal view returns (uint64) {
        return uint64(block.timestamp << TIME_RESOLUTION_BITS);
    }

    function votes(address holder) public view override returns (uint256) {
        return balanceOf(holder) * (_anchorTime() - voteAnchor[holder]);
    }

    function totalVotes() public view override returns (uint256) {
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
        totalVotesAtAnchor = uint192(totalVotes() - roundingLoss - lostVotes);
        totalVotesAnchorTime = time;
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