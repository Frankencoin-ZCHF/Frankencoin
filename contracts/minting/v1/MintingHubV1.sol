// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../../erc20/IERC20.sol";
import "./IReserve.sol";
import "./IFrankencoin.sol";

import "./IPositionV1.sol";
import "./IPositionFactoryV1.sol";

/**
 * @title Minting Hub
 * @notice The central hub for creating, cloning and challenging collateralized Frankencoin positions.
 * @dev Only one instance of this contract is required, whereas every new position comes with a new position
 * contract. Pending challenges are stored as structs in an array.
 */
contract MintingHubV1 {
    /**
     * @notice Irrevocable fee in ZCHF when proposing a new position (but not when cloning an existing one).
     */
    uint256 public constant OPENING_FEE = 1000 * 10 ** 18;

    /**
     * @notice The challenger reward in parts per million (ppm) relative to the challenged amount, whereas
     * challenged amount if defined as the challenged collateral amount times the liquidation price.
     */
    uint32 public constant CHALLENGER_REWARD = 20000; // 2%

    IPositionFactoryV1 private immutable POSITION_FACTORY; // position contract to clone

    IFrankencoin public immutable zchf; // currency
    Challenge[] public challenges; // list of open challenges

    /**
     * @notice Map to remember pending postponed collateral returns.
     * @dev It maps collateral => beneficiary => amount.
     */
    mapping(address collateral => mapping(address owner => uint256 amount)) public pendingReturns;

    struct Challenge {
        address challenger; // the address from which the challenge was initiated
        uint64 start; // the start of the challenge
        IPositionV1 position; // the position that was challenged
        uint256 size; // how much collateral the challenger provided
    }

    event PositionOpened(address indexed owner, address indexed position, address zchf, address collateral, uint256 price);
    event ChallengeStarted(address indexed challenger, address indexed position, uint256 size, uint256 number);
    event ChallengeAverted(address indexed position, uint256 number, uint256 size);
    event ChallengeSucceeded(address indexed position, uint256 number, uint256 bid, uint256 acquiredCollateral, uint256 challengeSize);
    event PostPonedReturn(address collateral, address indexed beneficiary, uint256 amount);

    error UnexpectedPrice();
    error InvalidPos();

    modifier validPos(address position) {
        if (zchf.getPositionParent(position) != address(this)) revert InvalidPos();
        _;
    }

    constructor(address _zchf, address _factory) {
        zchf = IFrankencoin(_zchf);
        POSITION_FACTORY = IPositionFactoryV1(_factory);
    }

    function openPositionOneWeek(
        address _collateralAddress,
        uint256 _minCollateral,
        uint256 _initialCollateral,
        uint256 _mintingMaximum,
        uint256 _expirationSeconds,
        uint64 _challengeSeconds,
        uint32 _annualInterestPPM,
        uint256 _liqPrice,
        uint32 _reservePPM
    ) public returns (address) {
        return openPosition(_collateralAddress, _minCollateral, _initialCollateral, _mintingMaximum, 7 days, _expirationSeconds, _challengeSeconds, _annualInterestPPM, _liqPrice, _reservePPM);
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
     * @param _annualInterestPPM ppm of minted amount that is paid as fee for each year of duration
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
        uint256 _initPeriodSeconds,
        uint256 _expirationSeconds,
        uint64 _challengeSeconds,
        uint32 _annualInterestPPM,
        uint256 _liqPrice,
        uint32 _reservePPM
    ) public returns (address) {
        require(_annualInterestPPM <= 1000000);
        require(CHALLENGER_REWARD <= _reservePPM && _reservePPM <= 1000000);
        require(IERC20(_collateralAddress).decimals() <= 24); // leaves 12 digits for price
        require(_initialCollateral >= _minCollateral, "must start with min col");
        require(_minCollateral * _liqPrice >= 5000 ether * 10 ** 18); // must start with at least 5000 ZCHF worth of collateral
        IPositionV1 pos = IPositionV1(
            POSITION_FACTORY.createNewPosition(msg.sender, address(zchf), _collateralAddress, _minCollateral, _mintingMaximum, _initPeriodSeconds, _expirationSeconds, _challengeSeconds, _annualInterestPPM, _liqPrice, _reservePPM)
        );
        zchf.registerPosition(address(pos));
        zchf.collectProfits(msg.sender, OPENING_FEE);
        IERC20(_collateralAddress).transferFrom(msg.sender, address(pos), _initialCollateral);

        emit PositionOpened(msg.sender, address(pos), address(zchf), _collateralAddress, _liqPrice);
        return address(pos);
    }

    /**
     * @notice Clones an existing position and immediately tries to mint the specified amount using the given collateral.
     * @dev This needs an allowance to be set on the collateral contract such that the minting hub can get the collateral.
     */
    function clone(address position, uint256 _initialCollateral, uint256 _initialMint, uint256 expiration) public validPos(position) returns (address) {
        IPositionV1 existing = IPositionV1(position);
        require(expiration <= IPositionV1(existing.original()).expiration());
        existing.reduceLimitForClone(_initialMint);
        address pos = POSITION_FACTORY.clonePosition(position);
        zchf.registerPosition(pos);
        IPositionV1(pos).initializeClone(msg.sender, existing.price(), _initialCollateral, _initialMint, expiration);
        existing.collateral().transferFrom(msg.sender, pos, _initialCollateral);

        emit PositionOpened(msg.sender, address(pos), address(zchf), address(IPositionV1(pos).collateral()), IPositionV1(pos).price());
        return address(pos);
    }

    /**
     * @notice Launch a challenge (Dutch auction) on a position
     * @param _positionAddr      address of the position we want to challenge
     * @param _collateralAmount  amount of the collateral we want to challenge
     * @param expectedPrice      position.price() to guard against the minter fruntrunning with a price change
     * @return index of the challenge in challenge-array
     */
    function challenge(address _positionAddr, uint256 _collateralAmount, uint256 expectedPrice) external validPos(_positionAddr) returns (uint256) {
        IPositionV1 position = IPositionV1(_positionAddr);
        if (position.price() != expectedPrice) revert UnexpectedPrice();
        IERC20(position.collateral()).transferFrom(msg.sender, address(this), _collateralAmount);
        uint256 pos = challenges.length;
        challenges.push(Challenge(msg.sender, uint64(block.timestamp), position, _collateralAmount));
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
        (uint256 liqPrice, uint64 phase1, uint64 phase2) = _challenge.position.challengeData(_challenge.start);
        size = _challenge.size < size ? _challenge.size : size; // cannot bid for more than the size of the challenge

        if (block.timestamp <= _challenge.start + phase1) {
            _avertChallenge(_challenge, _challengeNumber, liqPrice, size);
            emit ChallengeAverted(address(_challenge.position), _challengeNumber, size);
        } else {
            _returnChallengerCollateral(_challenge, _challengeNumber, size, postponeCollateralReturn);
            (uint256 transferredCollateral, uint256 offer) = _finishChallenge(_challenge, liqPrice, phase1, phase2, size);
            emit ChallengeSucceeded(address(_challenge.position), _challengeNumber, offer, transferredCollateral, size);
        }
    }

    function _finishChallenge(Challenge memory _challenge, uint256 liqPrice, uint64 phase1, uint64 phase2, uint256 size) internal returns (uint256, uint256) {
        // Repayments depend on what was actually minted, whereas bids depend on the available collateral
        (address owner, uint256 collateral, uint256 repayment, uint32 reservePPM) = _challenge.position.notifyChallengeSucceeded(msg.sender, size);

        // No overflow possible thanks to invariant (col * price <= limit * 10**18)
        // enforced in Position.setPrice and knowing that collateral <= col.
        uint256 offer = (_calculatePrice(_challenge.start + phase1, phase2, liqPrice) * collateral) / 10 ** 18;
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
    function _returnChallengerCollateral(Challenge memory _challenge, uint32 number, uint256 amount, bool postpone) internal {
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
    function _calculatePrice(uint64 start, uint64 phase2, uint256 liqPrice) internal view returns (uint256) {
        uint64 timeNow = uint64(block.timestamp);
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
            (uint256 liqPrice, uint64 phase1, uint64 phase2) = _challenge.position.challengeData(_challenge.start);
            return _calculatePrice(_challenge.start + phase1, phase2, liqPrice);
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
}
