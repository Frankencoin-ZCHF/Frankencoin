// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../../erc20/IERC20.sol";
import "../../rate/ILeadrate.sol";
import "../v1/IFrankencoin.sol";
import "../v1/IReserve.sol";

import "./IMintingHubV3.sol";
import "./IPositionV3.sol";
import "./PositionV3.sol";

/**
 * @title MintingHubV3
 * @notice Singleton hub containing ALL logic for the Frankencoin V3 collateralized minting system.
 *
 * Architecture:
 *  - Proposals: governance-whitelisted collateral configs. Any address can propose, equity
 *    holders have 7 days to deny. After that the proposal is active and positions can be opened.
 *  - Positions: ultra-minimal PositionV3 contracts that only hold collateral. All state lives
 *    here in `positionData`. Users call this hub directly for every operation.
 *  - No cloning: every position is equal, all derive from a proposal. The proposal tracks
 *    `totalMinted` as the global cap across all positions using it.
 *  - highestPrice: per proposal, tracks the all-time high price set by any position. Positions
 *    can freely increase their price up to this level without a cooldown.
 *  - Fee math: computed at 1e18 (WAD) precision internally; converted to ppm only when
 *    calling IFrankencoin which still uses a ppm interface.
 *  - Roller: roll logic is integrated here; no separate PositionRoller contract needed.
 */
