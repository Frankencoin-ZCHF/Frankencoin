// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./FPS2Governance.sol";
import "../Equity.sol";
import "../../utils/MathUtil.sol";
import "../../erc20/ERC20.sol";
import "../../erc20/IERC4626.sol";

/**
 * @title FPS2MintRedeem
 * @notice ERC-4626 tokenized vault around Frankencoin Pool Shares (FPS).
 * Users deposit ZCHF, which is invested into FPS via Equity. Redemptions apply a discount
 * based on an 8th-power curve that increases with recent redemption volume.
 * The spread (undiscounted portion) is returned to the Equity contract.
 *
 * ERC-4626 note: `mint` and `withdraw` are not supported (maxMint/maxWithdraw return 0)
 * because the cubic root pricing of Equity and the discount curve make exact inversion infeasible.
 */
abstract contract FPS2MintRedeem is ERC20, MathUtil, IERC4626 {

    uint256 public constant RECOVERY_PERIOD = 30 days;

    IEquity public immutable FPS1;

    // --- Spread mechanism (tracks net redemption volume in FPS shares) ---
    uint192 public recentlyRedeemed;
    uint64 public lastRedemption;

    event Trade(address who, int amount, uint totPrice);

    error NotSupported();

    constructor(IEquity fps1_) {
        FPS1 = fps1_;
    }

    // ==================== ERC-4626: Asset info ====================

    function asset() public view returns (address) {
        return address(ZCHF);
    }

    function totalAssets() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        return FPS1.calculateProceeds(supply);
    }

    // ==================== ERC-4626: Conversions ====================

    function convertToShares(uint256 assets) public view returns (uint256) {
        return FPS1.calculateShares(assets);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        if (shares == 0) return 0;
        return FPS1.calculateProceeds(shares);
    }

    // ==================== ERC-4626: Max ====================

    function maxDeposit(address) public pure returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) public pure returns (uint256) {
        return 0;
    }

    function maxWithdraw(address) public pure returns (uint256) {
        return 0;
    }

    function maxRedeem(address owner) public view returns (uint256) {
        return balanceOf(owner);
    }

    // ==================== ERC-4626: Previews ====================

    function previewDeposit(uint256 assets) public view returns (uint256) {
        return FPS1.calculateShares(assets);
    }

    function previewMint(uint256) public pure returns (uint256) {
        revert NotSupported();
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return calculateEffectiveProceeds(shares);
    }

    function previewWithdraw(uint256) public pure returns (uint256) {
        revert NotSupported();
    }

    // ==================== ERC-4626: Deposit / Mint ====================

    /**
     * @notice Deposit ZCHF and receive FPS2 shares. The ZCHF is invested into Equity (FPS1)
     * at the unaltered price.
     */
    function deposit(uint256 assets, address receiver) public returns (uint256 shares) {
        shares = _invest(msg.sender, receiver, assets);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256, address) public pure returns (uint256) {
        revert NotSupported();
    }

    // ==================== ERC-4626: Withdraw / Redeem ====================

    function withdraw(uint256, address, address) public pure returns (uint256) {
        revert NotSupported();
    }

    /**
     * @notice Burn FPS2 shares from owner and send ZCHF proceeds to receiver.
     * If caller is not owner, requires ERC-20 allowance.
     */
    function redeem(uint256 shares, address receiver, address owner) public returns (uint256 assets) {
        if (msg.sender != owner) {
            _useAllowance(owner, msg.sender, shares);
        }
        assets = _redeem(owner, receiver, shares);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    // ==================== Frankencoin-specific interface ====================

    /**
     * @notice Invest ZCHF to receive FPS2 tokens with slippage protection.
     * @param amount          ZCHF to invest
     * @param expectedShares  Minimum FPS2 shares expected
     * @return The number of FPS2 shares minted
     */
    function invest(uint256 amount, uint256 expectedShares) external returns (uint256) {
        uint256 shares = _invest(msg.sender, msg.sender, amount);
        require(shares >= expectedShares);
        return shares;
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

    // ==================== Pricing ====================

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

    /**
     * @notice Preview the effective proceeds after discount for selling the given number of shares.
     */
    function calculateEffectiveProceeds(uint256 shares) public view returns (uint256) {
        uint256 recent = weightedRecentRedemptions();
        return _mulD18(FPS1.calculateProceeds(shares), discount(recent, shares));
    }

    // ==================== Discount ====================

    /**
     * @notice Calculate the discount factor for a redemption using an 8th-power curve.
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

    function _invest(address from, address to, uint256 amount) internal returns (uint256 shares) {
        ZCHF.transferFrom(from, address(this), amount);
        shares = FPS1.invest(amount, 0);
        _mint(to, shares);
        _notifyInvestment(shares);
        emit Trade(to, int(shares), amount);
    }

    function _redeem(address from, address to, uint256 shares) internal returns (uint256 effectiveProceeds) {
        uint256 recent = weightedRecentRedemptions();
        uint256 discountFactor = discount(recent, shares);

        _burn(from, shares);
        uint256 rawProceeds = FPS1.redeem(address(this), shares);
        effectiveProceeds = _mulD18(rawProceeds, discountFactor);

        recentlyRedeemed = uint192(recent + shares);
        lastRedemption = uint64(block.timestamp);

        ZCHF.transfer(to, effectiveProceeds);
        ZCHF.transfer(address(FPS1), rawProceeds - effectiveProceeds);

        emit Trade(from, -int(shares), effectiveProceeds);
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
