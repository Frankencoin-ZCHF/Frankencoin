// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../IEquity.sol";
import "../../stablecoin/IFrankencoin.sol";
import "../../utils/MathUtil.sol";
import "../../erc20/ERC20.sol";
import "../../erc20/IERC4626.sol";

/**
 * Equips the FPS2 token with minting and redemption functionality that is compatible with the ERC-4626 standard.
 * 
 * While FPS2 wraps FPS1 tokens, minting and redemption is done directly in ZCHF, making this effectively a ZCHF vault token.
 * 
 * To discourage large-scale redemptions, the redemption price drops fast on redemptions, leading to a potentially large spread.
 * 
 * This spread is closed linearly over the course of a week. For large redemptions, it is recommended to spread the redemptions into
 * tranches that are executed over a longer period of time.
 */
abstract contract FPS2MintRedeem is ERC20, MathUtil, IERC4626 {

     // How long it takes for the price to fully recover (linearly) after a redemption
    uint256 public constant RECOVERY_PERIOD = 7 days;

    IEquity public immutable FPS1;
    IFrankencoin public immutable ZCHF;

    // The time-weighted amount that was recently redeemed
    uint192 public recentlyRedeemed;
    // The timestamp of the last redemption and the time recentlyRedeemed was last recalculated.
    uint64 public redemptionAnchor;

    error RedemptionsDisabled();

    constructor(IFrankencoin zchf_) {
        FPS1 = IEquity(address(zchf_.reserve()));
        ZCHF = zchf_;
        zchf_.approve(address(zchf_.reserve()), type(uint256).max);
    }

    // ==================== Asset info ====================

    function asset() public view returns (address) {
        return address(ZCHF);
    }

    /**
     * Total assets that can potentially be redeemed over time, disregarding the redemption discount, but including the 0.3%
     * fee of the underlying FPS1 system.
     */
    function totalAssets() public view returns (uint256) {
        return FPS1.calculateProceeds(FPS1.balanceOf(address(this)));
    }

    /**
     * Convert a given monetary amount into shares at the current price.
     * 
     * This is the inverse method of 'convertToAssets' and based on the current price of Frankencoin Pool Shares (FPS).
     * 
     * It disregards slippage, fees, redemption discounts and other factors that would apply when actually minting or
     * redeeming FPS2 tokens.
     */
    function convertToShares(uint256 assets) public view returns (uint256) {
        return _divD18(assets, FPS1.price());
    }

    /**
     * The price of the given amount of assets based on the current price of the shares.
     * 
     * This can be used to calculate the market value of a given number of shares, for example when showing the value
     * of a user's portfolio in a wallet app. It must not be confused with "previewRedeem", which returns a much
     * lower number for significant redemptions due to the underlying bonding curve and slippage.
     */
    function convertToAssets(uint256 shares) public view returns (uint256) {
        return _mulD18(shares, FPS1.price());
    }

    /**
     * The marginal price when buying FPS2 with ZCHF.
     * 
     * Note that FPS1 has a built-in fee of 0.3%, which is not reflected in this price.
     */
    function ask() public view returns (uint256) {
        return FPS1.price();
    }

    /**
     * @notice The marginal redemption price of one FPS2 in ZCHF, reflecting the current discount.
     * 
     * Note that FPS1 has a built-in fee of 0.3%, which is not reflected in this price.
     */
    function bid() public view returns (uint256) {
        uint256 recent = weightedRecentRedemptions();
        return _mulD18(FPS1.price(), discount(recent, 0));
    }

    // ==================== Deposit & Mint ====================

    /**
     * There is no limit for how much can be deposited.
     */
    function maxDeposit(address) public pure returns (uint256) {
        return type(uint256).max;
    }

    /**
     * Exact amount that an investor gets from depositing ZCHF, including fees and slippage.
     */
    function previewDeposit(uint256 assets) public view returns (uint256) {
        return FPS1.calculateShares(assets);
    }

    /**
     * Deposit ZCHF and receive FPS2 shares. In the background, FPS1 are bought and wrapped.
     */
    function deposit(uint256 assets, address recipient) public returns (uint256 shares) {
        return _deposit(recipient, assets);
    }

    /**
     * Deposit ZCHF to receive FPS2 tokens with frontrunning protection.
     * 
     * @param amount          ZCHF to invest
     * @param expectedShares  Minimum FPS2 shares expected
     * @return The number of FPS2 shares minted
     */
    function depositExpected(uint256 amount, address recipient, uint256 expectedShares) external returns (uint256) {
        uint256 shares = _deposit(recipient, amount);
        require(shares >= expectedShares);
        return shares;
    }

    function _deposit(address to, uint256 amount) internal returns (uint256) {
        ZCHF.transferFrom(msg.sender, address(this), amount);
        uint256 shares = FPS1.invest(amount, 0);
        _mint(to, shares);
        _notifyInvestment(shares);
        emit Deposit(msg.sender, to, amount, shares);
        return shares;
    }

    /**
     * There is no hard limit for the number of FPS2.
     */
    function maxMint(address) public pure returns (uint256) {
        return type(uint256).max;
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        return _findAssetsForShares(shares);
    }

    /**
     * @notice Mint exactly the requested FPS2 shares by depositing the necessary ZCHF.
     * To fulfill ERC-4626 specs, this function will always result in the caller receiving exactly 'shares'
     * shares, even if the underlying mechanism yields slightly more than requested due to rounding. In that
     * case, the excess dust amount is left in this contract as a micro-donation from the caller.
     */
    function mint(uint256 shares, address receiver) public returns (uint256) {
        uint256 assets = _findAssetsForShares(shares);
        ZCHF.transferFrom(msg.sender, address(this), assets);
        FPS1.invest(assets, shares); // must yield at least shares
        // note that we might have received more shares than requested due to rounding
        // this can leave dust amounts of FPS1 in this contract.
        _mint(receiver, shares);
        _notifyInvestment(shares);
        emit Deposit(msg.sender, receiver, assets, shares);
        return assets;
    }

    /**
     * Calculates the Frankencoins needed to buy the given number of FPS2 shares. The returned value
     * is guaranteed to be sufficient to mint the requested number of shares, but may be slightly higher
     * than necessary due to rounding.
     */
    function _findAssetsForShares(uint256 shares) internal view returns (uint256) {
        uint256 fps1Supply = FPS1.totalSupply();
        uint256 worstCaseUndershoot = 3 * fps1Supply / 1e18;
        uint256 growthFactor = _divD18(fps1Supply + shares + worstCaseUndershoot, fps1Supply);
        uint256 capitalGrowth = _mulD18(_mulD18(growthFactor, growthFactor), growthFactor);
        uint256 capitalNeeded = _mulD18(ZCHF.equity(), capitalGrowth) - ZCHF.equity();
        return capitalNeeded * 1000 / 997;
    }
    
    function _notifyInvestment(uint256 fpsShares) internal {
        uint256 recent = weightedRecentRedemptions();
        if (recent == 0) {
            // nothing to offset
        } else if (fpsShares > recent) {
            recentlyRedeemed = 0;
        } else {
            recentlyRedeemed = uint192(recent - fpsShares);
            redemptionAnchor = uint64(block.timestamp);
        }
    }

    // ==================== Withdraw & Redeem ====================

    function maxWithdraw(address owner) public view returns (uint256) {
        return previewRedeem(balanceOf(owner));
    }

    function calculateEffectiveProceeds(uint256 currentSupply, uint256 recent, uint256 latest, uint256 proceeds) internal pure returns (uint256) {
        return _mulD18(proceeds, discountPure(currentSupply, recent, latest));
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return _findSharesForAssets(assets);
    }

    /**
     * @notice Withdraw exactly the requested ZCHF by burning the necessary FPS2 shares.
     * The required shares are found via binary search on the discount curve.
     */
    function withdraw(uint256 assets, address receiver, address owner) public returns (uint256) {
        uint256 shares = _findSharesForAssets(assets);
        _redeem(owner, receiver, shares);
        return shares;
    }

    error RedemptionLimitExceeded(uint256 limit);

    /**
     * @notice Binary search for the minimum FPS2 shares to redeem in order to receive at least the given ZCHF amount.
     */
    function _findSharesForAssets(uint256 assets) internal view returns (uint256) {
        if (assets == 0) return 0;
        uint256 totalSupply = totalSupply();
        uint256 recent = weightedRecentRedemptions();
        uint256 lo = _divD18(assets, FPS1.price());
        uint256 hi = totalSupply / 10; // redeem at most 10% of all shares at once
        if (calculateEffectiveProceeds(totalSupply, recent, hi, FPS1.calculateProceeds(hi)) < assets) {
            revert RedemptionLimitExceeded(hi);
        }
        while (lo < hi) {
            uint256 mid = lo + (hi - lo) / 2;
            if (calculateEffectiveProceeds(totalSupply, recent, mid, FPS1.calculateProceeds(mid)) >= assets) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }
        return lo;
    }

    function redemptionsEnabled() internal view virtual returns (bool);

    function maxRedeem(address owner) public view returns (uint256) {
        return redemptionsEnabled() ? previewRedeem(balanceOf(owner)) : 0;
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        if (redemptionsEnabled()) {
            return calculateEffectiveProceeds(totalSupply(), weightedRecentRedemptions(), shares, FPS1.calculateProceeds(shares));
        } else {
            return 0;
        }
    }

    /**
     * @notice Burn FPS2 shares from owner and send ZCHF proceeds to receiver.
     * If caller is not owner, requires ERC-20 allowance.
     */
    function redeem(uint256 shares, address receiver, address owner) public returns (uint256) {
        return _redeem(owner, receiver, shares);
    }

    /**
     * @notice Redeem FPS2 for ZCHF.
     * @param target  Address to receive the ZCHF proceeds
     * @param shares  Number of FPS2 shares to redeem
     * @return The effective ZCHF proceeds sent to target
     */
    function redeem(address target, uint256 shares) public returns (uint256) {
        return _redeem(msg.sender, target, shares);
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
    
    function _redeem(address from, address to, uint256 shares) internal virtual returns (uint256) {
        if (!redemptionsEnabled()) revert RedemptionsDisabled();
        if (msg.sender != from) _useAllowance(from, msg.sender, shares);

        uint256 recent = weightedRecentRedemptions();
        uint256 totalSupply = totalSupply();
        _burn(from, shares);
        uint256 rawProceeds = FPS1.redeem(address(this), shares);
        uint256 effectiveProceeds = calculateEffectiveProceeds(totalSupply, recent, shares, rawProceeds);

        recentlyRedeemed = uint192(recent + shares);
        redemptionAnchor = uint64(block.timestamp);

        ZCHF.transfer(to, effectiveProceeds);
        ZCHF.transfer(address(FPS1), rawProceeds - effectiveProceeds);

        emit Withdraw(msg.sender, to, from, effectiveProceeds, shares);
        return effectiveProceeds;
    }

    /**
     * @notice Calculate the discount factor for a redemption using a 4th-power curve.
     * The curve starts at 1 when no recent redemptions have occurred and approaches 0
     * as redemptions consume the pool. Uses a midpoint approximation for the average
     * discount across the redeemed range.
     * @param recentRedemptions  Weighted recent FPS redemptions
     * @param plannedRedemption  Number of FPS being redeemed now
     * @return The discount factor with 18 decimals (1e18 = no discount)
     */
    function discount(uint256 recentRedemptions, uint256 plannedRedemption) public view returns (uint256) {
        return discountPure(totalSupply(), recentRedemptions, plannedRedemption);
    }

    function discountPure(uint256 currentSupply, uint256 recentRedemptions, uint256 plannedRedemption) internal pure returns (uint256) {
        uint256 total = currentSupply + recentRedemptions;
        uint256 leftMiddle = currentSupply - plannedRedemption / 2;
        uint256 factor = _divD18(leftMiddle, total);
        return _power4(factor);
    }

    /**
     * @notice Returns the time-weighted recent redemption volume in FPS shares,
     * decaying linearly to zero over the RECOVERY_PERIOD.
     */
    function weightedRecentRedemptions() public view returns (uint256) {
        uint256 elapsed = block.timestamp - redemptionAnchor;
        if (elapsed >= RECOVERY_PERIOD) {
            return 0;
        } else {
            return recentlyRedeemed * (RECOVERY_PERIOD - elapsed) / RECOVERY_PERIOD;
        }
    }

    /**
     * @notice The current discount factor that would apply when redeeming the given number of shares.
     * @param shares  Number of FPS2 shares to redeem (use 0 for the marginal discount)
     * @return The discount factor with 18 decimals (1e18 = no discount, 0 = full discount)
     */
    function currentDiscount(uint256 shares) public view returns (uint256) {
        return discount(weightedRecentRedemptions(), shares);
    }

}
