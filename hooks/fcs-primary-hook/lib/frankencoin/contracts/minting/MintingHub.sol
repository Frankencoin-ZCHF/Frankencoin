// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../erc20/IERC20.sol";
import "../rate/ILeadrate.sol";
import "../stablecoin/IFrankencoin.sol";
import "../minting/IPosition.sol";
import "../minting/IPositionFactory.sol";
import "./PositionRoller.sol";
import "../utils/Ownable.sol";

/**
 * @title Minting Hub
 * @notice The central hub for creating, cloning and challenging collateralized Frankencoin positions.
 * @dev Only one instance of this contract is required, whereas every new position comes with a new position
 * contract. Pending challenges are stored as structs in an array.
 */
contract MintingHub {
    /**
     * @notice Irrevocable fee in ZCHF when proposing a new position (but not when cloning an existing one).
     */
    uint256 public constant OPENING_FEE = 1000 * 10 ** 18;

    /**
     * @notice The challenger reward in parts per million (ppm) relative to the challenged amount, whereas
     * challenged amount if defined as the challenged collateral amount times the liquidation price.
     */
    uint256 public constant CHALLENGER_REWARD = 20000; // 2%
    uint256 public constant EXPIRED_PRICE_FACTOR = 10;

    IPositionFactory private immutable POSITION_FACTORY; // position contract to clone

    IFrankencoin public immutable zchf; // currency
    PositionRoller public immutable roller; // helper to roll positions
    ILeadrate public immutable rate; // to determine the interest rate

    Challenge[] public challenges; // list of open challenges

    /**
     * @notice Map to remember pending postponed collateral returns.
     * @dev It maps collateral => beneficiary => amount.
     */
    mapping(address collateral => mapping(address owner => uint256 amount)) public pendingReturns;

    struct Challenge {
        address challenger; // the address from which the challenge was initiated
        uint40 start; // the start of the challenge
        IPosition position; // the position that was challenged
        uint256 size; // how much collateral the challenger provided
    }

    event PositionOpened(address indexed owner, address indexed position, address original, address collateral);
    event ChallengeStarted(address indexed challenger, address indexed position, uint256 size, uint256 number);
    event ChallengeAverted(address indexed position, uint256 number, uint256 size);
    event ChallengeSucceeded(
        address indexed position,
        uint256 number,
        uint256 bid,
        uint256 acquiredCollateral,
        uint256 challengeSize
    );
    event PostPonedReturn(address collateral, address indexed beneficiary, uint256 amount);
    event ForcedSale(address pos, uint256 amount, uint256 priceE36MinusDecimals);

    error UnexpectedPrice();
    error InvalidPos();
    error IncompatibleCollateral();
    error InsufficientCollateral();

    modifier validPos(address position) {
        if (zchf.getPositionParent(position) != address(this)) revert InvalidPos();
        _;
    }

    constructor(address _zchf, address _leadrate, address _roller, address _factory) {
        zchf = IFrankencoin(_zchf);
        rate = ILeadrate(_leadrate);
        POSITION_FACTORY = IPositionFactory(_factory);
        roller = PositionRoller(_roller);
    }

    /**
     * @notice Open a collateralized loan position. See also https://docs.frankencoin.com/positions/open .
     * @dev For a successful call, you must set an allowance for the collateral token, allowing
     * the minting hub to transfer the initial collateral amount to the newly created position and to
     * withdraw the fees.
     *
     * @param _collateralAddress        address of collateral token
     * @param _minCollateral     minimum collateral required to prevent dust amounts
     * @param _initialCollateral amount of initial collateral to be deposited
     * @param _mintingMaximum    maximal amount of ZCHF that can be minted by the position owner
     * @param _expirationSeconds position tenor in unit of timestamp (seconds) from 'now'
     * @param _challengeSeconds  challenge period. Longer for less liquid collateral.
     * @param _riskPremium       ppm of minted amount that is added to the applicible minting fee as a risk premium
     * @param _liqPrice          Liquidation price with (36 - token decimals) decimals,
     *                           e.g. 18 decimals for an 18 dec collateral, 36 decs for a 0 dec collateral.
     * @param _reservePPM        ppm of minted amount that is locked as borrower's reserve, e.g. 20%
     * @return address           address of created position
     */
    function openPosition(
        address _collateralAddress,
        uint256 _minCollateral,
        uint256 _initialCollateral,
        uint256 _mintingMaximum,
        uint40 _initPeriodSeconds,
        uint40 _expirationSeconds,
        uint40 _challengeSeconds,
        uint24 _riskPremium,
        uint256 _liqPrice,
        uint24 _reservePPM
    ) public returns (address) {
        {
            require(_riskPremium <= 1000000);
            require(CHALLENGER_REWARD <= _reservePPM && _reservePPM <= 1000000);
            require(IERC20(_collateralAddress).decimals() <= 24); // leaves 12 digits for price
            uint256 invalidAmount = IERC20(_collateralAddress).totalSupply() + 1;
            try IERC20(_collateralAddress).transfer(address(0x123), invalidAmount) {
                revert IncompatibleCollateral(); // we need a collateral that reverts on failed transfers
            } catch Error(string memory /*reason*/) {
            } catch Panic(uint /*errorCode*/) {
            } catch (bytes memory /*lowLevelData*/) {
            }
            if (_initialCollateral < _minCollateral) revert InsufficientCollateral();
            if (_minCollateral * _liqPrice < 5000 ether * 10 ** 18) revert InsufficientCollateral(); // must start with at least 5000 ZCHF worth of collateral
        }
        IPosition pos = IPosition(
            POSITION_FACTORY.createNewPosition(
                msg.sender,
                address(zchf),
                _collateralAddress,
                _minCollateral,
                _mintingMaximum,
                _initPeriodSeconds,
                _expirationSeconds,
                _challengeSeconds,
                _riskPremium,
                _liqPrice,
                _reservePPM
            )
        );
        zchf.registerPosition(address(pos));
        zchf.collectProfits(msg.sender, OPENING_FEE);
        IERC20(_collateralAddress).transferFrom(msg.sender, address(pos), _initialCollateral);

        emit PositionOpened(msg.sender, address(pos), address(pos), _collateralAddress);
        return address(pos);
    }

   function clone(address parent, uint256 _initialCollateral, uint256 _initialMint, uint40 expiration) public returns (address) {
        return clone(msg.sender, parent, _initialCollateral, _initialMint, expiration);
   }

    /**
     * @notice Clones an existing position and immediately tries to mint the specified amount using the given collateral.
     * @dev This needs an allowance to be set on the collateral contract such that the minting hub can get the collateral.
     */
    function clone(address owner, address parent, uint256 _initialCollateral, uint256 _initialMint, uint40 expiration) public validPos(parent) returns (address) {
        address pos = POSITION_FACTORY.clonePosition(parent);
        IPosition child = IPosition(pos);
        child.initialize(parent, expiration);
        zchf.registerPosition(pos);
        IERC20 collateral = child.collateral();
        if (_initialCollateral < child.minimumCollateral()) revert InsufficientCollateral();
        collateral.transferFrom(msg.sender, pos, _initialCollateral); // collateral must still come from sender for security
        emit PositionOpened(owner, address(pos), parent, address(collateral));
        child.mint(owner, _initialMint);
        Ownable(address(child)).transferOwnership(owner);
        return address(pos);
    }

    /**
     * @notice Launch a challenge (Dutch auction) on a position
     * @param _positionAddr      address of the position we want to challenge
     * @param _collateralAmount  amount of the collateral we want to challenge
     * @param minimumPrice       position.price() to guard against the minter fruntrunning with a price change
     * @return index of the challenge in challenge-array
     */
    function challenge(
        address _positionAddr,
        uint256 _collateralAmount,
        uint256 minimumPrice
    ) external validPos(_positionAddr) returns (uint256) {
        IPosition position = IPosition(_positionAddr);
        // challenger should be ok if frontrun by owner with a higher price
        // in case owner fruntruns challenger with small price decrease to prevent challenge,
        // the challenger should set minimumPrice to market price
        if (position.price() < minimumPrice) revert UnexpectedPrice(); 
        IERC20(position.collateral()).transferFrom(msg.sender, address(this), _collateralAmount);
        uint256 pos = challenges.length;
        challenges.push(Challenge(msg.sender, uint40(block.timestamp), position, _collateralAmount));
        position.notifyChallengeStarted(_collateralAmount);
        emit ChallengeStarted(msg.sender, address(position), _collateralAmount, pos);
        return pos;
    }

    /**
     * @notice Post a bid in ZCHF given an open challenge.
     *
     * @dev In case that the collateral cannot be transfered back to the challenger (i.e. because the collateral token
     * has a blacklist and the challenger is on it), it is possible to postpone the return of the collateral.
     *
     * @param _challengeNumber  index of the challenge as broadcast in the event
     * @param size              how much of the collateral the caller wants to bid for at most
     *                          (automatically reduced to the available amount)
     * @param postponeCollateralReturn To postpone the return of the collateral to the challenger. Usually false.
     */
    function bid(uint32 _challengeNumber, uint256 size, bool postponeCollateralReturn) external {
        Challenge memory _challenge = challenges[_challengeNumber];
        (uint256 liqPrice, uint40 phase) = _challenge.position.challengeData();
        size = _challenge.size < size ? _challenge.size : size; // cannot bid for more than the size of the challenge

        if (block.timestamp <= _challenge.start + phase) {
            _avertChallenge(_challenge, _challengeNumber, liqPrice, size);
            emit ChallengeAverted(address(_challenge.position), _challengeNumber, size);
        } else {
            _returnChallengerCollateral(_challenge, _challengeNumber, size, postponeCollateralReturn);
            (uint256 transferredCollateral, uint256 offer) = _finishChallenge(_challenge, liqPrice, phase, size);
            emit ChallengeSucceeded(address(_challenge.position), _challengeNumber, offer, transferredCollateral, size);
        }
    }

    function _finishChallenge(Challenge memory _challenge, uint256 liqPrice, uint40 phase, uint256 size) internal returns (uint256, uint256) {
        // Repayments depend on what was actually minted, whereas bids depend on the available collateral
        (address owner, uint256 collateral, uint256 repayment, uint32 reservePPM) = _challenge.position.notifyChallengeSucceeded(msg.sender, size);

        // No overflow possible thanks to invariant (col * price <= limit * 10**18)
        // enforced in Position.setPrice and knowing that collateral <= col.
        uint256 offer = (_calculatePrice(_challenge.start + phase, phase, liqPrice) * collateral) / 10 ** 18;
        zchf.transferFrom(msg.sender, address(this), offer); // get money from bidder
        uint256 reward = (offer * CHALLENGER_REWARD) / 1000_000;
        zchf.transfer(_challenge.challenger, reward); // pay out the challenger reward
        uint256 fundsAvailable = offer - reward; // funds available after reward

        // Example: available funds are 90, repayment is 50, reserve 20%. Then 20%*(90-50)=16 are collected as profits
        // and the remaining 34 are sent to the position owner. If the position owner maxed out debt before the challenge
        // started and the liquidation price was 100, they would be slightly better off as they would get away with 80
        // instead of 40+36 = 76 in this example.
        if (fundsAvailable > repayment) {
            // The excess amount is distributed between the system and the owner using the reserve ratio
            // At this point, we cannot rely on the liquidation price because the challenge might have been started as a
            // response to an unreasonable increase of the liquidation price, such that we have to use this heuristic
            // for excess fund distribution, which make position owners that maxed out their positions slightly better
            // off in comparison to those who did not.
            uint256 profits = (reservePPM * (fundsAvailable - repayment)) / 1000_000;
            zchf.collectProfits(address(this), profits);
            zchf.transfer(owner, fundsAvailable - repayment - profits);
        } else if (fundsAvailable < repayment) {
            zchf.coverLoss(address(this), repayment - fundsAvailable); // ensure we have enough to pay everything
        }
        zchf.burnWithoutReserve(repayment, reservePPM); // Repay the challenged part, example: 50 ZCHF leading to 10 ZCHf in implicit profits
        return (collateral, offer);
    }

    function _avertChallenge(Challenge memory _challenge, uint32 number, uint256 liqPrice, uint256 size) internal {
        require(block.timestamp != _challenge.start); // do not allow to avert the challenge in the same transaction, see CS-ZCHF-037
        if (msg.sender == _challenge.challenger) {
            // allow challenger to cancel challenge without paying themselves
        } else {
            zchf.transferFrom(msg.sender, _challenge.challenger, (size * liqPrice) / (10 ** 18));
        }

        _challenge.position.notifyChallengeAverted(size);
        _challenge.position.collateral().transfer(msg.sender, size);
        if (size < _challenge.size) {
            challenges[number].size = _challenge.size - size;
        } else {
            require(size == _challenge.size);
            delete challenges[number];
        }
    }

    /**
     * @notice Returns 'amount' of the collateral to the challenger and reduces or deletes the relevant challenge.
     */
    function _returnChallengerCollateral(
        Challenge memory _challenge,
        uint32 number,
        uint256 amount,
        bool postpone
    ) internal {
        _returnCollateral(_challenge.position.collateral(), _challenge.challenger, amount, postpone);
        if (_challenge.size == amount) {
            // bid on full amount
            delete challenges[number];
        } else {
            // bid on partial amount
            challenges[number].size -= amount;
        }
    }

    /**
     * @notice Calculates the current Dutch auction price.
     * @dev Starts at the full price at time 'start' and linearly goes to 0 as 'phase2' passes.
     */
    function _calculatePrice(uint40 start, uint40 phase2, uint256 liqPrice) internal view returns (uint256) {
        uint40 timeNow = uint40(block.timestamp);
        if (timeNow <= start) {
            return liqPrice;
        } else if (timeNow >= start + phase2) {
            return 0;
        } else {
            uint256 timeLeft = phase2 - (timeNow - start);
            return (liqPrice / phase2) * timeLeft;
        }
    }

    /**
     * @notice Get the price per unit of the collateral for the given challenge.
     * @dev The price comes with (36-collateral.decimals()) digits, such that multiplying it with the
     * raw collateral amount always yields a price with 36 digits, or 18 digits after dividing by 10**18 again.
     */
    function price(uint32 challengeNumber) public view returns (uint256) {
        Challenge memory _challenge = challenges[challengeNumber];
        if (_challenge.challenger == address(0x0)) {
            return 0;
        } else {
            (uint256 liqPrice, uint40 phase) = _challenge.position.challengeData();
            return _calculatePrice(_challenge.start + phase, phase, liqPrice);
        }
    }

    /**
     * @notice Challengers can call this method to withdraw collateral whose return was postponed.
     */
    function returnPostponedCollateral(address collateral, address target) external {
        uint256 amount = pendingReturns[collateral][msg.sender];
        delete pendingReturns[collateral][msg.sender];
        IERC20(collateral).transfer(target, amount);
    }

    function _returnCollateral(IERC20 collateral, address recipient, uint256 amount, bool postpone) internal {
        if (postpone) {
            // Postponing helps in case the challenger was blacklisted or otherwise cannot receive at the moment.
            pendingReturns[address(collateral)][recipient] += amount;
            emit PostPonedReturn(address(collateral), recipient, amount);
        } else {
            collateral.transfer(recipient, amount); // return the challenger's collateral
        }
    }

    /**
     * The applicable purchase price when forcing the sale of collateral of an expired position.
     * 
     * The price starts at 10x the liquidation price at the expiration time, linearly declines to
     * 1x liquidation price over the course of one challenge period, and then linearly declines
     * less steeply to 0 over the course of another challenge period.
     */
    function expiredPurchasePrice(IPosition pos) public view returns (uint256) {
        uint256 liqprice = pos.price();
        uint256 expiration = pos.expiration();
        if (block.timestamp <= expiration) {
            return EXPIRED_PRICE_FACTOR * liqprice;
        } else {
            uint256 challengePeriod = pos.challengePeriod();
            uint256 timePassed = block.timestamp - expiration;
            if (timePassed <= challengePeriod) {
                // from 10x liquidation price to 1x in first phase
                uint256 timeLeft = challengePeriod - timePassed;
                return liqprice + (((EXPIRED_PRICE_FACTOR - 1) * liqprice) / challengePeriod) * timeLeft;
            } else if (timePassed < 2 * challengePeriod) {
                // from 1x liquidation price to 0 in second phase
                uint256 timeLeft = 2 * challengePeriod - timePassed;
                return (liqprice / challengePeriod) * timeLeft;
            } else {
                // get collateral for free after both phases passed
                return 0;
            }
        }
    }

    /**
     * Buys up to the desired amount of the collateral asset from the given expired position using
     * the applicable 'expiredPurchasePrice' in that instant.
     */
    function buyExpiredCollateral(IPosition pos, uint256 upToAmount) external returns (uint256) {
        uint256 max = pos.collateral().balanceOf(address(pos));
        uint256 amount = upToAmount > max ? max : upToAmount;
        uint256 forceSalePrice = expiredPurchasePrice(pos);
        uint256 costs = (forceSalePrice * amount) / 10 ** 18;
        pos.forceSale(msg.sender, amount, costs);
        emit ForcedSale(address(pos), amount, forceSalePrice);
        return amount;
    }
}
