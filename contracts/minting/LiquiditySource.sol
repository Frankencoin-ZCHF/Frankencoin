// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../interface/IERC20.sol";
import "../interface/IFrankencoin.sol";
import "../utils/Ownable.sol";

/**
 * Untested proof of concept to help a market maker or similar ecosystem contributor getting liquidity
 * under a set of binding commitments made in the initialize function. After initialization, the contract
 * is subject to the minter approval process.
 */
contract LiquiditySource is Ownable {
    IFrankencoin public constant ZCHF = IFrankencoin(0xB58E61C3098d85632Df34EecfB899A1Ed80921cB);
    uint256 public constant MIN_EXTERNAL_REPAYMENT = 100_000 * 1e18; // 100k ZCHF

    uint256 public immutable LIMIT;
    uint256 public immutable MATURITY;

    uint256 public minted;
    string public termsUrl;

    error InvalidParameters();
    error AlreadyInitialized();
    error LimitExceeded(uint256 max);
    error MaturityReached();
    error TooEarly();
    error RepaymentTooSmall(uint256 minted);

    event Minted(uint256 amount, uint256 newTotal);
    event Repaid(uint256 amount, uint256 newTotal);
    event CompensationOwed(address owner, string ref, uint256 amount);

    constructor(uint256 limit, uint256 maturityDate) {
        _setOwner(msg.sender);
        LIMIT = limit;
        MATURITY = maturityDate;
        minted = 0;
    }

    /**
     * Initialize the contract with the hash of and the link to the legal obligations of the owner.
     * Typically, the owner would legally commit to repay the outstanding amount fully before the
     * maturity date is reached. The owner would further commit that if they fail to repay the
     * outstanding amount in time, that they would owe the repaid amount plus a penalty to anyone
     * who repaid some or all of the outstanding amount using the 'repay' function.
     *
     * Initialization requires this contract to be funded with 1000 ZCHF to cover the application fee.
     *
     * It is the responsibility of the governance token holders verify the legal commitment made
     * by the applicants and to deny minting privileges if the commitments are deemed insufficient.
     */
    function initialize(string calldata termsUrl_) external onlyOwner {
        if (bytes(termsUrl).length > 0) revert AlreadyInitialized();
        if (bytes(termsUrl_).length == 0) revert InvalidParameters();
        termsUrl = termsUrl_;
        ZCHF.suggestMinter(address(this), ZCHF.MIN_APPLICATION_PERIOD(), ZCHF.MIN_FEE(), termsUrl_);
    }

    /**
     * Update the URL where the terms pdf can be found.
     * The terms themselves cannot be changed.
     */
    function updateTermsUrl(string calldata termsUrl_) external onlyOwner {
        if (bytes(termsUrl_).length == 0) revert InvalidParameters();
        termsUrl = termsUrl_;
    }

    /**
     * Mint new Frankencoins up to the limit.
     */
    function mint(address target, uint256 amount) external onlyOwner {
        if (block.timestamp > MATURITY) revert MaturityReached();
        if (minted + amount > LIMIT) revert LimitExceeded(LIMIT - minted);
        minted += amount;
        ZCHF.mint(target, amount);
        emit Minted(amount, minted);
    }

    /**
     * Repay some of the outstanding balance.
     * Anyone can call this, but it only makes sense for the owner to do so.
     */
    function burn(uint256 amount) public {
        if (amount > minted) revert LimitExceeded(minted);
        minted -= amount;
        ZCHF.burnFrom(msg.sender, amount);
        emit Repaid(amount, minted);
    }

    /**
     * Anyone who repays after maturity will be able to make a claim against the owner under the
     * published terms. This claim would typically include the repaid amount plus a penalty.
     * There is a minimum repayment amount that must be respected.
     *
     * The sender can speficy a reference number to help with the processing of the payment.
     */
    function repay(uint256 amount, string calldata ref) external {
        if (block.timestamp <= MATURITY) revert TooEarly();
        if (amount < MIN_EXTERNAL_REPAYMENT && amount < minted) revert RepaymentTooSmall(minted);
        burn(amount);
        emit CompensationOwed(msg.sender, ref, amount);
    }
}
