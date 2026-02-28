// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./IGovernance.sol";
import "./Equity.sol";
import "../stablecoin/Frankencoin.sol";
import "../utils/MathUtil.sol";
import "../erc20/ERC20PermitLight.sol";

/**
 * @title FPS2
 * @notice A wrapper token around the Frankencoin Pool Share (FPS) that removes the 90-day
 * redemption lock in favor of a spread-based pricing mechanism. It comes with its own
 * governance system with a 1% veto quorum and a minter pre-announcement system that
 * effectively extends the veto period for new minting modules to 3 months.
 *
 * Investment price is unaltered (same as investing directly in FPS). Selling incurs a spread
 * that increases with the amount sold. The capacity (10% of total FPS supply) linearly recovers
 * over 30 days.
 */
contract FPS2 is ERC20PermitLight, MathUtil, IGovernance {

    uint8 private constant TIME_RESOLUTION_BITS = 20;

    /**
     * @notice Selling 10% of all outstanding FPS would send the redemption price for subsequent
     * redemptions to 0.
     */
    uint256 public constant CAPACITY_DIVISOR = 10;

    /**
     * @notice The period over which used capacity linearly recovers to zero.
     */
    uint256 public constant RECOVERY_PERIOD = 30 days;

    /**
     * @notice Minters must be announced at least this long before FPS2 will refrain from
     * vetoing them.
     */
    uint256 public constant MIN_APPLICATION_PERIOD = 90 days;

    Equity public immutable fps;
    Frankencoin public immutable zchf;

    // --- Vote tracking (same pattern as Equity) ---
    uint192 private totalVotesAtAnchor;
    uint64 private totalVotesAnchorTime;
    mapping(address owner => uint64 timestamp) private voteAnchor;

    // --- Delegation ---
    mapping(address owner => address delegate) public delegates;

    // --- Spread mechanism ---
    uint256 public usedCapacity;
    uint256 public lastCapacityUpdate;

    // --- Minter announcements ---
    mapping(address minter => uint256 timestamp) public announcements;

    event Trade(address who, int amount, uint totPrice, uint newprice);
    event MinterAnnounced(address indexed minter, uint256 timestamp);
    event MinterVetoed(address indexed minter, string message);
    event Delegation(address indexed from, address indexed to);

    error NotQualified();
    error VetoBlocked();
    error CapacityExceeded();
    error PeriodTooShort();

    constructor(Frankencoin zchf_) ERC20(18) {
        zchf = zchf_;
        fps = Equity(address(zchf_.reserve()));
    }

    function name() external pure override returns (string memory) {
        return "Frankencoin Pool Share 2";
    }

    function symbol() external pure override returns (string memory) {
        return "FPS2";
    }

    // ==================== Investment ====================

    /**
     * @notice Invest ZCHF to receive FPS2 tokens. The caller must have approved this contract
     * to spend their ZCHF. The investment goes through Equity.invest at the unaltered price.
     * @param amount          ZCHF to invest
     * @param expectedShares  Minimum FPS2 shares expected (slippage protection)
     * @return The number of FPS2 shares minted
     */
    function invest(uint256 amount, uint256 expectedShares) external returns (uint256) {
        zchf.transferFrom(msg.sender, address(this), amount);
        uint256 fpsBefore = fps.balanceOf(address(this));
        fps.invest(amount, 0);
        uint256 fpsReceived = fps.balanceOf(address(this)) - fpsBefore;
        require(fpsReceived >= expectedShares, "slippage");
        _mint(msg.sender, fpsReceived);
        emit Trade(msg.sender, int(fpsReceived), amount, price());
        return fpsReceived;
    }

    // ==================== Pricing ====================

    /**
     * @notice The price of one FPS2 in ZCHF, equal to the underlying FPS price.
     */
    function price() public view returns (uint256) {
        return fps.price();
    }

    // ==================== Spread & Capacity ====================

    /**
     * @notice The maximum amount of FPS that can be redeemed before the price hits zero.
     * Equal to 10% of total outstanding FPS.
     */
    function capacity() public view returns (uint256) {
        return fps.totalSupply() / CAPACITY_DIVISOR;
    }

    /**
     * @notice The current used capacity, taking into account linear recovery over 30 days.
     */
    function currentUsedCapacity() public view returns (uint256) {
        uint256 elapsed = block.timestamp - lastCapacityUpdate;
        if (elapsed >= RECOVERY_PERIOD) {
            return 0;
        }
        return usedCapacity * (RECOVERY_PERIOD - elapsed) / RECOVERY_PERIOD;
    }

    /**
     * @notice How much capacity is still available for selling.
     */
    function availableCapacity() external view returns (uint256) {
        uint256 cap = capacity();
        uint256 currentUsed = currentUsedCapacity();
        if (currentUsed >= cap) return 0;
        return cap - currentUsed;
    }

    /**
     * @notice Preview the effective proceeds after spread for selling the given number of shares.
     */
    function calculateEffectiveProceeds(uint256 shares) external view returns (uint256) {
        uint256 underlyingProceeds = fps.calculateProceeds(shares);
        uint256 cap = capacity();
        uint256 currentUsed = currentUsedCapacity();
        if (currentUsed + shares > cap) return 0;
        return underlyingProceeds * (2 * cap - 2 * currentUsed - shares) / (2 * cap);
    }

    // ==================== Redemption ====================

    /**
     * @notice Redeem FPS2 for ZCHF. A spread is applied that increases with the amount sold
     * relative to total FPS supply. The spread is sent back to the Equity contract.
     * @param target  Address to receive the ZCHF proceeds
     * @param shares  Number of FPS2 shares to redeem
     * @return The effective ZCHF proceeds sent to target
     */
    function redeem(address target, uint256 shares) public returns (uint256) {
        uint256 cap = capacity();
        uint256 currentUsed = currentUsedCapacity();
        if (currentUsed + shares > cap) revert CapacityExceeded();

        // Update capacity tracking (checks-effects-interactions)
        usedCapacity = currentUsed + shares;
        lastCapacityUpdate = block.timestamp;

        // Burn FPS2 from sender
        _burn(msg.sender, shares);

        // Redeem underlying FPS from Equity -> ZCHF to this contract
        uint256 actualProceeds = fps.redeem(address(this), shares);

        // Apply spread: average multiplier = (2*cap - 2*currentUsed - shares) / (2*cap)
        uint256 effectiveProceeds = actualProceeds * (2 * cap - 2 * currentUsed - shares) / (2 * cap);
        uint256 spread = actualProceeds - effectiveProceeds;

        // Send effective proceeds to target, return spread to Equity
        zchf.transfer(target, effectiveProceeds);
        if (spread > 0) {
            zchf.transfer(address(fps), spread);
        }

        emit Trade(msg.sender, -int(shares), effectiveProceeds, price());
        return effectiveProceeds;
    }

    /**
     * @notice Like redeem, but with an extra parameter to protect against frontrunning.
     * @param expectedProceeds  The minimum acceptable effective proceeds
     */
    function redeemExpected(address target, uint256 shares, uint256 expectedProceeds) external returns (uint256) {
        uint256 proceeds = redeem(target, shares);
        require(proceeds >= expectedProceeds);
        return proceeds;
    }

    // ==================== Vote Tracking ====================

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

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
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

    // ==================== Delegation & Governance ====================

    function delegateVoteTo(address delegate_) external {
        delegates[msg.sender] = delegate_;
        emit Delegation(msg.sender, delegate_);
    }

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

    /**
     * @notice Check whether the sender has at least 1% of the total FPS2 votes.
     */
    function checkQualified(address sender, address[] calldata helpers) external view override {
        uint256 _votes = votesDelegated(sender, helpers);
        // Need 1% of the votes to reach for veto power.
        if (_votes * 100 < totalVotes()) revert NotQualified();
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

    // ==================== Minter Suggestion & Veto ====================

    /**
     * @notice Publicly accessible method to suggest a new way of minting Frankencoin.
     * 
     * Wraps the existing functionality in Frankencoin to enforce a 90 days period.
     */
    function suggestMinter(address _minter, uint256 _applicationPeriod, uint256 _applicationFee, string calldata _message) external override {
        if (_applicationPeriod < MIN_APPLICATION_PERIOD) revert PeriodTooShort();
        zchf.transferFrom(msg.sender, address(this), _applicationFee);
        announcements[_minter] = block.timestamp;
        emit MinterPreAnnounced(_minter, block.timestamp);
    }

    function denyMinter(address minter) {
        if (announcements[minter] != 0) revert MinterCorrectlyAnnounced();
        zchf.denyMinter(minter, equityHelpers, "Minters must be suggested 90 days in advance through the FPS2 contract");
    }

}
