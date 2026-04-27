// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "../../erc20/IERC20.sol";
import {IFrankencoin} from "../../stablecoin/IFrankencoin.sol";
import {Ownable} from "../../utils/Ownable.sol";
import {ITwocrypto} from "./helper/ITwocrypto.sol";
import {IAmplifierCurve} from "./helper/IAmplifierCurve.sol";
import {IAmplifiedCurvePosition} from "./helper/IAmplifiedCurvePosition.sol";

/**
 * @title AmplifiedCurvePosition
 *
 * Implementation contract for amplified Curve positions. Each user gets an EIP-1167 clone
 * of this contract deployed by AmplifierCurve, keeping per-user deployment cost minimal.
 *
 * On mint: pulls ZCHF + collateral from the amplifier into this contract, then calls
 *          add_liquidity on the Curve pool. LP tokens are held here.
 * On burn: calls remove_liquidity (tokens go directly to the owner), then repays the
 *          proportional borrowed ZCHF via the amplifier.
 */
contract AmplifiedCurvePosition is Ownable, IAmplifiedCurvePosition {
    IAmplifierCurve public AMP;

    uint256 public borrowed;
    uint256 public lpBalance;

    /**
     * One-shot initializer called by AmplifierCurve immediately after cloning.
     * Guards against re-initialization by checking AMP is unset.
     */
    function initialize(IAmplifierCurve amp, address positionOwner) external {
        if (address(AMP) != address(0)) revert AlreadyInitialized();
        AMP = amp;
        _setOwner(positionOwner);
    }

    /**
     * Adds liquidity to the Curve pool using borrowed ZCHF and owner-supplied collateral.
     *
     * The amplifier stages both tokens into this contract. The owner must have approved
     * this contract to spend `collateralAmount` of the collateral token beforehand.
     *
     * @param zchfAmount       ZCHF to borrow and add to the pool.
     * @param collateralAmount Collateral to pull from the owner and add to the pool.
     * @param minLp            Minimum LP tokens to receive (slippage guard).
     */
    function mint(uint256 zchfAmount, uint256 collateralAmount, uint256 minLp) external onlyOwner {
        IAmplifierCurve amp = AMP;
        ITwocrypto pool = amp.CURVE_POOL();
        IERC20 zchf = IERC20(address(amp.ZCHF()));
        IERC20 collateral = amp.COLLATERAL();

        // Stage both tokens into this contract via the amplifier.
        amp.borrowIntoPosition(owner, zchfAmount, collateralAmount);

        // Approve the pool to pull both tokens for add_liquidity.
        zchf.approve(address(pool), zchfAmount);
        collateral.approve(address(pool), collateralAmount);

        uint256[2] memory amounts = _makeAmounts(amp.ZCHF_INDEX(), zchfAmount, collateralAmount);
        uint256 lpReceived = pool.add_liquidity(amounts, minLp);

        borrowed += zchfAmount;
        lpBalance += lpReceived;

        emit Mint(zchfAmount, collateralAmount, lpReceived);
    }

    /**
     * Removes liquidity from the Curve pool and repays the proportional borrowed ZCHF.
     *
     * Tokens are delivered directly to the owner by the pool. The owner must have approved
     * the amplifier to burn the proportional ZCHF from their address before calling this.
     *
     * @param lpAmount   LP tokens to burn.
     * @param minAmounts Minimum [zchf, collateral] token amounts to receive (slippage guard).
     * @return received  Actual token amounts received by the owner.
     */
    function burn(uint256 lpAmount, uint256[2] calldata minAmounts) external onlyOwner returns (uint256[2] memory received) {
        IAmplifierCurve amp = AMP;

        received = amp.CURVE_POOL().remove_liquidity(lpAmount, minAmounts, owner);

        uint256 zchfRepaid = amp.repay(owner, borrowed, lpAmount, lpBalance);
        borrowed -= zchfRepaid;
        lpBalance -= lpAmount;

        emit Burn(lpAmount, zchfRepaid);
    }

    function _makeAmounts(uint256 zchfIndex, uint256 zchfAmt, uint256 collateralAmt) internal pure returns (uint256[2] memory amounts) {
        amounts[zchfIndex] = zchfAmt;
        amounts[1 - zchfIndex] = collateralAmt;
    }
}
