// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../erc20/IERC20.sol";
import "../stablecoin/IFrankencoin.sol";
import "./IPosition.sol";
import "../utils/Ownable.sol";

/**
 * @title PositionRoller
 *
 * Helper to roll over a debt from an old position to a new one.
 * Both positions should have the same collateral. Otherwise, it does not make much sense.
 */
contract PositionRoller {

    IFrankencoin private zchf;

    error NotOwner(address pos);
    error NotPosition(address pos);
    error Log(uint256, uint256, uint256);

    event Roll(address source, uint256 collWithdraw, uint256 repay, address target, uint256 collDeposit, uint256 mint);

    constructor(address zchf_) {
        zchf = IFrankencoin(zchf_);
    }

    /**
     * Convenience method to roll and old position into a new one.
     * 
     * Pre-condition is an allowance for the roller to spend the collateral assset on behalf of the caller,
     * i.e. one should set collateral.approve(roller, collateral.balanceOf(sourcePosition));
     * 
     * The following is assumed:
     * - If the limit of the target position permits, the user wants to roll everything
     * - The user does not want to add additional collateral, but excess collateral is returned
     * - If not enough can be minted in the new position, it is ok for the roller to use ZCHF from the msg.sender
     */
    function rollFully(IPosition source, IPosition target) external {
        rollFullyWithExpiration(source, target, target.expiration());
    }

    /**
     * Like rollFully, but with a custom expiration date for the new position.
     */
    function rollFullyWithExpiration(IPosition source, IPosition target, uint40 expiration) public {
        require(source.collateral() == target.collateral());
        uint256 repay = findRepaymentAmount(source);
        uint256 mintAmount = target.getMintAmount(repay);
        uint256 collateralToWithdraw = IERC20(source.collateral()).balanceOf(address(source));
        uint256 targetPrice = target.price();
        uint256 depositAmount = (mintAmount * 10**18 + targetPrice - 1) / targetPrice; // round up
        if (depositAmount > collateralToWithdraw){
            // If we need more collateral than available from the old position, we opt for taking
            // the missing funds from the caller instead of taking additional collateral from the caller
            depositAmount = collateralToWithdraw;
            mintAmount = depositAmount * target.price() / 10**18; // round down, rest will be taken from caller
        }
        roll(source, repay, collateralToWithdraw, target, mintAmount, depositAmount, expiration);
    }

    /**
     * Doing a binary search is not very efficient, but guaranteed to return a valid result without rounding errors.
     * To save gas costs, the frontend can also call this and other methods to calculate the right parameters and
     * then call 'roll' directly.
     */
    function findRepaymentAmount(IPosition pos) public view returns (uint256) {
        uint256 minted = pos.minted();
        uint24 reservePPM = pos.reserveContribution();
        if (minted == 0){
            return 0;
        }
        uint256 higherResult = zchf.calculateFreedAmount(minted, reservePPM);
        if (higherResult == minted){
            return minted;
        }
        return binarySearch(minted, reservePPM, 0, 0, minted, higherResult);
    }

    // max call stack depth is 1024 in solidity. Binary search on 256 bit number takes at most 256 steps, so it should be fine.
    function binarySearch(uint256 target, uint24 reservePPM, uint256 lowerBound, uint256 lowerResult, uint256 higherBound, uint256 higherResult) internal view returns (uint256) {
        uint256 middle = (lowerBound + higherBound) / 2;
        if (middle == lowerBound){
            return higherBound; // we have reached max precision without exact match, return next higher result to be on the safe side
        } else {
            uint256 middleResult = zchf.calculateFreedAmount(middle, reservePPM);
            if (middleResult == target){
                return middle;
            } else if (middleResult < target){
                return binarySearch(target, reservePPM, middle, middleResult, higherBound, higherResult);
            } else {
                return binarySearch(target, reservePPM, lowerBound, lowerResult, middle, middleResult);
            }
        }
    }

    /**
     * Rolls the source position into the target position using a flash loan.
     * Both the source and the target position must recognize this roller.
     * It is the responsibility of the caller to ensure that both positions are valid contracts.
     * 
     * @param source The source position, must be owned by the msg.sender .
     * @param repay The amount to flash loan in order to repay the source position and free up some or all collateral.
     * @param collWithdraw Collateral to move from the source position to the msg.sender .
     * @param target The target position. If not owned by msg.sender or if it does not have the desired expiration,
     *               it is cloned to create a position owned by the msg.sender.
     * @param mint The amount to be minted from the target position using collateral from msg.sender.
     * @param collDeposit The amount of collateral to be send from msg.sender to the target position.
     * @param expiration The desired expiration date for the target position.
     */
    function roll(IPosition source, uint256 repay, uint256 collWithdraw, IPosition target, uint256 mint, uint256 collDeposit, uint40 expiration) public valid(source) valid(target) own(source) {
        zchf.mint(address(this), repay); // take a flash loan
        source.repay(repay);
        source.withdrawCollateral(msg.sender, collWithdraw);
        if (mint > 0){
            IERC20 targetCollateral = IERC20(target.collateral());
            if (Ownable(address(target)).owner() != msg.sender || expiration != target.expiration()){
                targetCollateral.transferFrom(msg.sender, address(this), collDeposit); // get the new collateral
                targetCollateral.approve(target.hub(), collDeposit); // approve the new collateral and clone:
                target = IPosition(IMintingHub(target.hub()).clone(msg.sender, address(target), collDeposit, mint, expiration));
            } else {
                // We can roll into the provided existing position
                // We do not verify whether the target position has been created by the known minting hub in order
                // to allow positions to be rolled into future versions of the minting hub
                targetCollateral.transferFrom(msg.sender, address(target), collDeposit);
                target.mint(msg.sender, mint);
            }
        }
        zchf.burnFrom(msg.sender, repay); // repay the flash loan
        emit Roll(address(source), collWithdraw, repay, address(target), collDeposit, mint);
    }

    modifier own(IPosition pos) {
        if (Ownable(address(pos)).owner() != msg.sender) revert NotOwner(address(pos));
        _;
    }

    modifier valid(IPosition pos) {
        if (zchf.getPositionParent(address(pos)) == address(0x0)) revert NotPosition(address(pos));
        _;
    }
}

interface IMintingHub {
    function clone(address owner, address parent, uint256 _initialCollateral, uint256 _initialMint, uint40 expiration) external returns (address);
}
