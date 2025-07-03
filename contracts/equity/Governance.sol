// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./IGovernance.sol";

/**
 * Contract to consult when checking if someone has veto power.
 * Veto power is reached with 2% of the votes.
 */
abstract contract Governance is IGovernance {

    /**
     * @notice The quorum in basis points. 100 is 1%.
     */
    uint32 private constant QUORUM = 200;

    /**
     * @notice Keeping track on who delegated votes to whom.
     * Note that delegation does not mean you cannot vote / veto any more, it just means that the delegate can
     * benefit from your votes when invoking a veto. Circular delegations are valid, do not help when voting.
     */
    mapping(address owner => address delegate) public delegates;

    event Delegation(address indexed from, address indexed to); // indicates a delegation

    /**
     * @notice The votes of the holder, excluding votes from delegates.
     */
    function votes(address holder) virtual public view returns (uint256);

    /**
     * @notice Total number of votes in the system.
     */
    function totalVotes() virtual public view returns (uint256);

    /**
     * @notice The number of votes the sender commands when taking the support of the helpers into account.
     * @param sender    The address whose total voting power is of interest
     * @param helpers   An incrementally sorted list of helpers without duplicates and without the sender.
     *                  The call fails if the list contains an address that does not delegate to sender.
     *                  For indirect delegates, i.e. a -> b -> c, both a and b must be included for both to count.
     * @return          The total number of votes of sender at the current point in time.
     */
    function votesDelegated(address sender, address[] calldata helpers) public view returns (uint256) {
        uint256 _votes = votes(sender);
        require(_checkDuplicatesAndSorted(helpers));
        for (uint i = 0; i < helpers.length; i++) {
            address current = helpers[i];
            require(current != sender);
            require(_canVoteFor(sender, current));
            _votes += votes(current);
        }
        return _votes;
    }

    function _checkDuplicatesAndSorted(address[] calldata helpers) internal pure returns (bool ok) {
        if (helpers.length <= 1) {
            return true;
        } else {
            address prevAddress = helpers[0];
            for (uint i = 1; i < helpers.length; i++) {
                if (helpers[i] <= prevAddress) {
                    return false;
                }
                prevAddress = helpers[i];
            }
            return true;
        }
    }

    /**
     * @notice Checks whether the sender address is qualified given a list of helpers that delegated their votes
     * directly or indirectly to the sender. It is the responsiblity of the caller to figure out whether
     * helps are necessary and to identify them by scanning the blockchain for Delegation events.
     */
    function checkQualified(address sender, address[] calldata helpers) public view override {
        uint256 _votes = votesDelegated(sender, helpers);
        if (_votes * 10000 < QUORUM * totalVotes()) revert NotQualified();
    }

    error NotQualified();

    /**
     * @notice Increases the voting power of the delegate by your number of votes without taking away any voting power
     * from the sender.
     */
    function delegateVoteTo(address delegate_) external {
        delegate(msg.sender, delegate_);
    }

    function delegate(address owner, address delegate_) internal {
        delegates[owner] = delegate_;
        emit Delegation(owner, delegate_);
    }

    function _canVoteFor(address delegate_, address owner) internal view returns (bool) {
        if (owner == delegate_) {
            return true;
        } else if (owner == address(0x0)) {
            return false;
        } else {
            return _canVoteFor(delegate_, delegates[owner]);
        }
    }

}