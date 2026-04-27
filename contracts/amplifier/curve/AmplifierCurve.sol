// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IFrankencoin, IERC20} from "../../stablecoin/IFrankencoin.sol";
import {SafeERC20} from "../../erc20/SafeERC20.sol";
import {ITwocrypto} from "./helper/ITwocrypto.sol";
import {IAmplifierCurve} from "./helper/IAmplifierCurve.sol";
import {AmplifiedCurvePosition} from "./AmplifiedCurvePosition.sol";

/**
 * @title AmplifierCurve
 *
 * Factory and registered minter for amplified Curve TwoCrypto positions. Amplified positions
 * are positions where the ZCHF half of the trading pair is borrowed from the Frankencoin
 * protocol and only the collateral token is provided by the owner, halving the capital cost
 * of liquidity provisioning.
 *
 * The pool's oracle price at mint time must remain within 20% of the price recorded at
 * deployment. Each user position is an EIP-1167 minimal proxy clone of a shared
 * AmplifiedCurvePosition implementation, keeping per-position deployment cost minimal.
 *
 * Security properties:
 *  - borrowIntoPosition and repay are nonReentrant to prevent pool callback exploits.
 *  - The borrow limit (LIMIT) caps total protocol exposure.
 *  - Positions are tracked in an internal mapping; no Frankencoin position registry is used.
 */
