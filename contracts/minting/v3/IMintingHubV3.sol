// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../../erc20/IERC20.sol";
import "../../rate/ILeadrate.sol";
import "../v1/IFrankencoin.sol";

interface IMintingHubV3 {
    // -------------------------------------------------------------------------
    // Structs
    // -------------------------------------------------------------------------

    struct Proposal {
        address collateral;
        uint256 minCollateral;
        uint256 mintLimit; // global cap across ALL positions using this proposal
        uint256 totalMinted; // currently minted across all positions using this proposal
        uint40 duration;
        uint40 challengePeriod;
        uint24 riskPremiumPPM;
        uint24 reservePPM;
        uint256 liqPrice;
        uint40 proposedAt;
        bool denied;
        uint256 highestPrice; // all-time high price ever set by any position in this proposal
    }

    struct PositionState {
        uint256 proposalId;
        address owner;
        uint256 minted;
        uint256 price;
        uint256 challengedAmount;
        uint40 start;
        uint40 expiration;
        uint40 cooldown;
        bool closed;
    }

    struct Challenge {
        address challenger;
        uint40 start;
        address position;
        uint256 size;
    }

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event ProposalCreated(uint256 indexed proposalId, address indexed collateral, address indexed proposer);
    event ProposalDenied(uint256 indexed proposalId, address indexed denier);
    event PositionOpened(address indexed owner, address indexed position, uint256 indexed proposalId, address collateral);
    event MintingUpdate(address indexed pos, uint256 collateral, uint256 price, uint256 minted);
    event PositionDenied(address indexed pos, address indexed sender, string message);
    event ChallengeStarted(address indexed challenger, address indexed position, uint256 size, uint256 number);
    event ChallengeAverted(address indexed position, uint256 number, uint256 size);
    event ChallengeSucceeded(address indexed position, uint256 number, uint256 bid, uint256 acquiredCollateral, uint256 challengeSize);
    event PostPonedReturn(address collateral, address indexed beneficiary, uint256 amount);
    event ForcedSale(address pos, uint256 amount, uint256 priceE36MinusDecimals);
    event Roll(address source, uint256 collWithdraw, uint256 repaid, address target, uint256 collDeposit, uint256 minted);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error UnexpectedPrice();
    error InvalidPos();
    error IncompatibleCollateral();
    error InsufficientCollateral(uint256 needed, uint256 available);
    error ProposalNotActive();
    error TooLate();
    error NotOwner();
    error NotHub();
    error Expired(uint40 time, uint40 expiration);
    error Alive();
    error Closed();
    error Hot();
    error Challenged();
    error LimitExceeded(uint256 tried, uint256 available);
    error RepaidTooMuch(uint256 excess);
    error ChallengeTooSmall();
    error InvalidExpiration();
    error PriceIncreaseTooHigh();
    error NotPosition(address pos);

    // -------------------------------------------------------------------------
    // View / pure
    // -------------------------------------------------------------------------

    function zchf() external view returns (IFrankencoin);

    function rate() external view returns (ILeadrate);

    function OPENING_FEE() external view returns (uint256);

    function CHALLENGER_REWARD() external view returns (uint256);

    function EXPIRED_PRICE_FACTOR() external view returns (uint256);

    function proposals(uint256 id) external view returns (Proposal memory);

    function proposalCount() external view returns (uint256);

    function collateralProposals(address collateral, uint256 index) external view returns (uint256);

    function positionData(address pos) external view returns (PositionState memory);

    function allPositions(uint256 index) external view returns (address);

    function positionCount() external view returns (uint256);

    function isPosition(address pos) external view returns (bool);

    function availableForMinting(address pos) external view returns (uint256);

    function challenges(uint256 id) external view returns (Challenge memory);

    function challengeCount() external view returns (uint256);

    function pendingReturns(address collateral, address owner) external view returns (uint256);

    function isProposalActive(uint256 proposalId) external view returns (bool);

    function annualInterestWAD(uint256 proposalId) external view returns (uint256);

    function calculateFeeWAD(address pos) external view returns (uint256);

    function calculateFeeWAD(address pos, uint40 customExpiration) external view returns (uint256);

    function price(uint256 challengeNumber) external view returns (uint256);

    function expiredPurchasePrice(address pos) external view returns (uint256);

    function findRepaymentAmount(address pos) external view returns (uint256);

    function getUsableMint(address pos, uint256 totalMint, bool afterFees) external view returns (uint256);

    function getMintAmount(address pos, uint256 usableMint) external view returns (uint256);

    // -------------------------------------------------------------------------
    // State-changing
    // -------------------------------------------------------------------------

    function proposeCollateral(address collateral, uint256 minCollateral, uint256 mintLimit, uint40 duration, uint40 challengePeriod, uint24 riskPremiumPPM, uint24 reservePPM, uint256 liqPrice) external returns (uint256 proposalId);

    function denyProposal(uint256 proposalId, address[] calldata helpers, string calldata message) external;

    function openPosition(uint256 proposalId, uint256 minCollateral, uint256 initialCollateral, uint256 mintingMaximum, uint40 initPeriodSeconds, uint40 expirationSeconds, uint256 liqPrice) external returns (address);

    function mint(address pos, address target, uint256 amount) external;

    function repay(address pos, uint256 amount) external returns (uint256);

    function adjust(address pos, uint256 newMinted, uint256 newCollateral, uint256 newPrice) external;

    function adjustPrice(address pos, uint256 newPrice) external;

    function withdrawCollateral(address pos, address target, uint256 amount) external;

    function withdraw(address pos, address token, address target, uint256 amount) external;

    function challenge(address pos, uint256 collateralAmount, uint256 minimumPrice) external returns (uint256);

    function bid(uint32 challengeNumber, uint256 size, bool postponeCollateralReturn) external;

    function buyExpiredCollateral(address pos, uint256 upToAmount) external returns (uint256);

    function returnPostponedCollateral(address collateral, address target) external;

    function rollFully(address source, address target) external;

    function rollFullyWithExpiration(address source, address target, uint40 expiration) external;

    function roll(address source, uint256 repay, uint256 collWithdraw, address target, uint256 mint, uint256 collDeposit, uint40 expiration) external;

    function deny(address pos, address[] calldata helpers, string calldata message) external;
}
