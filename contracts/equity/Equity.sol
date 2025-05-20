// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./Governance.sol";
import "../stablecoin/Frankencoin.sol";
import "../utils/MathUtil.sol";
import "../erc20/IERC677Receiver.sol";

/**
 * @title Equity
 * @notice If the Frankencoin system was a bank, this contract would represent the equity on its balance sheet.
 * Like with a corporation, the owners of the equity capital are the shareholders, or in this case the holders
 * of Frankencoin Pool Shares (FPS) tokens. Anyone can mint additional FPS tokens by adding Frankencoins to the
 * reserve pool. Also, FPS tokens can be redeemed for Frankencoins again after a minimum holding period.
 * Furthermore, the FPS shares come with some voting power. Anyone that held at least 3% of the holding-period-
 * weighted reserve pool shares gains veto power and can veto new proposals.
 */
contract Equity is Governance, ERC20PermitLight, MathUtil {
    /**
     * The VALUATION_FACTOR determines the market cap of the reserve pool shares relative to the equity reserves.
     * The following always holds: Market Cap = Valuation Factor * Equity Reserve = Price * Supply
     *
     * In the absence of profits and losses, the variables grow as follows when FPS tokens are minted:
     *
     * |   Reserve     |   Market Cap  |     Price     |     Supply   |
     * |          1000 |          3000 |             3 |         1000 |
     * |       1000000 |       3000000 |           300 |        10000 |
     * |    1000000000 |    3000000000 |         30000 |       100000 |
     * | 1000000000000 | 3000000000000 |       3000000 |      1000000 |
     *
     * I.e., the supply is proporational to the cubic root of the reserve and the price is proportional to the
     * squared cubic root. When profits accumulate or losses materialize, the reserve, the market cap,
     * and the price are adjusted proportionally, with the supply staying constant. In the absence of an extreme
     * inflation of the Swiss franc, it is unlikely that there will ever be more than ten million FPS.
     */
    uint32 public constant VALUATION_FACTOR = 3;

    uint256 private constant MINIMUM_EQUITY = 1000 * ONE_DEC18;

    /**
     * @notice The number of digits to store the average holding time of share tokens.
     */
    uint8 private constant TIME_RESOLUTION_BITS = 20;

    /**
     * @notice The minimum holding duration. You are not allowed to redeem your pool shares if you held them
     * for less than the minimum holding duration at average. For example, if you have two pool shares on your
     * address, one acquired 5 days ago and one acquired 105 days ago, you cannot redeem them as the average
     * holding duration of your shares is only 55 days < 90 days.
     */
    uint256 public constant MIN_HOLDING_DURATION = 90 days << TIME_RESOLUTION_BITS; // Set to 5 for local testing

    Frankencoin public immutable zchf;

    /**
     * @dev To track the total number of votes we need to know the number of votes at the anchor time and when the
     * anchor time was. This is (hopefully) stored in one 256 bit slot, with the anchor time taking 64 Bits and
     * the total vote count 192 Bits. Given the sub-second resolution of 20 Bits, the implicit assumption is
     * that the timestamp can always be stored in 44 Bits (i.e. it does not exceed half a million years). Further,
     * given 18 decimals (about 60 Bits), this implies that the total supply cannot exceed
     *   192 - 60 - 44 - 20 = 68 Bits
     * Here, we are also save, as 68 Bits would imply more than a trillion outstanding shares. In fact,
     * a limit of about 2**36 shares (that's about 2**96 Bits when taking into account the decimals) is imposed
     * when minting. This means that the maximum supply is billions shares, which is could only be reached in
     * a scenario with hyper inflation, in which case the stablecoin is worthless anyway.
     */
    uint192 private totalVotesAtAnchor; // Total number of votes at the anchor time, see comment on the um
    uint64 private totalVotesAnchorTime; // 44 Bit for the time stamp, 20 Bit sub-second time resolution

    /**
     * @notice A time stamp in the past such that: votes = balance * (time passed since anchor was set)
     */
    mapping(address owner => uint64 timestamp) private voteAnchor; // 44 bits for time stamp, 20 subsecond resolution

    event Trade(address who, int amount, uint totPrice, uint newprice); // amount pos or neg for mint or redemption

    constructor(Frankencoin zchf_) ERC20(18) {
        zchf = zchf_;
    }

    function name() external pure override returns (string memory) {
        return "Frankencoin Pool Share";
    }

    function symbol() external pure override returns (string memory) {
        return "FPS";
    }

    /**
     * @notice Returns the price of one FPS in ZCHF with 18 decimals precision.
     */
    function price() public view returns (uint256) {
        uint256 equity = zchf.equity();
        if (equity == 0 || totalSupply() == 0) {
            return ONE_DEC18; // initial price is 1000 ZCHF for the first 1000 FPS
        } else {
            return (VALUATION_FACTOR * zchf.equity() * ONE_DEC18) / totalSupply();
        }
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        super._beforeTokenTransfer(from, to, amount);
        if (amount > 0) {
            // No need to adjust the sender votes. When they send out 10% of their shares, they also lose 10% of
            // their votes so everything falls nicely into place. Recipient votes should stay the same, but grow
            // faster in the future, requiring an adjustment of the anchor.
            uint256 roundingLoss = _adjustRecipientVoteAnchor(to, amount);
            // The total also must be adjusted and kept accurate by taking into account the rounding error.
            _adjustTotalVotes(from, amount, roundingLoss);
        }
    }

    /**
     * @notice Returns whether the given address is allowed to redeem FPS, which is the
     * case after their average holding duration is larger than the required minimum.
     */
    function canRedeem(address owner) public view returns (bool) {
        return _anchorTime() - voteAnchor[owner] >= MIN_HOLDING_DURATION;
    }

    /**
     * @notice Decrease the total votes anchor when tokens lose their voting power due to being moved
     * @param from      sender
     * @param amount    amount to be sent
     */
    function _adjustTotalVotes(address from, uint256 amount, uint256 roundingLoss) internal {
        uint64 time = _anchorTime();
        uint256 lostVotes = from == address(0x0) ? 0 : (time - voteAnchor[from]) * amount;
        totalVotesAtAnchor = uint192(totalVotes() - roundingLoss - lostVotes);
        totalVotesAnchorTime = time;
    }

    /**
     * @notice the vote anchor of the recipient is moved forward such that the number of calculated
     * votes does not change despite the higher balance.
     * @param to        receiver address
     * @param amount    amount to be received
     * @return the number of votes lost due to rounding errors
     */
    function _adjustRecipientVoteAnchor(address to, uint256 amount) internal returns (uint256) {
        if (to != address(0x0)) {
            uint256 recipientVotes = votes(to); // for example 21 if 7 shares were held for 3 seconds
            uint256 newbalance = balanceOf(to) + amount; // for example 11 if 4 shares are added
            // new example anchor is only 21 / 11 = 1 second in the past
            voteAnchor[to] = uint64(_anchorTime() - recipientVotes / newbalance);
            return recipientVotes % newbalance; // we have lost 21 % 11 = 10 votes
        } else {
            // optimization for burn, vote anchor of null address does not matter
            return 0;
        }
    }

    /**
     * @notice Time stamp with some additional bits for higher resolution.
     */
    function _anchorTime() internal view returns (uint64) {
        return uint64(block.timestamp << TIME_RESOLUTION_BITS);
    }

    /**
     * @notice The relative voting power of the address.
     * @return A percentage with 1e18 being 100%
     */
    function relativeVotes(address holder) external view returns (uint256) {
        return (ONE_DEC18 * votes(holder)) / totalVotes();
    }

    /**
     * @notice The votes of the holder, excluding votes from delegates.
     */
    function votes(address holder) public override view returns (uint256) {
        return balanceOf(holder) * (_anchorTime() - voteAnchor[holder]);
    }

    /**
     * @notice How long the holder already held onto their average FPS in seconds.
     */
    function holdingDuration(address holder) public view returns (uint256) {
        return (_anchorTime() - voteAnchor[holder]) >> TIME_RESOLUTION_BITS;
    }

    /**
     * @notice Total number of votes in the system.
     */
    function totalVotes() public override view returns (uint256) {
        return totalVotesAtAnchor + totalSupply() * (_anchorTime() - totalVotesAnchorTime);
    }

    /**
     * @notice Since quorum is rather low, it is important to have a way to prevent malicious minority holders
     * from blocking the whole system. This method provides a way for the good guys to team up and destroy
     * the bad guy's votes (at the cost of also reducing their own votes). This mechanism potentially
     * gives full control over the system to whoever has 51% of the votes.
     *
     * Since this is a rather aggressive measure, delegation is not supported. Every holder must call this
     * method on their own.
     * @param targets   The target addresses to remove votes from
     * @param votesToDestroy    The maximum number of votes the caller is willing to sacrifice
     */
    function kamikaze(address[] calldata targets, uint256 votesToDestroy) external {
        uint256 budget = _reduceVotes(msg.sender, votesToDestroy);
        uint256 destroyedVotes = 0;
        for (uint256 i = 0; i < targets.length && destroyedVotes < budget; i++) {
            destroyedVotes += _reduceVotes(targets[i], budget - destroyedVotes);
        }
        require(destroyedVotes > 0); // sanity check
        totalVotesAtAnchor = uint192(totalVotes() - destroyedVotes - budget);
        totalVotesAnchorTime = _anchorTime();
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

    /**
     * @notice Call this method to obtain newly minted pool shares in exchange for Frankencoins.
     * No allowance required (i.e. it is hardcoded in the Frankencoin token contract).
     * Make sure to invest at least 10e-12 * market cap to avoid rounding losses.
     *
     * @dev If equity is close to zero or negative, you need to send enough ZCHF to bring equity back to 1000 ZCHF.
     *
     * @param amount            Frankencoins to invest
     * @param expectedShares    Minimum amount of expected shares for frontrunning protection
     */
    function invest(uint256 amount, uint256 expectedShares) external returns (uint256) {
        zchf.transferFrom(msg.sender, address(this), amount);
        uint256 equity = zchf.equity();
        require(equity >= MINIMUM_EQUITY, "insuf equity"); // ensures that the initial deposit is at least 1000 ZCHF

        uint256 shares = _calculateShares(equity <= amount ? 0 : equity - amount, amount);
        require(shares >= expectedShares);
        _mint(msg.sender, shares);
        emit Trade(msg.sender, int(shares), amount, price());

        // limit the total supply to a reasonable amount to guard against overflows with price and vote calculations
        // the 36 bits are 68 bits for magnitude and 60 bits for precision, as calculated in an above comment
        require(totalSupply() <= type(uint96).max, "total supply exceeded");
        return shares;
    }

    /**
     * @notice Calculate shares received when investing Frankencoins
     * @param investment    ZCHF to be invested
     * @return shares to be received in return
     */
    function calculateShares(uint256 investment) external view returns (uint256) {
        return _calculateShares(zchf.equity(), investment);
    }

    function _calculateShares(uint256 capitalBefore, uint256 investment) internal view returns (uint256) {
        uint256 totalShares = totalSupply();
        uint256 investmentExFees = (investment * 997) / 1000; // remove 0.3% fee
        // Assign 1000 FPS for the initial deposit, calculate the amount otherwise
        uint256 newTotalShares = capitalBefore < MINIMUM_EQUITY || totalShares == 0
            ? totalShares + 1000 * ONE_DEC18
            : _mulD18(totalShares, _cubicRoot(_divD18(capitalBefore + investmentExFees, capitalBefore)));
        return newTotalShares - totalShares;
    }

    /**
     * @notice Redeem the given amount of shares owned by the sender and transfer the proceeds to the target.
     * @return The amount of ZCHF transferred to the target
     */
    function redeem(address target, uint256 shares) external returns (uint256) {
        return _redeemFrom(msg.sender, target, shares);
    }

    /**
     * @notice Like redeem(...), but with an extra parameter to protect against frontrunning.
     * @param expectedProceeds  The minimum acceptable redemption proceeds.
     */
    function redeemExpected(address target, uint256 shares, uint256 expectedProceeds) external returns (uint256) {
        uint256 proceeds = _redeemFrom(msg.sender, target, shares);
        require(proceeds >= expectedProceeds);
        return proceeds;
    }

    /**
     * @notice Redeem FPS based on an allowance from the owner to the caller.
     * See also redeemExpected(...).
     */
    function redeemFrom(
        address owner,
        address target,
        uint256 shares,
        uint256 expectedProceeds
    ) external returns (uint256) {
        _useAllowance(owner, msg.sender, shares);
        uint256 proceeds = _redeemFrom(owner, target, shares);
        require(proceeds >= expectedProceeds);
        return proceeds;
    }

    function _redeemFrom(address owner, address target, uint256 shares) internal returns (uint256) {
        require(canRedeem(owner));
        uint256 proceeds = calculateProceeds(shares);
        _burn(owner, shares);
        zchf.transfer(target, proceeds);
        emit Trade(owner, -int(shares), proceeds, price());
        return proceeds;
    }

    /**
     * @notice Calculate ZCHF received when depositing shares
     * @param shares number of shares we want to exchange for ZCHF,
     *               in dec18 format
     * @return amount of ZCHF received for the shares
     */
    function calculateProceeds(uint256 shares) public view returns (uint256) {
        uint256 totalShares = totalSupply();
        require(shares + ONE_DEC18 < totalShares, "too many shares"); // make sure there is always at least one share
        uint256 capital = zchf.equity();
        uint256 reductionAfterFees = (shares * 997) / 1000;
        uint256 newCapital = _mulD18(capital, _power3(_divD18(totalShares - reductionAfterFees, totalShares)));
        return capital - newCapital;
    }

    /**
     * @notice If there is less than 1000 ZCHF in equity left (maybe even negative), the system is at risk
     * and we should allow qualified FPS holders to restructure the system.
     *
     * Example: there was a devastating loss and equity stands at -1'000'000. Most shareholders have lost hope in the
     * Frankencoin system except for a group of small FPS holders who still believes in it and is willing to provide
     * 2'000'000 ZCHF to save it. These brave souls are essentially donating 1'000'000 to the minter reserve and it
     * would be wrong to force them to share the other million with the passive FPS holders. Instead, they will get
     * the possibility to bootstrap the system again owning 100% of all FPS shares.
     *
     * @param helpers          A list of addresses that delegate to the caller in incremental order
     * @param addressesToWipe  A list of addresses whose FPS will be burned to zero
     */
    function restructureCapTable(address[] calldata helpers, address[] calldata addressesToWipe) external {
        require(zchf.equity() < MINIMUM_EQUITY);
        checkQualified(msg.sender, helpers);
        for (uint256 i = 0; i < addressesToWipe.length; i++) {
            address current = addressesToWipe[i];
            _burn(current, balanceOf(current));
        }
    }
}
