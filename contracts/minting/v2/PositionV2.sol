// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../../utils/Ownable.sol";
import "../../utils/MathUtil.sol";

import "../../erc20/IERC20.sol";
import "../../rate/ILeadrate.sol";
import "../v1/IReserve.sol";
import "../v1/IFrankencoin.sol";

import "./IPositionV2.sol";

/**
 * @title PositionV2
 * @notice A collateralized minting position.
 */
contract PositionV2 is Ownable, IPositionV2, MathUtil {
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
     * @notice How much has been minted in total. This variable is only used in the parent position.
     */
    uint256 private totalMinted;

    uint256 public immutable limit;

    /**
     * @notice Amount of the collateral that is currently under a challenge.
     * Used to figure out whether there are pending challenges.
     */
    uint256 public challengedAmount;

    /**
     * @notice Challenge period in seconds.
     */
    uint40 public immutable challengePeriod;

    /**
     * @notice Timestamp when minting can start and the position no longer denied.
     */
    uint40 public immutable start;

    /**
     * @notice End of the latest cooldown. If this is in the future, minting is suspended.
     */
    uint40 public cooldown;

    /**
     * @notice Timestamp of the expiration of the position. After expiration, challenges cannot be averted
     * any more. This is also the basis for fee calculations.
     */
    uint40 public expiration;

    bool private closed;

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
     * @notice The interest in parts per million per year that is deducted when minting Frankencoins.
     * To be paid upfront.
     */
    uint24 public immutable riskPremiumPPM;

    /**
     * @notice The reserve contribution in parts per million of the minted amount.
     */
    uint24 public immutable reserveContribution;

    event MintingUpdate(uint256 collateral, uint256 price, uint256 minted);
    event PositionDenied(address indexed sender, string message); // emitted if closed by governance

    error InsufficientCollateral(uint256 needed, uint256 available);
    error TooLate();
    error RepaidTooMuch(uint256 excess);
    error LimitExceeded(uint256 tried, uint256 available);
    error ChallengeTooSmall();
    error Expired(uint40 time, uint40 expiration);
    error Alive();
    error Closed();
    error Hot();
    error Challenged();
    error NotHub();
    error NotOriginal();
    error InvalidExpiration();
    error AlreadyInitialized();

    modifier alive() {
        if (block.timestamp >= expiration) revert Expired(uint40(block.timestamp), expiration);
        _;
    }

    // requires that the position has always been backed by a minimal amount of collateral
    modifier backed() {
        if (isClosed()) revert Closed();
        _;
    }

    modifier expired() {
        if (block.timestamp < expiration) revert Alive();
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

    modifier ownerOrRoller() {
        if (msg.sender != address(IHub(hub).roller())) _requireOwner(msg.sender);
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
        uint40 _initPeriod,
        uint40 _duration,
        uint40 _challengePeriod,
        uint24 _riskPremiumPPM,
        uint256 _liqPrice,
        uint24 _reservePPM
    ) {
        require(_initPeriod >= 3 days); // must be at least three days, recommended to use higher values
        _setOwner(_owner);
        original = address(this);
        hub = _hub;
        zchf = IFrankencoin(_zchf);
        collateral = IERC20(_collateral);
        riskPremiumPPM = _riskPremiumPPM;
        reserveContribution = _reservePPM;
        minimumCollateral = _minCollateral;
        challengePeriod = _challengePeriod;
        start = uint40(block.timestamp) + _initPeriod; // at least three days time to deny the position
        cooldown = start;
        expiration = start + _duration;
        limit = _initialLimit;
        _setPrice(_liqPrice, _initialLimit);
    }

    /**
     * Initialization method for clones.
     * Can only be called once. Should be called immediately after creating the clone.
     */
    function initialize(address parent, uint40 _expiration) external onlyHub {
        if (expiration != 0) revert AlreadyInitialized();
        if (_expiration < block.timestamp || _expiration > PositionV2(original).expiration()) revert InvalidExpiration(); // expiration must not be later than original
        expiration = _expiration;
        price = PositionV2(parent).price();
        _setOwner(hub);
    }

    /**
     * Cloning a position is only allowed if the position is not challenged, not expired and not in cooldown.
     */
    function assertCloneable() external noChallenge noCooldown alive backed {}

    /**
     * Notify the original that some amount has been minted.
     */
    function notifyMint(uint256 mint_) external {
        if (zchf.getPositionParent(msg.sender) != hub) revert NotHub();
        totalMinted += mint_;
    }

    function notifyRepaid(uint256 repaid_) external {
        if (zchf.getPositionParent(msg.sender) != hub) revert NotHub();
        totalMinted -= repaid_;
    }

    /**
     * Should only be called on the original position.
     * Better use 'availableForMinting'.
     */
    function availableForClones() external view returns (uint256) {
        // reserve capacity for the original to the extent the owner provided collateral
        uint256 potential = (_collateralBalance() * price) / ONE_DEC18;
        uint256 unusedPotential = minted > potential ? 0 : potential - minted;
        if (totalMinted + unusedPotential >= limit) {
            return 0;
        } else {
            return limit - totalMinted - unusedPotential;
        }
    }

    /**
     * The amount available for minting in this position family.
     *
     * Does not check if positions are challenged, closed, or under cooldown.
     */
    function availableForMinting() public view returns (uint256) {
        if (address(this) == original) {
            return limit - totalMinted;
        } else {
            return PositionV2(original).availableForClones();
        }
    }

    /**
     * @notice Qualified pool share holders can call this method to immediately expire a freshly proposed position.
     */
    function deny(address[] calldata helpers, string calldata message) external {
        if (block.timestamp >= start) revert TooLate();
        IReserve(zchf.reserve()).checkQualified(msg.sender, helpers);
        _close();
        emit PositionDenied(msg.sender, message);
    }

    /**
     * Closes the position by putting it into eternal cooldown.
     * This allows the users to still withdraw the collateral that is left, but never to mint again.
     */
    function _close() internal {
        closed = true;
    }

    function isClosed() public view returns (bool) {
        return closed;
    }

    /**
     * @notice This is how much the minter can actually use when minting ZCHF, with the rest being used
     * assigned to the minter reserve or (if applicable) fees.
     */
    function getUsableMint(uint256 totalMint, bool afterFees) public view returns (uint256) {
        if (afterFees) {
            return (totalMint * (1000_000 - reserveContribution - calculateCurrentFee())) / 1000_000;
        } else {
            return (totalMint * (1000_000 - reserveContribution)) / 1000_000;
        }
    }

    /**
     * Returns the corresponding mint amount (disregarding the limit).
     */
    function getMintAmount(uint256 usableMint) external view returns (uint256) {
        return usableMint == 0 ? 0 : (usableMint * 1000_000 - 1) / (1000_000 - reserveContribution - calculateCurrentFee()) + 1;
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
            _notifyRepaid(minted - newMinted);
        }
        if (newCollateral < colbal) {
            _withdrawCollateral(msg.sender, colbal - newCollateral);
        }
        // Must be called after collateral withdrawal
        if (newMinted > minted) {
            _mint(msg.sender, newMinted - minted, newCollateral);
        }
        if (newPrice != price) {
            _adjustPrice(newPrice);
        }
        emit MintingUpdate(newCollateral, newPrice, newMinted);
    }

    /**
     * @notice Allows the position owner to adjust the liquidation price as long as there is no pending challenge.
     * Lowering the liquidation price can be done with immediate effect, given that there is enough collateral.
     * Increasing the liquidation price triggers a cooldown period of 3 days, during which minting is suspended.
     */
    function adjustPrice(uint256 newPrice) public onlyOwner {
        _adjustPrice(newPrice);
        emit MintingUpdate(_collateralBalance(), price, minted);
    }

    function _adjustPrice(uint256 newPrice) internal noChallenge alive backed {
        if (newPrice > price) {
            _restrictMinting(3 days);
        } else {
            _checkCollateral(_collateralBalance(), newPrice);
        }
        _setPrice(newPrice, minted + availableForMinting());
    }

    function _setPrice(uint256 newPrice, uint256 bounds) internal {
        require(newPrice * minimumCollateral <= bounds * ONE_DEC18); // sanity check
        price = newPrice;
    }

    function _collateralBalance() internal view returns (uint256) {
        return IERC20(collateral).balanceOf(address(this));
    }

    /**
     * @notice Mint ZCHF as long as there is no open challenge, the position is not subject to a cooldown,
     * and there is sufficient collateral.
     */
    function mint(address target, uint256 amount) public ownerOrRoller {
        uint256 collateralBalance = _collateralBalance();
        _mint(target, amount, collateralBalance);
        emit MintingUpdate(collateralBalance, price, minted);
    }

    /**
     * The applicable upfront fee in ppm when minting more Frankencoins based on the annual interest rate and
     * the expiration of the position.
     */
    function calculateCurrentFee() public view returns (uint24) {
        return calculateFee(expiration);
    }

    /**
     * The applicable interest rate in ppm when minting more Frankencoins.
     * It consists on the globally valid interest plus an individual risk premium.
     */
    function annualInterestPPM() public view returns (uint24) {
        return IHub(hub).rate().currentRatePPM() + riskPremiumPPM;
    }

    /**
     * The fee in ppm when cloning and minting with the given expiration date.
     */
    function calculateFee(uint256 exp) public view returns (uint24) {
        uint256 time = block.timestamp < start ? start : block.timestamp;
        uint256 timePassed = exp - time;
        // Time resolution is in the range of minutes for typical interest rates.
        uint256 feePPM = (timePassed * annualInterestPPM()) / 365 days;
        return uint24(feePPM > 1000000 ? 1000000 : feePPM); // fee cannot exceed 100%
    }

    function _mint(address target, uint256 amount, uint256 collateral_) internal noChallenge noCooldown alive backed {
        if (amount > availableForMinting()) revert LimitExceeded(amount, availableForMinting());
        PositionV2(original).notifyMint(amount);
        zchf.mintWithReserve(target, amount, reserveContribution, calculateCurrentFee());
        minted += amount;
        _checkCollateral(collateral_, price);
    }

    function _restrictMinting(uint40 period) internal {
        uint40 horizon = uint40(block.timestamp) + period;
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
    function repay(uint256 amount) public returns (uint256) {
        IERC20(zchf).transferFrom(msg.sender, address(this), amount);
        uint256 actuallyRepaid = IFrankencoin(zchf).burnWithReserve(amount, reserveContribution);
        _notifyRepaid(actuallyRepaid);
        emit MintingUpdate(_collateralBalance(), price, minted);
        return actuallyRepaid;
    }

    function _notifyRepaid(uint256 amount) internal {
        if (amount > minted) revert RepaidTooMuch(amount - minted);
        PositionV2(original).notifyRepaid(amount);
        minted -= amount;
    }

    /**
     * Force the sale of some collateral after the position is expired.
     *
     * Can only be called by the minting hub and the minting hub is trusted to calculate the price correctly.
     * The proceeds from the sale are first used to repay the outstanding balance and then (if anything is left)
     * it is sent to the owner of the position.
     *
     * Do not allow a forced sale as long as there is an open challenge. Otherwise, a forced sale by the owner
     * himself could remove any incentive to launch challenges shortly before the expiration. (CS-ZCHF2-001)
     */
    function forceSale(address buyer, uint256 collAmount, uint256 proceeds) external onlyHub expired noChallenge {
        // send collateral to buyer
        uint256 remainingCollateral = _sendCollateral(buyer, collAmount);
        if (minted > 0) {
            uint256 availableReserve = zchf.calculateAssignedReserve(minted, reserveContribution);
            if (proceeds + availableReserve >= minted) {
                // repay everything from the buyer's account
                uint256 returnedReserve = zchf.burnFromWithReserve(buyer, minted, reserveContribution);
                assert(returnedReserve == availableReserve);
                // transfer the remaining purchase price from the buyer to the owner
                zchf.transferFrom(buyer, owner, proceeds + returnedReserve - minted);
                _notifyRepaid(minted);
            } else {
                // we can only repay a part, nothing left to pay to owner
                zchf.transferFrom(buyer, address(this), proceeds);
                if (remainingCollateral == 0) {
                    // CS-ZCHF2-002, bad debt should be properly handled. In this case, the proceeds from
                    // the forced sale did not suffice to repay the position and there is a loss
                    zchf.coverLoss(address(this), minted - proceeds); // more than we need, but returned again on next line
                    zchf.burnWithoutReserve(minted, reserveContribution);
                    _notifyRepaid(minted);
                } else {
                    uint256 repaid = zchf.burnWithReserve(proceeds, reserveContribution);
                    _notifyRepaid(repaid);
                }
            }
        } else {
            // wire funds directly to owner
            zchf.transferFrom(buyer, owner, proceeds);
        }
        emit MintingUpdate(_collateralBalance(), price, minted);
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
    function withdrawCollateral(address target, uint256 amount) public ownerOrRoller {
        uint256 balance = _withdrawCollateral(target, amount);
        emit MintingUpdate(balance, price, minted);
    }

    function _withdrawCollateral(address target, uint256 amount) internal noChallenge returns (uint256) {
        if (block.timestamp <= cooldown) revert Hot();
        uint256 balance = _sendCollateral(target, amount);
        _checkCollateral(balance, price);
        return balance;
    }

    function _sendCollateral(address target, uint256 amount) internal returns (uint256) {
        if (amount > 0) {
            // Some weird tokens fail when trying to transfer 0 amounts
            IERC20(collateral).transfer(target, amount);
        }
        uint256 balance = _collateralBalance();
        if (balance < minimumCollateral) {
            _close();
        }
        return balance;
    }

    /**
     * @notice This invariant must always hold and must always be checked when any of the three
     * variables change in an adverse way.
     */
    function _checkCollateral(uint256 collateralReserve, uint256 atPrice) internal view {
        uint256 relevantCollateral = collateralReserve < minimumCollateral ? 0 : collateralReserve;
        if (relevantCollateral * atPrice < minted * ONE_DEC18) revert InsufficientCollateral(relevantCollateral * atPrice, minted * ONE_DEC18);
    }

    /**
     * @notice Returns the liquidation price and the durations for phase1 and phase2 of the challenge.
     * Both phases are usually of equal duration, but near expiration, phase one is adjusted such that
     * it cannot last beyond the expiration date of the position.
     */
    function challengeData() external view returns (uint256 liqPrice, uint40 phase) {
        return (price, challengePeriod);
    }

    function notifyChallengeStarted(uint256 size) external onlyHub alive {
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

        uint256 newBalance = _sendCollateral(_bidder, _size); // transfer collateral to the bidder and emit update

        emit MintingUpdate(newBalance, price, minted);

        return (owner, _size, repayment, reserveContribution);
    }
}

interface IHub {
    function rate() external view returns (ILeadrate);

    function roller() external view returns (address);
}
