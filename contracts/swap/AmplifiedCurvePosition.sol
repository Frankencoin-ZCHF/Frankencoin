// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "../erc20/IERC20.sol";
import {Ownable} from "../utils/Ownable.sol";
import {ITwocrypto} from "./utils/ITwocrypto.sol";
import {ICurveAmplifier} from "./utils/ICurveAmplifier.sol";
import {IAmplifiedCurvePosition} from "./utils/IAmplifiedCurvePosition.sol";

/**
 * @title AmplifiedCurvePosition
 *
 * Per-user position contract for the AmplifierCurve system, deployed as an EIP-1167 clone.
 * Holds LP tokens on behalf of the owner and manages the borrow/repay lifecycle with the
 * parent AmplifierCurve.
 *
 * Mint flow:
 *   1. Owner calls mint() — debt state is updated first (CEI).
 *   2. AmplifierCurve.borrowIntoPosition() stages ZCHF + collateral in this contract.
 *   3. This contract approves and calls pool.add_liquidity(); LP tokens are held here.
 *
 * Burn flow:
 *   1. Owner calls burn() — pool returns tokens directly to the owner.
 *   2. Proportional ZCHF debt is burned from the owner via AmplifierCurve.repay().
 *   3. Debt and LP balance are decremented.
 */
contract AmplifiedCurvePosition is Ownable, IAmplifiedCurvePosition {
    ICurveAmplifier public AMP;

    uint256 public borrowed;
    uint256 public lpBalance;

    // 0 = unlocked (clone default), 1 = locked.
    // Intentionally not initialised to 1 — clones don't run constructors.
    uint256 private _locked;

    // Brick the bare implementation so it can never be initialized.
    // Clones do not run constructors, so their AMP starts at address(0) and
    // initialize() works normally on them.
    constructor() {
        AMP = ICurveAmplifier(address(1));
        _locked = 1;
    }

    /**
     * One-shot initializer called by AmplifierCurve immediately after cloning.
     */
    function initialize(ICurveAmplifier amp, address positionOwner) external {
        if (address(AMP) != address(0)) revert AlreadyInitialized();
        AMP = amp;
        _setOwner(positionOwner);
    }

    /**
     * Adds liquidity to the Curve pool using borrowed ZCHF and owner-supplied collateral.
     *
     * The owner must approve AmplifierCurve (not this contract) to spend `collateralAmount`
     * of the collateral token, because the amplifier executes the transferFrom.
     *
     * @param zchfAmount       ZCHF to borrow and add to the pool.
     * @param collateralAmount Collateral to pull from the owner into the pool.
     * @param minLp            Minimum LP tokens to receive (slippage guard).
     * @return lpReceived      LP tokens received and credited to this position.
     */
    function mint(uint256 zchfAmount, uint256 collateralAmount, uint256 minLp) external onlyOwner nonReentrant returns (uint256 lpReceived) {
        if (zchfAmount == 0 || collateralAmount == 0) revert ZeroAmount();

        ITwocrypto pool = AMP.CURVE_POOL();
        IERC20 zchf = IERC20(address(AMP.ZCHF()));
        IERC20 collateral = AMP.COLLATERAL();

        // Update debt before any external call (CEI).
        borrowed += zchfAmount;

        AMP.borrowIntoPosition(owner, zchfAmount, collateralAmount);

        zchf.approve(address(pool), zchfAmount);
        collateral.approve(address(pool), collateralAmount);

        uint256[2] memory amounts = _makeAmounts(AMP.ZCHF_INDEX(), zchfAmount, collateralAmount);
        lpReceived = pool.add_liquidity(amounts, minLp);

        zchf.approve(address(pool), 0);
        collateral.approve(address(pool), 0);

        lpBalance += lpReceived;

        emit Mint(zchfAmount, collateralAmount, lpReceived);
    }

    /**
     * Removes liquidity from the Curve pool and repays the proportional borrowed ZCHF.
     *
     * Tokens are sent directly to the owner by the pool. No explicit ZCHF approval is needed —
     * Frankencoin grants registered minters unlimited allowance on all accounts.
     *
     * Repayment uses ceiling division so partial burns always reduce debt at least proportionally,
     * preventing LP extraction without corresponding debt repayment.
     *
     * @param lpAmount   LP tokens to burn.
     * @param minAmounts Minimum [coin0, coin1] amounts to receive (slippage guard).
     * @return received  Actual token amounts delivered to the owner by the pool.
     */
    function burn(uint256 lpAmount, uint256[2] calldata minAmounts) external onlyOwner nonReentrant returns (uint256[2] memory received) {
        if (lpAmount == 0) revert ZeroAmount();

        received = AMP.CURVE_POOL().remove_liquidity(lpAmount, minAmounts, owner);

        uint256 zchfRepay = (lpAmount == lpBalance) ? borrowed : (borrowed * lpAmount + lpBalance - 1) / lpBalance;

        AMP.repay(owner, zchfRepay);
        borrowed -= zchfRepay;
        lpBalance -= lpAmount;

        emit Burn(lpAmount, zchfRepay);
    }

    modifier nonReentrant() {
        if (_locked == 1) revert Reentered();
        _locked = 1;
        _;
        _locked = 0;
    }

    function _makeAmounts(uint256 zchfIndex, uint256 zchfAmt, uint256 collateralAmt) internal pure returns (uint256[2] memory amounts) {
        amounts[zchfIndex] = zchfAmt;
        amounts[1 - zchfIndex] = collateralAmt;
    }
}
