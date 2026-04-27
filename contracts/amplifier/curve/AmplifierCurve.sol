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
 * are positions where the ZCHF half of the pair is borrowed from the Frankencoin protocol and
 * only the collateral token is provided by the owner, halving the capital cost of liquidity
 * provisioning.
 *
 * The pool's oracle price at mint time must remain within 20% of the price recorded at deployment.
 *
 * Each user position is an EIP-1167 minimal proxy clone of a shared AmplifiedCurvePosition
 * implementation, keeping per-user deployment cost minimal.
 */
contract AmplifierCurve is IAmplifierCurve {
    using SafeERC20 for IERC20;

    ITwocrypto public immutable CURVE_POOL;
    IFrankencoin public immutable ZCHF;
    IERC20 public immutable COLLATERAL;

    // Index of ZCHF in the Curve pool (0 or 1); collateral occupies the other index.
    uint256 public immutable ZCHF_INDEX;

    // price_oracle() at deployment: price of coin[1] in coin[0] terms, 18 decimals.
    uint256 public immutable PRICE_ANCHOR;

    uint40 public immutable EXPIRATION;
    uint256 public immutable LIMIT;

    // Shared implementation that every clone delegates to.
    address public immutable POSITION_IMPLEMENTATION;

    uint256 public totalBorrowed;
    mapping(address => bool) public isPosition;
    uint256 private _locked = 1;

    uint256 internal constant ONE = 1e18;
    uint256 internal constant TWENTY_PERCENT = ONE / 5;

    /**
     * @param curvePool_     Address of the Curve TwoCrypto pool.
     * @param zchf_          Address of Frankencoin (ZCHF).
     * @param expiration     Unix timestamp after which no new borrows are allowed.
     * @param borrowingLimit Maximum total ZCHF that can be borrowed across all positions.
     */
    constructor(address curvePool_, address zchf_, uint40 expiration, uint256 borrowingLimit) {
        CURVE_POOL = ITwocrypto(curvePool_);
        ZCHF = IFrankencoin(zchf_);
        EXPIRATION = expiration;
        LIMIT = borrowingLimit;

        // pool token config
        address coin0 = CURVE_POOL.coins(0);
        address coin1 = CURVE_POOL.coins(1);
        require(coin0 == zchf_ || coin1 == zchf_, "ZCHF not in pool");

        // pool index config
        ZCHF_INDEX = coin0 == zchf_ ? 0 : 1;
        COLLATERAL = IERC20(coin0 == zchf_ ? coin1 : coin0);

        // token 18 decimals config
        require(ZCHF.decimals() == 18);
        require(COLLATERAL.decimals() == 18);

        // snapshot pool price
        PRICE_ANCHOR = CURVE_POOL.price_oracle();

        // deploy implementation
        POSITION_IMPLEMENTATION = address(new AmplifiedCurvePosition());
    }

    /**
     * Returns the minimum collateral required to borrow `zchfAmount`, computed at the price anchor.
     *
     * price_oracle() is the price of coin[1] in coin[0] terms (18 decimals).
     *   ZCHF is coin[0]: 1 collateral = PRICE_ANCHOR ZCHF  →  minCollateral = zchfAmount / PRICE_ANCHOR
     *   ZCHF is coin[1]: 1 ZCHF = PRICE_ANCHOR collateral  →  minCollateral = zchfAmount * PRICE_ANCHOR / 1e18
     */
    function getMinimumCollateral(uint256 zchfAmount) public view returns (uint256) {
        if (ZCHF_INDEX == 0) {
            return (zchfAmount * ONE) / PRICE_ANCHOR;
        } else {
            return (zchfAmount * PRICE_ANCHOR) / ONE;
        }
    }

    /**
     * Reverts if the current pool oracle price has deviated more than 20% from the deployment anchor.
     */
    function checkPrice() public view {
        uint256 current = CURVE_POOL.price_oracle();
        uint256 maxDelta = (PRICE_ANCHOR * TWENTY_PERCENT) / ONE;
        if (current + maxDelta < PRICE_ANCHOR || current > PRICE_ANCHOR + maxDelta) {
            revert PriceDeviatedTooMuch(current, PRICE_ANCHOR);
        }
    }

    /**
     * Called by a position during mint. Validates all constraints, then stages both tokens
     * inside the calling position contract so it can call add_liquidity on the pool.
     *
     * @param owner            Position owner; collateral is pulled from this address.
     * @param zchfAmount       ZCHF to mint into the position.
     * @param collateralAmount Collateral to pull from the owner into the position.
     */
    function borrowIntoPosition(address owner, uint256 zchfAmount, uint256 collateralAmount) external onlyPosition notExpired nonReentrant {
        // verify price threshold
        checkPrice();

        // verify collateral amount
        uint256 required = getMinimumCollateral(zchfAmount);
        if (collateralAmount < required) revert InsufficientCollateral(required, collateralAmount);

        // verify minting limit
        uint256 newTotal = totalBorrowed + zchfAmount;
        if (newTotal > LIMIT) revert LimitExceeded(newTotal, LIMIT);
        totalBorrowed = newTotal;

        // provide tokens to position
        COLLATERAL.safeTransferFrom(owner, msg.sender, collateralAmount);
        ZCHF.mint(msg.sender, zchfAmount);

        emit Borrowed(msg.sender, zchfAmount, newTotal);
    }

    /**
     * Burns the specified amount of ZCHF from the owner. Called by a position during burn().
     * No explicit approval is required — Frankencoin grants registered minters unlimited allowance.
     *
     * @param owner      Address whose ZCHF will be burned.
     * @param zchfAmount Amount to burn; calculated by the position before calling this.
     */
    function repay(address owner, uint256 zchfAmount) external onlyPosition nonReentrant {
        ZCHF.burnFrom(owner, zchfAmount);
        totalBorrowed -= zchfAmount;
        emit Repaid(msg.sender, zchfAmount, totalBorrowed);
    }

    /**
     * Deploys a minimal proxy clone of the shared position implementation and registers it
     * with the Frankencoin protocol. The caller becomes the position owner.
     */
    function createAmplifiedPosition() external notExpired returns (address position) {
        position = _clone(POSITION_IMPLEMENTATION);
        AmplifiedCurvePosition(position).initialize(IAmplifierCurve(this), msg.sender);
        isPosition[position] = true;
        emit AmplifiedPositionCreated(position, msg.sender);
    }

    // EIP-1167 minimal proxy, identical to PositionFactory._createClone.
    function _clone(address target) internal returns (address result) {
        bytes20 targetBytes = bytes20(target);
        assembly {
            let clone := mload(0x40)
            mstore(clone, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(clone, 0x14), targetBytes)
            mstore(add(clone, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            result := create(0, clone, 0x37)
        }
        require(result != address(0));
    }

    modifier onlyPosition() {
        if (!isPosition[msg.sender]) revert AccessDenied();
        _;
    }

    modifier notExpired() {
        if (block.timestamp > EXPIRATION) revert AmplifierExpired();
        _;
    }

    modifier nonReentrant() {
        require(_locked == 1);
        _locked = 2;
        _;
        _locked = 1;
    }
}