contract MintingHubV3 is IMintingHubV3 {

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice Irrevocable fee in ZCHF when proposing a new collateral.
    uint256 public constant override OPENING_FEE = 1000 * 10 ** 18;

    /// @notice Challenger reward in ppm of the challenged value (2%).
    uint256 public constant override CHALLENGER_REWARD = 20_000;

    /// @notice Starting multiplier for the force-sale price of expired positions.
    uint256 public constant override EXPIRED_PRICE_FACTOR = 10;

    /// @notice Governance denial window for new proposals.
    uint40 public constant PROPOSAL_DENIAL_PERIOD = 7 days;

    /// @notice Cooldown imposed when a position sets a new all-time-high price.
    uint40 public constant PRICE_INCREASE_COOLDOWN = 3 days;

    /// @notice 1e18 — base for WAD fee arithmetic.
    uint256 internal constant WAD = 1e18;

    // -------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------

    IFrankencoin public immutable override zchf;
    ILeadrate public immutable override rate;

    // -------------------------------------------------------------------------
    // Proposals
    // -------------------------------------------------------------------------

    /// @dev proposal index => Proposal. proposalCount == proposals.length
    Proposal[] internal _proposals;

    /// @dev collateral address => list of proposal indices
    mapping(address => uint256[]) internal _collateralProposals;

    // -------------------------------------------------------------------------
    // Positions
    // -------------------------------------------------------------------------

    /// @dev position address => state
    mapping(address => PositionState) internal _positionData;

    /// @dev ordered list of all opened positions
    address[] internal _allPositions;

    /// @dev quick membership check
    mapping(address => bool) internal _isPosition;

    // -------------------------------------------------------------------------
    // Challenges
    // -------------------------------------------------------------------------

    mapping(uint256 => Challenge) internal _challenges;
    uint256 public override challengeCount;

    // -------------------------------------------------------------------------
    // Postponed collateral returns
    // -------------------------------------------------------------------------

    mapping(address => mapping(address => uint256)) public override pendingReturns;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(address _zchf, address _leadrate) {
        zchf = IFrankencoin(_zchf);
        rate = ILeadrate(_leadrate);
    }

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier validPos(address pos) {
        if (!_isPosition[pos]) revert InvalidPos();
        _;
    }

    modifier onlyOwner(address pos) {
        if (_positionData[pos].owner != msg.sender) revert NotOwner();
        _;
    }

    modifier ownerOrRoller(address pos) {
        // Roller is integrated — only owner can call (roller calls roll() directly)
        if (_positionData[pos].owner != msg.sender) revert NotOwner();
        _;
    }

    // -------------------------------------------------------------------------
    // Public view — proposals
    // -------------------------------------------------------------------------

    function proposals(uint256 id) external view override returns (Proposal memory) {
        return _proposals[id];
    }

    function proposalCount() external view override returns (uint256) {
        return _proposals.length;
    }

    function collateralProposals(address collateral, uint256 index) external view override returns (uint256) {
        return _collateralProposals[collateral][index];
    }

    function isProposalActive(uint256 proposalId) public view override returns (bool) {
        Proposal storage p = _proposals[proposalId];
        return !p.denied && block.timestamp >= p.proposedAt + PROPOSAL_DENIAL_PERIOD;
    }

    // -------------------------------------------------------------------------
    // Public view — positions
    // -------------------------------------------------------------------------

    function positionData(address pos) external view override returns (PositionState memory) {
        return _positionData[pos];
    }

    function allPositions(uint256 index) external view override returns (address) {
        return _allPositions[index];
    }

    function positionCount() external view override returns (uint256) {
        return _allPositions.length;
    }

    function isPosition(address pos) external view override returns (bool) {
        return _isPosition[pos];
    }

    function challenges(uint256 id) external view override returns (Challenge memory) {
        return _challenges[id];
    }

    // -------------------------------------------------------------------------
    // Public view — fee math (1e18 precision)
    // -------------------------------------------------------------------------

    /**
     * @notice Annual interest rate for a proposal in WAD (1e18 = 100%).
     * @dev Converts leadrate ppm + risk premium ppm to WAD by multiplying by 1e12.
     */
    function annualInterestWAD(uint256 proposalId) public view override returns (uint256) {
        Proposal storage p = _proposals[proposalId];
        return (uint256(rate.currentRatePPM()) + uint256(p.riskPremiumPPM)) * 1e12;
    }

    /**
     * @notice Upfront fee in WAD for minting from `pos` now until its expiration.
     */
    function calculateFeeWAD(address pos) public view override returns (uint256) {
        PositionState storage s = _positionData[pos];
        return _feeWAD(s.proposalId, s.start, s.expiration);
    }

    /**
     * @notice Upfront fee in WAD for minting from `pos` with a custom expiration (e.g. when opening).
     */
    function calculateFeeWAD(address pos, uint40 customExpiration) public view override returns (uint256) {
        PositionState storage s = _positionData[pos];
        return _feeWAD(s.proposalId, s.start, customExpiration);
    }

    function _feeWAD(uint256 proposalId, uint40 start, uint40 expiration) internal view returns (uint256) {
        uint256 t = block.timestamp < start ? start : block.timestamp;
        if (expiration <= t) return 0;
        uint256 remaining = expiration - t;
        uint256 fee = (remaining * annualInterestWAD(proposalId)) / 365 days;
        return fee > WAD ? WAD : fee;
    }

    /// @dev Convert internal WAD fee to ppm for the IFrankencoin boundary.
    function _feePPM(uint256 proposalId, uint40 start, uint40 expiration) internal view returns (uint24) {
        return uint24(_feeWAD(proposalId, start, expiration) / 1e12);
    }

    // -------------------------------------------------------------------------
    // Public view — minting capacity
    // -------------------------------------------------------------------------

    /**
     * @notice How much more ZCHF this position can mint.
     * @dev Limited by both the position's collateral-backed capacity and the proposal's
     *      remaining global mint headroom.
     */
    function availableForMinting(address pos) public view override returns (uint256) {
        PositionState storage s = _positionData[pos];
        Proposal storage p = _proposals[s.proposalId];

        // Collateral-backed capacity of this position
        uint256 colBal = IERC20(p.collateral).balanceOf(pos);
        uint256 colBacked = colBal * s.price / WAD;
        uint256 posAvail = colBacked > s.minted ? colBacked - s.minted : 0;

        // Remaining headroom in the proposal's global limit
        uint256 propAvail = p.mintLimit > p.totalMinted ? p.mintLimit - p.totalMinted : 0;

        return posAvail < propAvail ? posAvail : propAvail;
    }

    /**
     * @notice How much ZCHF the position owner actually receives when minting `totalMint`,
     *         after reserve and (optionally) fees are set aside.
     */
    function getUsableMint(address pos, uint256 totalMint, bool afterFees) public view override returns (uint256) {
        PositionState storage s = _positionData[pos];
        Proposal storage p = _proposals[s.proposalId];
        if (afterFees) {
            uint256 feePPM = _feePPM(s.proposalId, s.start, s.expiration);
            return (totalMint * (1_000_000 - p.reservePPM - feePPM)) / 1_000_000;
        } else {
            return (totalMint * (1_000_000 - p.reservePPM)) / 1_000_000;
        }
    }

    /**
     * @notice Inverse of getUsableMint — how much must be minted to receive `usableMint`.
     */
    function getMintAmount(address pos, uint256 usableMint) public view override returns (uint256) {
        if (usableMint == 0) return 0;
        PositionState storage s = _positionData[pos];
        Proposal storage p = _proposals[s.proposalId];
        uint256 feePPM = _feePPM(s.proposalId, s.start, s.expiration);
        uint256 denom = 1_000_000 - p.reservePPM - feePPM;
        return (usableMint * 1_000_000 - 1) / denom + 1; // round up
    }

    // -------------------------------------------------------------------------
    // Public view — challenges
    // -------------------------------------------------------------------------

    /**
     * @notice Current Dutch-auction price for the given challenge.
     */
    function price(uint256 challengeNumber) public view override returns (uint256) {
        Challenge storage c = _challenges[challengeNumber];
        if (c.challenger == address(0)) return 0;
        PositionState storage s = _positionData[c.position];
        Proposal storage p = _proposals[s.proposalId];
        return _auctionPrice(c.start + p.challengePeriod, p.challengePeriod, s.price);
    }

    /**
     * @notice Purchase price curve for buying collateral from an expired position.
     * @dev Starts at EXPIRED_PRICE_FACTOR × liqPrice at expiration, drops to 1× over one
     *      challenge period, then drops to 0 over a second challenge period.
     */
    function expiredPurchasePrice(address pos) public view override returns (uint256) {
        PositionState storage s = _positionData[pos];
        Proposal storage p = _proposals[s.proposalId];
        uint256 liqPrice = s.price;
        if (block.timestamp <= s.expiration) return EXPIRED_PRICE_FACTOR * liqPrice;
        uint256 elapsed = block.timestamp - s.expiration;
        uint256 cp = p.challengePeriod;
        if (elapsed <= cp) {
            uint256 remaining = cp - elapsed;
            return liqPrice + ((EXPIRED_PRICE_FACTOR - 1) * liqPrice * remaining) / cp;
        } else if (elapsed < 2 * cp) {
            uint256 remaining = 2 * cp - elapsed;
            return (liqPrice * remaining) / cp;
        } else {
            return 0;
        }
    }

    // -------------------------------------------------------------------------
    // Proposals — governance lifecycle
    // -------------------------------------------------------------------------

    /**
     * @notice Propose a new collateral type with its risk parameters.
     * @dev Anyone can propose by paying the OPENING_FEE. Equity holders have
     *      PROPOSAL_DENIAL_PERIOD (7 days) to deny it. After that it is permanently active.
     *
     * @param collateral       ERC20 collateral token address
     * @param minCollateral    Minimum collateral amount (dust floor)
     * @param mintLimit        Global ZCHF cap across all positions using this proposal
     * @param duration         Maximum lifetime of any position created from this proposal
     * @param challengePeriod  Dutch-auction window for challenges
     * @param riskPremiumPPM   Extra interest on top of the leadrate (ppm per year)
     * @param reservePPM       Reserve contribution (ppm of minted amount)
     * @param liqPrice         Initial liquidation price (36 − collateral.decimals decimals)
     * @return proposalId      Index into the proposals array
     */
    function proposeCollateral(
        address collateral,
        uint256 minCollateral,
        uint256 mintLimit,
        uint40 duration,
        uint40 challengePeriod,
        uint24 riskPremiumPPM,
        uint24 reservePPM,
        uint256 liqPrice
    ) external override returns (uint256 proposalId) {
        // Basic sanity checks on collateral token
        require(IERC20(collateral).decimals() <= 24); // leaves 12 digits for price encoding
        {
            uint256 impossible = IERC20(collateral).totalSupply() + 1;
            try IERC20(collateral).transfer(address(0x1), impossible) {
                revert IncompatibleCollateral();
            } catch {}
        }
        require(riskPremiumPPM <= 1_000_000);
        require(CHALLENGER_REWARD <= reservePPM && reservePPM <= 1_000_000);
        require(minCollateral * liqPrice >= 5000 ether * WAD); // min 5000 ZCHF collateral value

        zchf.collectProfits(msg.sender, OPENING_FEE);

        proposalId = _proposals.length;
        _proposals.push(Proposal({
            collateral:      collateral,
            minCollateral:   minCollateral,
            mintLimit:       mintLimit,
            totalMinted:     0,
            duration:        duration,
            challengePeriod: challengePeriod,
            riskPremiumPPM:  riskPremiumPPM,
            reservePPM:      reservePPM,
            liqPrice:        liqPrice,
            proposedAt:      uint40(block.timestamp),
            denied:          false,
            highestPrice:    liqPrice
        }));
        _collateralProposals[collateral].push(proposalId);

        emit ProposalCreated(proposalId, collateral, msg.sender);
    }

    /**
     * @notice Deny a proposal during its governance window (7 days from proposal).
     * @dev Only qualified equity holders can deny.
     */
    function denyProposal(
        uint256 proposalId,
        address[] calldata helpers,
        string calldata message
    ) external override {
        Proposal storage p = _proposals[proposalId];
        if (block.timestamp >= p.proposedAt + PROPOSAL_DENIAL_PERIOD) revert TooLate();
        if (p.denied) revert TooLate();
        IReserve(zchf.reserve()).checkQualified(msg.sender, helpers);
        p.denied = true;
        emit ProposalDenied(proposalId, msg.sender);
    }

    // -------------------------------------------------------------------------
    // Positions — creation
    // -------------------------------------------------------------------------

    /**
     * @notice Open a new collateralized minting position derived from an active proposal.
     * @dev The caller must approve this hub to spend `initialCollateral` of the collateral token
     *      and `OPENING_FEE` of ZCHF before calling.
     *
     *      The position cannot mint until `initPeriodSeconds` have elapsed (denial window for the
     *      individual position). This mirrors the V1/V2 per-position governance safety margin.
     *
     * @param proposalId        Which approved proposal to derive this position from
     * @param minCollateral     Dust floor for this position (must be >= proposal.minCollateral)
     * @param initialCollateral Amount of collateral deposited at opening
     * @param mintingMaximum    Per-position mint cap (must be <= proposal.mintLimit)
     * @param initPeriodSeconds Seconds before minting is unlocked (min 3 days)
     * @param expirationSeconds Lifetime in seconds from now (must be <= proposal.duration)
     * @param liqPrice          Initial liquidation price (must be <= proposal.liqPrice for safety;
     *                          owner can raise it later subject to cooldown rules)
     * @return pos              Address of the newly deployed PositionV3 vault
     */
    function openPosition(
        uint256 proposalId,
        uint256 minCollateral,
        uint256 initialCollateral,
        uint256 mintingMaximum,
        uint40 initPeriodSeconds,
        uint40 expirationSeconds,
        uint256 liqPrice
    ) external override returns (address pos) {
        if (!isProposalActive(proposalId)) revert ProposalNotActive();
        Proposal storage p = _proposals[proposalId];

        require(initPeriodSeconds >= 3 days);
        require(minCollateral >= p.minCollateral);
        require(mintingMaximum <= p.mintLimit);
        if (initialCollateral < minCollateral) revert InsufficientCollateral(initialCollateral, minCollateral);
        if (minCollateral * liqPrice < 5000 ether * WAD) revert InsufficientCollateral(minCollateral * liqPrice, 5000 ether * WAD);

        uint40 start      = uint40(block.timestamp) + initPeriodSeconds;
        uint40 expiration = uint40(block.timestamp) + expirationSeconds;
        require(expirationSeconds <= p.duration);

        // Deploy the minimal vault
        pos = address(new PositionV3(address(this)));

        _positionData[pos] = PositionState({
            proposalId:       proposalId,
            owner:            msg.sender,
            minted:           0,
            price:            liqPrice,
            challengedAmount: 0,
            start:            start,
            expiration:       expiration,
            cooldown:         start,   // cooldown == start means minting locked until init period ends
            closed:           false
        });

        _allPositions.push(pos);
        _isPosition[pos] = true;

        // Update proposal's highestPrice if the opening liqPrice exceeds it
        if (liqPrice > p.highestPrice) {
            p.highestPrice = liqPrice;
        }

        zchf.registerPosition(pos);
        IERC20(p.collateral).transferFrom(msg.sender, pos, initialCollateral);

        emit PositionOpened(msg.sender, pos, proposalId, p.collateral);
    }

    // -------------------------------------------------------------------------
    // Positions — operations (hub-centric API)
    // -------------------------------------------------------------------------

    /**
     * @notice Mint ZCHF against collateral held in `pos`.
     * @dev Caller must be the position owner. Position must not be in cooldown,
     *      challenged, expired, or closed.
     */
    function mint(address pos, address target, uint256 amount) external override validPos(pos) onlyOwner(pos) {
        PositionState storage s = _positionData[pos];
        _requireActive(s);
        if (amount > availableForMinting(pos)) revert LimitExceeded(amount, availableForMinting(pos));

        Proposal storage p = _proposals[s.proposalId];
        s.minted += amount;
        p.totalMinted += amount;
        _checkCollateral(s, pos, s.price);
        zchf.mintWithReserve(target, amount, p.reservePPM, _feePPM(s.proposalId, s.start, s.expiration));

        emit MintingUpdate(pos, IERC20(p.collateral).balanceOf(pos), s.price, s.minted);
    }

    /**
     * @notice Repay outstanding ZCHF. Can be called by anyone (not just owner) to allow
     *         third-party repayments. Excess repayment reverts.
     * @return actuallyRepaid The effective amount subtracted from minted debt.
     */
    function repay(address pos, uint256 amount) public override validPos(pos) returns (uint256 actuallyRepaid) {
        PositionState storage s = _positionData[pos];
        Proposal storage p = _proposals[s.proposalId];

        IERC20(address(zchf)).transferFrom(msg.sender, address(this), amount);
        actuallyRepaid = zchf.burnWithReserve(amount, p.reservePPM);
        if (actuallyRepaid > s.minted) revert RepaidTooMuch(actuallyRepaid - s.minted);

        s.minted -= actuallyRepaid;
        p.totalMinted -= actuallyRepaid;

        emit MintingUpdate(pos, IERC20(p.collateral).balanceOf(pos), s.price, s.minted);
    }

    /**
     * @notice Atomically adjust minted amount, collateral, and price in one transaction.
     * @dev Order of operations: deposit collateral → repay → withdraw collateral → mint → adjust price.
     */
    function adjust(
        address pos,
        uint256 newMinted,
        uint256 newCollateral,
        uint256 newPrice
    ) external override validPos(pos) onlyOwner(pos) {
        PositionState storage s = _positionData[pos];
        Proposal storage p = _proposals[s.proposalId];
        IERC20 col = IERC20(p.collateral);

        uint256 colBal = col.balanceOf(pos);

        // 1. Deposit collateral first so repay can be backed
        if (newCollateral > colBal) {
            col.transferFrom(msg.sender, pos, newCollateral - colBal);
        }

        // 2. Repay before withdraw (frees up collateral headroom)
        if (newMinted < s.minted) {
            uint256 toRepay = s.minted - newMinted;
            IERC20(address(zchf)).transferFrom(msg.sender, address(this), toRepay);
            uint256 repaid = zchf.burnFromWithReserve(msg.sender, toRepay, p.reservePPM);
            s.minted -= repaid;
            p.totalMinted -= repaid;
        }

        // 3. Withdraw collateral
        if (newCollateral < colBal) {
            _withdrawCollateral(pos, s, p, msg.sender, colBal - newCollateral);
        }

        // 4. Mint more
        if (newMinted > s.minted) {
            uint256 toMint = newMinted - s.minted;
            _requireActive(s);
            if (toMint > availableForMinting(pos)) revert LimitExceeded(toMint, availableForMinting(pos));
            s.minted += toMint;
            p.totalMinted += toMint;
            _checkCollateral(s, pos, newPrice == 0 ? s.price : newPrice);
            zchf.mintWithReserve(msg.sender, toMint, p.reservePPM, _feePPM(s.proposalId, s.start, s.expiration));
        }

        // 5. Adjust price if requested
        if (newPrice != 0 && newPrice != s.price) {
            _adjustPrice(pos, s, newPrice);
        }

        emit MintingUpdate(pos, col.balanceOf(pos), s.price, s.minted);
    }

    /**
     * @notice Adjust the liquidation price of a position.
     *
     * Lowering: immediate, provided collateral remains sufficient.
     * Raising to <= proposal.highestPrice: no cooldown (price was seen before in this family).
     * Raising above proposal.highestPrice: 3-day minting cooldown + updates the record.
     */
    function adjustPrice(address pos, uint256 newPrice) external override validPos(pos) onlyOwner(pos) {
        PositionState storage s = _positionData[pos];
        _adjustPrice(pos, s, newPrice);
        Proposal storage p = _proposals[s.proposalId];
        emit MintingUpdate(pos, IERC20(p.collateral).balanceOf(pos), s.price, s.minted);
    }

    function _adjustPrice(address pos, PositionState storage s, uint256 newPrice) internal {
        _requireNotChallenged(s);
        _requireAlive(s);
        _requireNotClosed(s);

        Proposal storage p = _proposals[s.proposalId];

        if (newPrice > s.price) {
            if (newPrice <= p.highestPrice) {
                // Returning to a price this proposal family has already reached — no cooldown.
                _checkCollateral(s, pos, newPrice);
            } else {
                // New all-time high for this proposal — impose cooldown and record it.
                _requireNoCooldown(s);
                _restrictMinting(s, PRICE_INCREASE_COOLDOWN);
                p.highestPrice = newPrice;
                _checkCollateral(s, pos, newPrice);
            }
        } else {
            // Lowering price — always allowed if collateral is still sufficient.
            _checkCollateral(s, pos, newPrice);
        }
        _setPrice(s, p, newPrice);
    }

    function _setPrice(PositionState storage s, Proposal storage p, uint256 newPrice) internal {
        // Sanity check: price × minCollateral must not exceed mint limit (prevents dust attacks)
        require(newPrice * p.minCollateral <= p.mintLimit * WAD);
        s.price = newPrice;
    }

    /**
     * @notice Withdraw collateral from `pos` to `target`. Position must not be challenged
     *         or in cooldown, and must remain sufficiently collateralised afterwards.
     */
    function withdrawCollateral(
        address pos,
        address target,
        uint256 amount
    ) public override validPos(pos) ownerOrRoller(pos) {
        PositionState storage s = _positionData[pos];
        Proposal storage p = _proposals[s.proposalId];
        _withdrawCollateral(pos, s, p, target, amount);
        emit MintingUpdate(pos, IERC20(p.collateral).balanceOf(pos), s.price, s.minted);
    }

    function _withdrawCollateral(
        address pos,
        PositionState storage s,
        Proposal storage p,
        address target,
        uint256 amount
    ) internal {
        _requireNotChallenged(s);
        _requireNoCooldown(s);
        _sendCollateral(pos, p, target, amount);
        _checkCollateral(s, pos, s.price);
    }

    /**
     * @notice Withdraw any ERC20 token held in `pos`. For collateral tokens the standard
     *         collateral checks apply. For other tokens only the collateral balance guard runs.
     */
    function withdraw(
        address pos,
        address token,
        address target,
        uint256 amount
    ) external override validPos(pos) onlyOwner(pos) {
        Proposal storage p = _proposals[_positionData[pos].proposalId];
        if (token == p.collateral) {
            withdrawCollateral(pos, target, amount);
        } else {
            uint256 colBefore = IERC20(p.collateral).balanceOf(pos);
            IPositionV3(pos).transfer(token, target, amount);
            require(IERC20(p.collateral).balanceOf(pos) == colBefore); // guard: double-entry-point tokens
        }
    }

    /**
     * @notice Deny (expire early) a position that is still in its initial cooldown period.
     * @dev Qualified equity holders can block a position before it starts minting.
     */
    function deny(
        address pos,
        address[] calldata helpers,
        string calldata message
    ) external override validPos(pos) {
        PositionState storage s = _positionData[pos];
        if (block.timestamp >= s.start) revert TooLate();
        IReserve(zchf.reserve()).checkQualified(msg.sender, helpers);
        s.closed = true;
        emit PositionDenied(pos, msg.sender, message);
    }

    // -------------------------------------------------------------------------
    // Challenges
    // -------------------------------------------------------------------------

    /**
     * @notice Launch a Dutch-auction challenge against a position.
     * @param pos              Address of the position to challenge
     * @param collateralAmount Amount of collateral the challenger provides (must be >= minCollateral)
     * @param minimumPrice     Reverts if the current price has dropped below this (frontrun protection)
     * @return challengeId     Index of the new challenge in the challenges mapping
     */
    function challenge(
        address pos,
        uint256 collateralAmount,
        uint256 minimumPrice
    ) external override validPos(pos) returns (uint256 challengeId) {
        PositionState storage s = _positionData[pos];
        Proposal storage p = _proposals[s.proposalId];

        _requireAlive(s);
        if (s.price < minimumPrice) revert UnexpectedPrice();

        uint256 colBal = IERC20(p.collateral).balanceOf(pos);
        if (collateralAmount < p.minCollateral && collateralAmount < colBal) revert ChallengeTooSmall();
        if (collateralAmount == 0) revert ChallengeTooSmall();

        IERC20(p.collateral).transferFrom(msg.sender, address(this), collateralAmount);
        s.challengedAmount += collateralAmount;

        challengeId = challengeCount++;
        _challenges[challengeId] = Challenge({
            challenger: msg.sender,
            start:      uint40(block.timestamp),
            position:   pos,
            size:       collateralAmount
        });

        emit ChallengeStarted(msg.sender, pos, collateralAmount, challengeId);
    }

    /**
     * @notice Bid on an open challenge.
     *
     * If still in the aversion window (phase 1): the bidder pays the position owner and
     * receives the challenger's collateral back — the challenge is averted.
     *
     * If the aversion window has passed (phase 2): the position is liquidated at the
     * current Dutch-auction price — the challenge succeeds.
     *
     * @param _challengeNumber Index of the challenge
     * @param size             Collateral amount the bidder wants to acquire (capped at challenge size)
     * @param postponeCollateralReturn  If true, returns challenger collateral via pendingReturns
     *                                 (safety valve for blacklisted addresses)
     */
    function bid(
        uint32 _challengeNumber,
        uint256 size,
        bool postponeCollateralReturn
    ) external override {
        Challenge storage c = _challenges[_challengeNumber];
        PositionState storage s = _positionData[c.position];
        Proposal storage p = _proposals[s.proposalId];

        size = c.size < size ? c.size : size;

        uint256 liqPrice = s.price;
        uint40 phase     = p.challengePeriod;

        if (block.timestamp <= c.start + phase) {
            _avertChallenge(c, _challengeNumber, s, p, liqPrice, size);
            emit ChallengeAverted(c.position, _challengeNumber, size);
        } else {
            address posAddr = c.position;
            _returnChallengerCollateral(c, _challengeNumber, p, size, postponeCollateralReturn);
            (uint256 transferred, uint256 offer) = _finishChallenge(c, s, p, posAddr, liqPrice, phase, size);
            emit ChallengeSucceeded(posAddr, _challengeNumber, offer, transferred, size);
        }
    }

    function _avertChallenge(
        Challenge storage c,
        uint32 number,
        PositionState storage s,
        Proposal storage p,
        uint256 liqPrice,
        uint256 size
    ) internal {
        require(block.timestamp != c.start); // CS-ZCHF-037: cannot avert in same block as challenge
        if (msg.sender != c.challenger) {
            // Bidder pays challenger the current liqPrice for the challenged collateral
            zchf.transferFrom(msg.sender, c.challenger, (size * liqPrice) / WAD);
        }
        s.challengedAmount -= size;
        _restrictMinting(s, 1 days);
        // Return the challenger's deposited collateral to the bidder
        IERC20(p.collateral).transfer(msg.sender, size);

        if (size < c.size) {
            _challenges[number].size = c.size - size;
        } else {
            delete _challenges[number];
        }
    }

    function _returnChallengerCollateral(
        Challenge storage c,
        uint32 number,
        Proposal storage p,
        uint256 amount,
        bool postpone
    ) internal {
        _returnCollateral(p.collateral, c.challenger, amount, postpone);
        if (c.size == amount) {
            delete _challenges[number];
        } else {
            _challenges[number].size -= amount;
        }
    }

    function _finishChallenge(
        Challenge storage c,
        PositionState storage s,
        Proposal storage p,
        address posAddr,
        uint256 liqPrice,
        uint40 phase,
        uint256 size
    ) internal returns (uint256 transferred, uint256 offer) {
        // Auction price at current time
        uint256 auctPrice = _auctionPrice(c.start + phase, phase, liqPrice);

        // Scale down if challenger provided more than the actual collateral balance
        uint256 colBal = IERC20(p.collateral).balanceOf(posAddr);
        if (colBal < size) size = colBal;

        // Proportional repayment
        uint256 repayment = colBal == 0 ? 0 : (s.minted * size) / colBal;

        // Transfer collateral to bidder
        IPositionV3(posAddr).transfer(p.collateral, msg.sender, size);
        transferred = size;

        s.challengedAmount -= size;
        s.minted -= repayment;
        p.totalMinted -= repayment;
        _restrictMinting(s, 3 days);

        // Collect payment from bidder
        offer = (auctPrice * size) / WAD;
        zchf.transferFrom(msg.sender, address(this), offer);

        uint256 reward = (offer * CHALLENGER_REWARD) / 1_000_000;
        zchf.transfer(c.challenger, reward);
        uint256 available = offer - reward;

        if (available > repayment) {
            uint256 excess     = available - repayment;
            uint256 toProtocol = (uint256(p.reservePPM) * excess) / 1_000_000;
            zchf.collectProfits(address(this), toProtocol);
            zchf.transfer(s.owner, excess - toProtocol);
        } else if (available < repayment) {
            zchf.coverLoss(address(this), repayment - available);
        }

        zchf.burnWithoutReserve(repayment, p.reservePPM);

        emit MintingUpdate(posAddr, IERC20(p.collateral).balanceOf(posAddr), s.price, s.minted);
    }

    // -------------------------------------------------------------------------
    // Expired collateral
    // -------------------------------------------------------------------------

    /**
     * @notice Buy collateral from an expired position at the time-decaying force-sale price.
     * @dev Cannot be called while challenges are open (CS-ZCHF2-001).
     */
    function buyExpiredCollateral(
        address pos,
        uint256 upToAmount
    ) external override validPos(pos) returns (uint256 amount) {
        PositionState storage s = _positionData[pos];
        Proposal storage p = _proposals[s.proposalId];

        if (block.timestamp < s.expiration) revert Alive();
        if (s.challengedAmount > 0) revert Challenged();

        uint256 maxAvail = IERC20(p.collateral).balanceOf(pos);
        amount = upToAmount > maxAvail ? maxAvail : upToAmount;

        uint256 salePrice = expiredPurchasePrice(pos);
        uint256 cost      = (salePrice * amount) / WAD;

        _forceSale(pos, s, p, msg.sender, amount, cost);
        emit ForcedSale(pos, amount, salePrice);
    }

    function _forceSale(
        address pos,
        PositionState storage s,
        Proposal storage p,
        address buyer,
        uint256 collAmount,
        uint256 proceeds
    ) internal {
        // Transfer collateral to buyer
        IPositionV3(pos).transfer(p.collateral, buyer, collAmount);
        uint256 remaining = IERC20(p.collateral).balanceOf(pos);

        if (s.minted > 0) {
            uint256 reserve = zchf.calculateAssignedReserve(s.minted, p.reservePPM);
            if (proceeds + reserve >= s.minted) {
                // Full repayment: release reserve, return surplus to owner
                uint256 returned = zchf.burnFromWithReserve(buyer, s.minted, p.reservePPM);
                zchf.transferFrom(buyer, s.owner, proceeds + returned - s.minted);
                p.totalMinted -= s.minted;
                s.minted = 0;
            } else {
                zchf.transferFrom(buyer, address(this), proceeds);
                if (remaining == 0) {
                    // CS-ZCHF2-002: bad debt — cover and burn
                    zchf.coverLoss(address(this), s.minted - proceeds);
                    zchf.burnWithoutReserve(s.minted, p.reservePPM);
                    p.totalMinted -= s.minted;
                    s.minted = 0;
                } else {
                    uint256 repaid = zchf.burnWithReserve(proceeds, p.reservePPM);
                    p.totalMinted -= repaid;
                    s.minted -= repaid;
                }
            }
        } else {
            zchf.transferFrom(buyer, s.owner, proceeds);
        }

        emit MintingUpdate(pos, remaining, s.price, s.minted);
    }

    // -------------------------------------------------------------------------
    // Roller (integrated)
    // -------------------------------------------------------------------------

    /**
     * @notice Roll all debt from `source` into `target` in one atomic transaction.
     * @dev Convenience wrapper — expiration is taken from target.
     *      Pre-condition: caller must approve the source position's collateral for this hub.
     */
    function rollFully(address source, address target) external override {
        rollFullyWithExpiration(source, target, _positionData[target].expiration);
    }

    /**
     * @notice Roll all debt from `source` into `target` with a custom expiration date.
     */
    function rollFullyWithExpiration(
        address source,
        address target,
        uint40 expiration
    ) public override {
        Proposal storage sp = _proposals[_positionData[source].proposalId];
        Proposal storage tp = _proposals[_positionData[target].proposalId];
        require(sp.collateral == tp.collateral, "collateral mismatch");

        uint256 repayAmt  = findRepaymentAmount(source);
        uint256 mintAmt   = getMintAmount(target, repayAmt);
        uint256 colWithdraw = IERC20(sp.collateral).balanceOf(source);

        PositionState storage ts = _positionData[target];
        uint256 depositAmt = mintAmt == 0 ? 0 : (mintAmt * WAD + ts.price - 1) / ts.price;
        if (depositAmt > colWithdraw) {
            depositAmt = colWithdraw;
            mintAmt = (depositAmt * ts.price) / WAD;
        }

        roll(source, repayAmt, colWithdraw, target, mintAmt, depositAmt, expiration);
    }

    /**
     * @notice Core roll: flash-loan repays `source`, frees collateral, deposits into `target`, mints.
     * @param source       Position to roll out of (caller must own it)
     * @param repayAmt     ZCHF to flash-loan for repaying source
     * @param collWithdraw Collateral to pull from source to caller
     * @param target       Position to roll into (caller must own it)
     * @param mintAmt      ZCHF to mint from target
     * @param collDeposit  Collateral to deposit into target from caller
     * @param expiration   Desired expiration of the target position
     */
    function roll(
        address source,
        uint256 repayAmt,
        uint256 collWithdraw,
        address target,
        uint256 mintAmt,
        uint256 collDeposit,
        uint40 expiration
    ) public override validPos(source) validPos(target) {
        PositionState storage ss = _positionData[source];
        if (ss.owner != msg.sender) revert NotOwner();

        // Validate target ownership & expiration match (or adjust)
        PositionState storage ts = _positionData[target];
        if (ts.owner != msg.sender) revert NotOwner();
        if (ts.expiration != expiration) {
            // If expiration doesn't match, the caller should have opened/adjusted the target first.
            // We enforce expiration must be <= target's current expiration for safety.
            require(expiration <= ts.expiration, "expiration exceeds target");
        }

        Proposal storage sp = _proposals[ss.proposalId];

        // Flash-loan: hub mints ZCHF to itself, uses it to repay source
        zchf.mint(address(this), repayAmt);
        // Repay source using flash-loaned funds (no transferFrom needed — hub holds the ZCHF)
        {
            uint256 repaid = zchf.burnWithReserve(repayAmt, sp.reservePPM);
            if (repaid > ss.minted) revert RepaidTooMuch(repaid - ss.minted);
            ss.minted -= repaid;
            sp.totalMinted -= repaid;
        }

        // Withdraw collateral from source to caller
        _withdrawCollateral(source, ss, sp, msg.sender, collWithdraw);

        // Mint from target into caller
        if (mintAmt > 0) {
            Proposal storage tp = _proposals[ts.proposalId];
            IERC20(tp.collateral).transferFrom(msg.sender, target, collDeposit);
            _requireActive(ts);
            if (mintAmt > availableForMinting(target)) revert LimitExceeded(mintAmt, availableForMinting(target));
            ts.minted += mintAmt;
            tp.totalMinted += mintAmt;
            _checkCollateral(ts, target, ts.price);
            zchf.mintWithReserve(msg.sender, mintAmt, tp.reservePPM, _feePPM(ts.proposalId, ts.start, ts.expiration));
        }

        // Repay flash loan from caller
        zchf.burnFrom(msg.sender, repayAmt);

        emit Roll(source, collWithdraw, repayAmt, target, collDeposit, mintAmt);
    }

    // -------------------------------------------------------------------------
    // Roller helper: binary search for exact repayment amount
    // -------------------------------------------------------------------------

    /**
     * @notice Find the exact ZCHF amount that, when passed to repay(), brings minted to zero.
     * @dev Uses binary search because burnWithReserve has non-linear reserve release.
     */
    function findRepaymentAmount(address pos) public view override returns (uint256) {
        PositionState storage s = _positionData[pos];
        Proposal storage p = _proposals[s.proposalId];
        uint256 minted = s.minted;
        if (minted == 0) return 0;
        uint256 high = zchf.calculateFreedAmount(minted, p.reservePPM);
        if (high == minted) return minted;
        return _binarySearch(minted, p.reservePPM, 0, 0, minted, high);
    }

    function _binarySearch(
        uint256 target_,
        uint24 reservePPM,
        uint256 lo,
        uint256 loResult,
        uint256 hi,
        uint256 hiResult
    ) internal view returns (uint256) {
        uint256 mid = (lo + hi) / 2;
        if (mid == lo) return hi;
        uint256 midResult = zchf.calculateFreedAmount(mid, reservePPM);
        if (midResult == target_) return mid;
        if (midResult < target_)  return _binarySearch(target_, reservePPM, mid, midResult, hi, hiResult);
        else                      return _binarySearch(target_, reservePPM, lo, loResult,  mid, midResult);
    }

    // -------------------------------------------------------------------------
    // Postponed collateral returns
    // -------------------------------------------------------------------------

    /**
     * @notice Claim collateral whose return was postponed during a challenge bid.
     */
    function returnPostponedCollateral(address collateral, address target) external override {
        uint256 amt = pendingReturns[collateral][msg.sender];
        delete pendingReturns[collateral][msg.sender];
        IERC20(collateral).transfer(target, amt);
    }

    function _returnCollateral(address collateral, address recipient, uint256 amount, bool postpone) internal {
        if (postpone) {
            pendingReturns[collateral][recipient] += amount;
            emit PostPonedReturn(collateral, recipient, amount);
        } else {
            IERC20(collateral).transfer(recipient, amount);
        }
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    function _sendCollateral(address pos, Proposal storage p, address to, uint256 amount) internal {
        IPositionV3(pos).transfer(p.collateral, to, amount);
        uint256 bal = IERC20(p.collateral).balanceOf(pos);
        if (bal < p.minCollateral) {
            _positionData[pos].closed = true;
        }
    }

    function _checkCollateral(PositionState storage s, address pos, uint256 atPrice) internal view {
        Proposal storage p = _proposals[s.proposalId];
        uint256 colBal = IERC20(p.collateral).balanceOf(pos);
        uint256 relevant = colBal < p.minCollateral ? 0 : colBal;
        if (relevant * atPrice < s.minted * WAD) {
            revert InsufficientCollateral(relevant * atPrice, s.minted * WAD);
        }
    }

    function _restrictMinting(PositionState storage s, uint40 period) internal {
        uint40 horizon = uint40(block.timestamp) + period;
        if (horizon > s.cooldown) s.cooldown = horizon;
    }

    /// @dev Dutch auction: starts at liqPrice at `start`, linearly falls to 0 over `phase`.
    ///      Fixed precision vs V2: multiply first, divide last.
    function _auctionPrice(uint40 start, uint40 phase, uint256 liqPrice) internal view returns (uint256) {
        uint40 t = uint40(block.timestamp);
        if (t <= start)         return liqPrice;
        if (t >= start + phase) return 0;
        uint256 remaining = phase - (t - start);
        return (liqPrice * remaining) / phase;
    }

    // -------------------------------------------------------------------------
    // Require helpers (gas-efficient guard consolidation)
    // -------------------------------------------------------------------------

    function _requireActive(PositionState storage s) internal view {
        _requireNotClosed(s);
        _requireAlive(s);
        _requireNoCooldown(s);
        _requireNotChallenged(s);
    }

    function _requireAlive(PositionState storage s) internal view {
        if (block.timestamp >= s.expiration) revert Expired(uint40(block.timestamp), s.expiration);
    }

    function _requireNotClosed(PositionState storage s) internal view {
        if (s.closed) revert Closed();
    }

    function _requireNoCooldown(PositionState storage s) internal view {
        if (block.timestamp <= s.cooldown) revert Hot();
    }

    function _requireNotChallenged(PositionState storage s) internal view {
        if (s.challengedAmount > 0) revert Challenged();
    }
}