contract AmplifierCurve is IAmplifierCurve {
    using SafeERC20 for IERC20;

    ITwocrypto public immutable CURVE_POOL;
    IFrankencoin public immutable ZCHF;
    IERC20 public immutable COLLATERAL;

    /// @dev Index of ZCHF in the pool (0 or 1); collateral occupies the other slot.
    uint256 public immutable ZCHF_INDEX;

    /// @dev price_oracle() snapshot at deployment: coin[1] price in coin[0] terms, 18 decimals.
    uint256 public immutable PRICE_ANCHOR;

    uint40 public immutable EXPIRATION;
    uint256 public immutable LIMIT;

    /// @dev Shared logic contract that every clone delegates to.
    address public immutable POSITION_IMPLEMENTATION;

    uint256 public totalBorrowed;
    mapping(address => bool) public isPosition;

    uint256 internal constant ONE = 1e18;
    uint256 internal constant TWENTY_PERCENT = ONE / 5;

    /**
     * @param curvePool_     Curve TwoCrypto pool address. Must contain ZCHF as one of its coins.
     * @param zchf_          Frankencoin (ZCHF) address.
     * @param expiration     Unix timestamp after which no new borrows are allowed. Must be future.
     * @param borrowingLimit Maximum total ZCHF that may be borrowed across all positions.
     */
    constructor(address curvePool_, address zchf_, uint40 expiration, uint256 borrowingLimit) {
        if (expiration <= block.timestamp) revert InvalidExpiration();
        if (borrowingLimit == 0) revert InvalidLimit();

        CURVE_POOL = ITwocrypto(curvePool_);
        ZCHF = IFrankencoin(zchf_);
        EXPIRATION = expiration;
        LIMIT = borrowingLimit;

        address coin0 = CURVE_POOL.coins(0);
        address coin1 = CURVE_POOL.coins(1);
        if (coin0 != zchf_ && coin1 != zchf_) revert ZCHFNotInPool();

        ZCHF_INDEX = coin0 == zchf_ ? 0 : 1;
        COLLATERAL = IERC20(coin0 == zchf_ ? coin1 : coin0);

        if (ZCHF.decimals() != 18) revert InvalidDecimals();
        if (COLLATERAL.decimals() != 18) revert InvalidDecimals();

        PRICE_ANCHOR = CURVE_POOL.price_oracle();
        POSITION_IMPLEMENTATION = address(new AmplifiedCurvePosition());
    }

    /**
     * Returns the minimum collateral required to borrow `zchfAmount`, at the deployment price anchor.
     *
     * price_oracle() is the price of coin[1] in coin[0] terms (18 decimals):
     *   ZCHF is coin[0]: minCollateral = zchfAmount * 1e18 / PRICE_ANCHOR
     *   ZCHF is coin[1]: minCollateral = zchfAmount * PRICE_ANCHOR / 1e18
     */
    function getMinimumCollateral(uint256 zchfAmount) public view returns (uint256) {
        return ZCHF_INDEX == 0 ? (zchfAmount * ONE) / PRICE_ANCHOR : (zchfAmount * PRICE_ANCHOR) / ONE;
    }

    /**
     * Returns the remaining ZCHF that can be borrowed before the global limit is reached.
     */
    function getMaximumMint() public view returns (uint256) {
        return totalBorrowed >= LIMIT ? 0 : LIMIT - totalBorrowed;
    }

    /**
     * Reverts if the current pool oracle price has deviated more than 20% from PRICE_ANCHOR.
     */
    function checkPrice() public view {
        uint256 current = CURVE_POOL.price_oracle();
        uint256 maxDelta = (PRICE_ANCHOR * TWENTY_PERCENT) / ONE;
        if (current + maxDelta < PRICE_ANCHOR || current > PRICE_ANCHOR + maxDelta) {
            revert PriceDeviatedTooMuch(current, PRICE_ANCHOR);
        }
    }

    /**
     * Called by a registered position during mint. Validates constraints then stages both tokens
     * in the calling position contract so it can call add_liquidity on the Curve pool.
     *
     * Not intended for direct calls — enforced by onlyPosition.
     *
     * @param owner            Position owner; collateral is pulled from this address.
     * @param zchfAmount       ZCHF to mint into the position.
     * @param collateralAmount Collateral to transfer from owner into the position.
     */
    function borrowIntoPosition(address owner, uint256 zchfAmount, uint256 collateralAmount) external onlyPosition notExpired {
        checkPrice();

        uint256 required = getMinimumCollateral(zchfAmount);
        if (collateralAmount < required) revert InsufficientCollateral(required, collateralAmount);

        uint256 newTotal = totalBorrowed + zchfAmount;
        if (newTotal > LIMIT) revert LimitExceeded(newTotal, LIMIT);
        totalBorrowed = newTotal;

        COLLATERAL.safeTransferFrom(owner, msg.sender, collateralAmount);
        ZCHF.mint(msg.sender, zchfAmount);

        emit Borrowed(msg.sender, zchfAmount, newTotal);
    }

    /**
     * Burns ZCHF from the owner on behalf of a registered position during burn().
     * Frankencoin grants registered minters unlimited allowance, so no explicit approval is needed.
     *
     * Not intended for direct calls — enforced by onlyPosition.
     *
     * @param owner      Address whose ZCHF is burned.
     * @param zchfAmount Amount to burn; computed by the position before calling this.
     */
    function repay(address owner, uint256 zchfAmount) external onlyPosition {
        ZCHF.burnFrom(owner, zchfAmount);
        totalBorrowed = zchfAmount > totalBorrowed ? 0 : totalBorrowed - zchfAmount;
        emit Repaid(msg.sender, zchfAmount, totalBorrowed);
    }

    /**
     * Deploys a minimal proxy clone of POSITION_IMPLEMENTATION, initialises it,
     * and registers it in the local isPosition mapping. The caller becomes the position owner.
     */
    function createAmplifiedPosition() external notExpired returns (address position) {
        position = _clone(POSITION_IMPLEMENTATION);
        AmplifiedCurvePosition(position).initialize(IAmplifierCurve(this), msg.sender);
        isPosition[position] = true;
        emit AmplifiedPositionCreated(position, msg.sender);
    }

    /// @dev EIP-1167 minimal proxy deploy. Identical to PositionFactory._createClone.
    function _clone(address target) internal returns (address result) {
        bytes20 targetBytes = bytes20(target);
        assembly {
            let clone := mload(0x40)
            mstore(clone, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(clone, 0x14), targetBytes)
            mstore(add(clone, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            mstore(0x40, add(clone, 0x37))
            result := create(0, clone, 0x37)
        }
        if (result == address(0)) revert CloneFailed();
    }

    modifier onlyPosition() {
        if (!isPosition[msg.sender]) revert AccessDenied();
        _;
    }

    modifier notExpired() {
        if (block.timestamp > EXPIRATION) revert AmplifierExpired();
        _;
    }

}
