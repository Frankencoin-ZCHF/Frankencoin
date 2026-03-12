// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./FPS2Governance.sol";
import "../Equity.sol";
import "../../utils/MathUtil.sol";
import "../../erc20/ERC20.sol";

/**
 * @title FPS2MintRedeem
 * @notice Mint and redemption logic for FPS2. Users can invest ZCHF or wrap FPS to get FPS2.
 * Redemptions apply a discount based on an 8th-power curve that increases with recent
 * redemption volume (measured in FPS shares). The spread (undiscounted portion) is returned
 * to the Equity contract.
 */
abstract contract FPS2MintRedeem is ERC20, MathUtil {

    uint256 public constant RECOVERY_PERIOD = 30 days;

    Equity public immutable fps;

    // --- Spread mechanism (tracks net redemption volume in FPS shares) ---
    uint192 public recentlyRedeemed;
    uint64 public lastRedemption;

    event Trade(address who, int amount, uint totPrice);

    constructor(Equity fps_) {
        fps = fps_;
    }

    // ==================== Investment ====================

    /**
     * @notice Invest ZCHF to receive FPS2 tokens. The caller must have approved this contract
     * to spend their ZCHF. The investment goes through Equity.invest at the unaltered price.
     * @param amount          ZCHF to invest
     * @param expectedShares  Minimum FPS2 shares expected (slippage protection)
     * @return The number of FPS2 shares minted
     */
    function invest(uint256 amount, uint256 expectedShares) external returns (uint256) {
        zchf.transferFrom(msg.sender, address(this), amount);
        uint256 fpsMinted = fps.invest(amount, expectedShares);
        _mint(msg.sender, fpsMinted);
        _notifyInvestment(fpsMinted);
        emit Trade(msg.sender, int(fpsMinted), amount);
        return fpsMinted;
    }

    /**
     * @notice Wrap FPS tokens into FPS2 tokens 1:1.
     * The caller must have approved this contract to spend their FPS.
     * @param amount  Number of FPS to wrap
     */
    function wrap(uint256 amount) external {
        fps.transferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, amount);
        _notifyInvestment(amount);
        emit Trade(msg.sender, int(amount), 0);
    }

    // ==================== Redemption ====================

    /**
     * @notice Redeem FPS2 for ZCHF. A discount is applied based on the 8th power of the
     * remaining share ratio, increasing with recent redemption volume. The undiscounted
     * portion of the proceeds is returned to Equity.
     * @param target  Address to receive the ZCHF proceeds
     * @param shares  Number of FPS2 shares to redeem
     * @return The effective ZCHF proceeds sent to target
     */
    function redeem(address target, uint256 shares) public returns (uint256) {
        uint256 recent = weightedRecentRedemptions();
        uint256 fpsLeft = totalSupply() - shares;
        uint256 discountFactor = discount(recent, shares, fpsLeft);

        _burn(msg.sender, shares);
        uint256 rawProceeds = fps.redeem(address(this), shares);
        uint256 effectiveProceeds = _mulD18(rawProceeds, discountFactor);

        recentlyRedeemed = uint192(recent + shares);
        lastRedemption = uint64(block.timestamp);

        zchf.transfer(target, effectiveProceeds);
        uint256 spread = rawProceeds - effectiveProceeds;
        if (spread > 0) {
            zchf.transfer(address(fps), spread);
        }

        emit Trade(msg.sender, -int(shares), effectiveProceeds);
        return effectiveProceeds;
    }

    /**
     * @notice Like redeem, but with an extra parameter to protect against frontrunning.
     * @param expectedProceeds  The minimum acceptable effective proceeds
     */
    function redeemExpected(address target, uint256 shares, uint256 expectedProceeds) external returns (uint256) {
        uint256 proceeds = redeem(target, shares);
        require(proceeds >= expectedProceeds);
        return proceeds;
    }

    // ==================== Pricing ====================

    /**
     * @notice The investment price of one FPS2 in ZCHF, equal to the underlying FPS price.
     */
    function ask() public view returns (uint256) {
        return fps.price();
    }

    /**
     * @notice The marginal redemption price of one FPS2 in ZCHF, reflecting the current discount.
     */
    function bid() public view returns (uint256) {
        uint256 recent = weightedRecentRedemptions();
        return _mulD18(fps.price(), discount(recent, 0, totalSupply()));
    }

    /**
     * @notice Preview the effective proceeds after discount for selling the given number of shares.
     */
    function calculateEffectiveProceeds(uint256 shares) external view returns (uint256) {
        uint256 recent = weightedRecentRedemptions();
        return _mulD18(fps.calculateProceeds(shares), discount(recent, shares, totalSupply() - shares));
    }

    // ==================== Discount ====================

    /**
     * @notice Calculate the discount factor for a redemption using an 8th-power curve.
     * The curve starts at 1 when no recent redemptions have occurred and approaches 0
     * as redemptions consume the pool. Uses a midpoint approximation for the average
     * discount across the redeemed range.
     * @param recentRedemptions            Weighted recent FPS redemptions
     * @param currentRedemption            Number of FPS being redeemed now
     * @param fpsLeftAfterCurrentRedemption FPS2 supply remaining after this redemption
     * @return The discount factor with 18 decimals (1e18 = no discount)
     */
    function discount(uint256 recentRedemptions, uint256 currentRedemption, uint256 fpsLeftAfterCurrentRedemption) public pure returns (uint256) {
        uint256 total = fpsLeftAfterCurrentRedemption + recentRedemptions + currentRedemption;
        uint256 leftMiddle = fpsLeftAfterCurrentRedemption + currentRedemption / 2;
        uint256 factor = _divD18(leftMiddle, total);
        return _eightPower(factor);
    }

    // ==================== Internals ====================

    /**
     * @notice Returns the time-weighted recent redemption volume in FPS shares,
     * decaying linearly to zero over the RECOVERY_PERIOD.
     */
    function weightedRecentRedemptions() public view returns (uint256) {
        uint256 elapsed = block.timestamp - lastRedemption;
        if (elapsed >= RECOVERY_PERIOD) {
            return 0;
        } else {
            return recentlyRedeemed * (RECOVERY_PERIOD - elapsed) / RECOVERY_PERIOD;
        }
    }

    function _notifyInvestment(uint256 fpsShares) internal {
        uint256 recent = weightedRecentRedemptions();
        if (recent == 0) {
            // nothing to offset
        } else if (fpsShares > recent) {
            recentlyRedeemed = 0;
        } else {
            recentlyRedeemed = uint192(recent - fpsShares);
            lastRedemption = uint64(block.timestamp);
        }
    }

}
