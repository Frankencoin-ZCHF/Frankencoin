// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../IEquity.sol";
import "../../stablecoin/IFrankencoin.sol";
import "../../utils/MathUtil.sol";
import "../../erc20/ERC20.sol";
import "../../erc20/IERC4626.sol";

/**
 * @title FPS2MintRedeem
 * @notice ERC-4626 tokenized vault around Frankencoin Pool Shares (FPS).
 * Users deposit ZCHF, which is invested into FPS via Equity. Redemptions apply a discount
 * based on a 4th-power curve that increases with recent redemption volume.
 * The spread (undiscounted portion) is returned to the Equity contract.
 */
abstract contract FPS2MintRedeem is ERC20, MathUtil, IERC4626 {

    uint256 public constant RECOVERY_PERIOD = 7 days;

    IEquity public immutable FPS1;
    IFrankencoin public immutable ZCHF;

    // --- Spread mechanism (tracks net redemption volume in FPS shares) ---
    uint192 public recentlyRedeemed;
    uint64 public redemptionAnchor;

    constructor(IFrankencoin zchf_) {
        FPS1 = IEquity(address(zchf_.reserve()));
        ZCHF = zchf_;
        zchf_.approve(address(zchf_.reserve()), type(uint256).max);
    }

    // ==================== Asset info ====================

    function asset() public view returns (address) {
        return address(ZCHF);
    }

    function totalAssets() public view returns (uint256) {
        return FPS1.calculateProceeds(totalSupply());
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return _divD18(assets, ask());
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return _mulD18(shares, bid());
    }

    /**
     * @notice The investment price of one FPS2 in ZCHF, equal to the underlying FPS price.
     */
    function ask() public view returns (uint256) {
        return FPS1.price();
    }

    /**
     * @notice The marginal redemption price of one FPS2 in ZCHF, reflecting the current discount.
     */
    function bid() public view returns (uint256) {
        uint256 recent = weightedRecentRedemptions();
        return _mulD18(FPS1.price(), discount(recent, 0));
    }

    // ==================== Deposit & Mint ====================

    function maxDeposit(address) public pure returns (uint256) {
        return type(uint256).max;
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        return FPS1.calculateShares(assets);
    }

    /**
     * @notice Deposit ZCHF and receive FPS2 shares. The ZCHF is invested into Equity (FPS1)
     * at the unaltered price.
     */
    function deposit(uint256 assets, address receiver) public returns (uint256 shares) {
        return _deposit(receiver, assets);
    }

    /**
     * @notice Deposit ZCHF to receive FPS2 tokens with slippage protection.
     * @param amount          ZCHF to invest
     * @param expectedShares  Minimum FPS2 shares expected
     * @return The number of FPS2 shares minted
     */
    function deposit(uint256 amount, uint256 expectedShares) external returns (uint256) {
        uint256 shares = _deposit(msg.sender, amount);
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

    function maxMint(address) public pure returns (uint256) {
        return type(uint256).max;
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        return _findAssetsForShares(shares);
    }

    /**
     * @notice Mint exactly the requested FPS2 shares by depositing the necessary ZCHF.
     * The required amount is found via binary search on the cubic root pricing curve.
     */
    function mint(uint256 shares, address receiver) public returns (uint256) {
        uint256 assets = _findAssetsForShares(shares);
        ZCHF.transferFrom(msg.sender, address(this), assets);
        uint256 actualShares = FPS1.invest(assets, shares);
        _mint(receiver, actualShares);
        _notifyInvestment(actualShares);
        emit Deposit(msg.sender, receiver, assets, actualShares);
        return assets;
    }

    /**
     * @notice Binary search for the minimum ZCHF needed to receive at least the given number of FPS shares.
     */
    function _findAssetsForShares(uint256 shares) internal view returns (uint256) {
        if (shares == 0) return 0;
        uint256 lo = _mulD18(shares, FPS1.price());
        uint256 hi = lo + lo / 5 + 1;
        while (FPS1.calculateShares(hi) < shares) {
            hi *= 2;
        }
        while (lo < hi) {
            uint256 mid = lo + (hi - lo) / 2;
            if (FPS1.calculateShares(mid) >= shares) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }
        return lo;
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

    function calculateEffectiveProceeds(uint256 recent, uint256 latest, uint256 proceeds) internal view returns (uint256) {
        return _mulD18(proceeds, discount(recent, latest));
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

    /**
     * @notice Binary search for the minimum FPS2 shares to redeem in order to receive at least the given ZCHF amount.
     */
    function _findSharesForAssets(uint256 assets) internal view returns (uint256) {
        if (assets == 0) return 0;
        uint256 recent = weightedRecentRedemptions();
        uint256 lo = _divD18(assets, FPS1.price());
        uint256 hi = lo + lo / 5 + 1;
        while (calculateEffectiveProceeds(recent, hi, FPS1.calculateProceeds(hi)) < assets) {
            hi *= 2;
        }
        while (lo < hi) {
            uint256 mid = lo + (hi - lo) / 2;
            if (calculateEffectiveProceeds(recent, mid, FPS1.calculateProceeds(mid)) >= assets) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }
        return lo;
    }

    function maxRedeem(address owner) public view returns (uint256) {
        return balanceOf(owner);
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return calculateEffectiveProceeds(weightedRecentRedemptions(), shares, FPS1.calculateProceeds(shares));
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
    
    function _redeem(address from, address to, uint256 shares) internal returns (uint256) {
        if (msg.sender != from) _useAllowance(from, msg.sender, shares);

        uint256 recent = weightedRecentRedemptions();
        _burn(from, shares);
        uint256 rawProceeds = FPS1.redeem(address(this), shares);
        uint256 effectiveProceeds = calculateEffectiveProceeds(recent, shares, rawProceeds);

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
        uint256 currentSupply = totalSupply();
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
