// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../../utils/Ownable.sol";
import "../../utils/MathUtil.sol";

import "../../erc20/IERC20.sol";
import "./IReserve.sol";
import "./IFrankencoin.sol";

import "./IPositionV1.sol";

/**
 * @title Position
 * @notice A collateralized minting position.
 */
contract PositionV1 is Ownable, IPositionV1, MathUtil {
    /**
     * @notice Note that this contract is intended to be cloned. All clones will share the same values for
     * the constant and immutable fields, but have their own values for the other fields.
     */

    /**
     * @notice The zchf price per unit of the collateral below which challenges succeed, (36 - collateral.decimals) decimals
     */
    uint256 public price;

    /**
     * @notice Net minted amount, including reserve.
     */
    uint256 public minted;

    /**
     * @notice Amount of the collateral that is currently under a challenge.
     * Used to figure out whether there are pending challenges.
     */
    uint256 public challengedAmount;

    /**
     * @notice Challenge period in seconds.
     */
    uint64 public immutable challengePeriod;

    /**
     * @notice End of the latest cooldown. If this is in the future, minting is suspended.
     */
    uint256 public cooldown;

    /**
     * @notice How much can be minted at most.
     */
    uint256 public limit;

    /**
     * @notice Timestamp when minting can start and the position no longer denied.
     */
    uint256 public immutable start;

    /**
     * @notice Timestamp of the expiration of the position. After expiration, challenges cannot be averted
     * any more. This is also the basis for fee calculations.
     */
    uint256 public expiration;

    /**
     * @notice The original position to help identifying clones.
     */
    address public immutable original;

    /**
     * @notice Pointer to the minting hub.
     */
    address public immutable hub;

    /**
     * @notice The Frankencoin contract.
     */
    IFrankencoin public immutable zchf;

    /**
     * @notice The collateral token.
     */
    IERC20 public immutable override collateral;

    /**
     * @notice Minimum acceptable collateral amount to prevent dust.
     */
    uint256 public immutable override minimumCollateral;

    /**
     * @notice Always pay interest for at least four weeks.
     */
    uint256 private constant MIN_INTEREST_DURATION = 4 weeks;

    /**
     * @notice The interest in parts per million per year that is deducted when minting Frankencoins.
     * To be paid upfront.
     */
    uint32 public immutable annualInterestPPM;

    /**
     * @notice The reserve contribution in parts per million of the minted amount.
     */
    uint32 public immutable reserveContribution;

    event MintingUpdate(uint256 collateral, uint256 price, uint256 minted, uint256 limit);
    event PositionDenied(address indexed sender, string message); // emitted if closed by governance

    error InsufficientCollateral();
    error TooLate();
    error RepaidTooMuch(uint256 excess);
    error LimitExceeded();
    error ChallengeTooSmall();
    error Expired();
    error Hot();
    error Challenged();
    error NotHub();

    modifier alive() {
        if (block.timestamp >= expiration) revert Expired();
        _;
    }

    modifier noCooldown() {
        if (block.timestamp <= cooldown) revert Hot();
        _;
    }

    modifier noChallenge() {
        if (challengedAmount > 0) revert Challenged();
        _;
    }

    modifier onlyHub() {
        if (msg.sender != address(hub)) revert NotHub();
        _;
    }

    /**
     * @dev See MintingHub.openPosition
     */
    constructor(
        address _owner,
        address _hub,
        address _zchf,
        address _collateral,
        uint256 _minCollateral,
        uint256 _initialLimit,
        uint256 _initPeriod,
        uint256 _duration,
        uint64 _challengePeriod,
        uint32 _annualInterestPPM,
        uint256 _liqPrice,
        uint32 _reservePPM
    ) {
        require(_initPeriod >= 3 days); // must be at least three days, recommended to use higher values
        _setOwner(_owner);
        original = address(this);
        hub = _hub;
        zchf = IFrankencoin(_zchf);
        collateral = IERC20(_collateral);
        annualInterestPPM = _annualInterestPPM;
        reserveContribution = _reservePPM;
        minimumCollateral = _minCollateral;
        challengePeriod = _challengePeriod;
        start = block.timestamp + _initPeriod; // at least three days time to deny the position
        cooldown = start;
        expiration = start + _duration;
        limit = _initialLimit;
        _setPrice(_liqPrice);
    }

    /**
     * @notice Method to initialize a freshly created clone. It is the responsibility of the creator to make sure this is only
     * called once and to call reduceLimitForClone on the original position before initializing the clone.
     */
    function initializeClone(address owner, uint256 _price, uint256 _coll, uint256 _initialMint, uint256 expirationTime) external onlyHub {
        if (_coll < minimumCollateral) revert InsufficientCollateral();
        uint256 impliedPrice = (_initialMint * ONE_DEC18) / _coll;
        _initialMint = (impliedPrice * _coll) / ONE_DEC18; // to cancel potential rounding errors
        if (impliedPrice > _price) revert InsufficientCollateral();
        _setOwner(owner);
        limit = _initialMint;
        expiration = expirationTime;
        _setPrice(impliedPrice);
        _mint(owner, _initialMint, _coll);
    }

    function limitForClones() public view returns (uint256) {
        uint256 backedLimit = (_collateralBalance() * price) / ONE_DEC18;
        if (backedLimit >= limit) {
            return 0;
        } else {
            // due to invariants, this is always below (limit - minted)
            return limit - backedLimit;
        }
    }

    /**
     * @notice Adjust this position's limit to allow a clone to mint its own Frankencoins.
     * Invariant: global limit stays the same.
     *
     * Cloning a position is only allowed if the position is not challenged, not expired and not in cooldown.
     */
    function reduceLimitForClone(uint256 mint_) external noChallenge noCooldown alive onlyHub {
        if (mint_ > limitForClones()) revert LimitExceeded();
        limit -= mint_;
    }

    /**
     * @notice Qualified pool share holders can call this method to immediately expire a freshly proposed position.
     */
    function deny(address[] calldata helpers, string calldata message) external {
        if (block.timestamp >= start) revert TooLate();
        IReserve(zchf.reserve()).checkQualified(msg.sender, helpers);
        _close(); // since expiration is immutable, we put it under eternal cooldown
        emit PositionDenied(msg.sender, message);
    }

    function _close() internal {
        cooldown = type(uint256).max;
    }

    function isClosed() public view returns (bool) {
        return cooldown == type(uint256).max;
    }

    /**
     * @notice This is how much the minter can actually use when minting ZCHF, with the rest being used
     * assigned to the minter reserve or (if applicable) fees.
     */
    function getUsableMint(uint256 totalMint, bool afterFees) external view returns (uint256) {
        if (afterFees) {
            return (totalMint * (1000_000 - reserveContribution - calculateCurrentFee())) / 1000_000;
        } else {
            return (totalMint * (1000_000 - reserveContribution)) / 1000_000;
        }
    }

    /**
     * @notice "All in one" function to adjust the outstanding amount of ZCHF, the collateral amount,
     * and the price in one transaction.
     */
    function adjust(uint256 newMinted, uint256 newCollateral, uint256 newPrice) external onlyOwner {
        uint256 colbal = _collateralBalance();
        if (newCollateral > colbal) {
            collateral.transferFrom(msg.sender, address(this), newCollateral - colbal);
        }
        // Must be called after collateral deposit, but before withdrawal
        if (newMinted < minted) {
            zchf.burnFromWithReserve(msg.sender, minted - newMinted, reserveContribution);
            minted = newMinted;
        }
        if (newCollateral < colbal) {
            withdrawCollateral(msg.sender, colbal - newCollateral);
        }
        // Must be called after collateral withdrawal
        if (newMinted > minted) {
            mint(msg.sender, newMinted - minted);
        }
        if (newPrice != price) {
            adjustPrice(newPrice);
        }
    }

    /**
     * @notice Allows the position owner to adjust the liquidation price as long as there is no pending challenge.
     * Lowering the liquidation price can be done with immediate effect, given that there is enough collateral.
     * Increasing the liquidation price triggers a cooldown period of 3 days, during which minting is suspended.
     */
    function adjustPrice(uint256 newPrice) public onlyOwner noChallenge {
        if (newPrice > price) {
            _restrictMinting(3 days);
        } else {
            _checkCollateral(_collateralBalance(), newPrice);
        }
        _setPrice(newPrice);
        emit MintingUpdate(_collateralBalance(), price, minted, limit);
    }

    function _setPrice(uint256 newPrice) internal {
        require(newPrice * minimumCollateral <= limit * ONE_DEC18); // sanity check
        price = newPrice;
    }

    function _collateralBalance() internal view returns (uint256) {
        return IERC20(collateral).balanceOf(address(this));
    }

    /**
     * @notice Mint ZCHF as long as there is no open challenge, the position is not subject to a cooldown,
     * and there is sufficient collateral.
     */
    function mint(address target, uint256 amount) public onlyOwner noChallenge noCooldown alive {
        _mint(target, amount, _collateralBalance());
    }

    function calculateCurrentFee() public view returns (uint32) {
        uint256 exp = expiration;
        uint256 time = block.timestamp < start ? start : block.timestamp;
        uint256 timePassed = time >= exp - MIN_INTEREST_DURATION ? MIN_INTEREST_DURATION : exp - time;
        // Time resolution is in the range of minutes for typical interest rates.
        return uint32((timePassed * annualInterestPPM) / 365 days);
    }

    function _mint(address target, uint256 amount, uint256 collateral_) internal {
        if (minted + amount > limit) revert LimitExceeded();
        zchf.mintWithReserve(target, amount, reserveContribution, calculateCurrentFee());
        minted += amount;

        _checkCollateral(collateral_, price);
        emit MintingUpdate(_collateralBalance(), price, minted, limit);
    }

    function _restrictMinting(uint256 period) internal {
        uint256 horizon = block.timestamp + period;
        if (horizon > cooldown) {
            cooldown = horizon;
        }
    }

    /**
     * @notice Repay some ZCHF. If too much is repaid, the call fails.
     * It is possible to repay while there are challenges, but the collateral is locked until all is clear again.
     *
     * The repaid amount should fulfill the following equation in order to close the position,
     * i.e. bring the minted amount to 0:
     * minted = amount + zchf.calculateAssignedReserve(amount, reservePPM)
     *
     * Under normal circumstances, this implies:
     * amount = minted * (1000000 - reservePPM)
     *
     * E.g. if minted is 50 and reservePPM is 200000, it is necessary to repay 40 to be able to close the position.
     */
    function repay(uint256 amount) public {
        IERC20(zchf).transferFrom(msg.sender, address(this), amount);
        uint256 actuallyRepaid = IFrankencoin(zchf).burnWithReserve(amount, reserveContribution);
        _notifyRepaid(actuallyRepaid);
        emit MintingUpdate(_collateralBalance(), price, minted, limit);
    }

    function _notifyRepaid(uint256 amount) internal {
        if (amount > minted) revert RepaidTooMuch(amount - minted);
        minted -= amount;
    }

    /**
     * @notice Withdraw any ERC20 token that might have ended up on this address.
     * Withdrawing collateral is subject to the same restrictions as withdrawCollateral(...).
     */
    function withdraw(address token, address target, uint256 amount) external onlyOwner {
        if (token == address(collateral)) {
            withdrawCollateral(target, amount);
        } else {
            uint256 balance = _collateralBalance();
            IERC20(token).transfer(target, amount);
            require(balance == _collateralBalance()); // guard against double-entry-point tokens
        }
    }

    /**
     * @notice Withdraw collateral from the position up to the extent that it is still well collateralized afterwards.
     * Not possible as long as there is an open challenge or the contract is subject to a cooldown.
     *
     * Withdrawing collateral below the minimum collateral amount formally closes the position.
     */
    function withdrawCollateral(address target, uint256 amount) public onlyOwner noChallenge {
        if (block.timestamp <= cooldown && !isClosed()) revert Hot();
        uint256 balance = _withdrawCollateral(target, amount);
        _checkCollateral(balance, price);
        if (balance < minimumCollateral && balance > 0) revert InsufficientCollateral(); // Prevent dust amounts
    }

    function _withdrawCollateral(address target, uint256 amount) internal returns (uint256) {
        if (amount > 0) {
            // Some weird tokens fail when trying to transfer 0 amounts
            IERC20(collateral).transfer(target, amount);
        }
        uint256 balance = _collateralBalance();
        _considerClose(balance);
        emit MintingUpdate(balance, price, minted, limit);
        return balance;
    }

    function _considerClose(uint256 collateralBalance) internal {
        if (collateralBalance < minimumCollateral && challengedAmount == 0) {
            // This leaves a slightly unsatisfying possibility open: if the withdrawal happens due to a successful
            // challenge, there might be a small amount of collateral left that is not withheld in case there are no
            // other pending challenges. The only way to cleanly solve this would be to have two distinct cooldowns,
            // one for minting and one for withdrawals.
            _close();
        }
    }

    /**
     * @notice This invariant must always hold and must always be checked when any of the three
     * variables change in an adverse way.
     */
    function _checkCollateral(uint256 collateralReserve, uint256 atPrice) internal view {
        if (collateralReserve * atPrice < minted * ONE_DEC18) revert InsufficientCollateral();
    }

    /**
     * @notice Returns the liquidation price and the durations for phase1 and phase2 of the challenge.
     * Both phases are usually of equal duration, but near expiration, phase one is adjusted such that
     * it cannot last beyond the expiration date of the position.
     */
    function challengeData(uint256 challengeStart) external view returns (uint256 liqPrice, uint64 phase1, uint64 phase2) {
        uint256 timeToExpiration = challengeStart >= expiration ? 0 : expiration - challengeStart;
        return (price, uint64(_min(timeToExpiration, challengePeriod)), challengePeriod);
    }

    function notifyChallengeStarted(uint256 size) external onlyHub {
        // Require minimum size. Collateral balance can be below minimum if it was partially challenged before.
        if (size < minimumCollateral && size < _collateralBalance()) revert ChallengeTooSmall();
        if (size == 0) revert ChallengeTooSmall();
        challengedAmount += size;
    }

    /**
     * @param size   amount of collateral challenged (dec18)
     */
    function notifyChallengeAverted(uint256 size) external onlyHub {
        challengedAmount -= size;

        // Don't allow minter to close the position immediately so challenge can be repeated before
        // the owner has a chance to mint more on an undercollateralized position
        _restrictMinting(1 days);

        // If this was the last open challenge and there is only a dust amount of collateral left, the position should be closed
        _considerClose(_collateralBalance());
    }

    /**
     * @notice Notifies the position that a challenge was successful.
     * Triggers the payout of the challenged part of the collateral.
     * Everything else is assumed to be handled by the hub.
     *
     * @param _bidder   address of the bidder that receives the collateral
     * @param _size     amount of the collateral bid for
     * @return (position owner, effective challenge size in ZCHF, amount to be repaid, reserve ppm)
     */
    function notifyChallengeSucceeded(address _bidder, uint256 _size) external onlyHub returns (address, uint256, uint256, uint32) {
        challengedAmount -= _size;
        uint256 colBal = _collateralBalance();
        if (colBal < _size) {
            _size = colBal;
        }
        uint256 repayment = colBal == 0 ? 0 : (minted * _size) / colBal; // for enormous colBal, this could be rounded to 0, which is ok
        _notifyRepaid(repayment); // we assume the caller takes care of the actual repayment

        // Give time for additional challenges before the owner can mint again. In particular,
        // the owner might have added collateral only seconds before the challenge ended, preventing a close.
        _restrictMinting(3 days);

        _withdrawCollateral(_bidder, _size); // transfer collateral to the bidder and emit update

        return (owner, _size, repayment, reserveContribution);
    }
}
