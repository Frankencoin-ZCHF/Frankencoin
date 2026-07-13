// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../erc20/IERC20.sol";
import "../stablecoin/IFrankencoin.sol";

/**
 * @title Stable Coin Bridge
 * @notice A minting contract for another Swiss franc stablecoin ('source stablecoin') that we trust.
 * @author Frankencoin
 */
contract StablecoinBridge {

    IERC20 public immutable chf; // the source stablecoin
    IFrankencoin public immutable zchf; // the Frankencoin

    /**
     * @notice The time horizon after which this bridge expires and needs to be replaced by a new contract.
     */
    uint256 public immutable horizon;

    /**
     * @notice The decimal difference between ZCHF and the source stablecoin.
     */
    uint256 public immutable decimalMultiplier;

    /**
     * The maximum amount of outstanding converted source stablecoins.
     */
    uint256 public immutable limit;
    uint256 public minted;

    mapping (address => uint256) public credits;

    event Mint(address indexed target, uint256 amount);
    event Burn(address indexed zchfHolder, uint256 amount);
    event Credit(address indexed target, uint256 amount);
    event Payout(address indexed target, uint256 amount);

    error Limit(uint256 amount, uint256 limit);
    error Expired(uint256 time, uint256 expiration);

    /**
     * Construct the swap bridge.
     * 
     * Other is the address of a trusted CHF stablecoin that we will allow minting against. It can have at most 18 decimals and 
     * the number of decimals must be constant over time. The bridge will mint 1 Frankencoin for each unit of the source stablecoin.
     */
    constructor(address other, address zchfAddress, uint256 limit_) {
        chf = IERC20(other);
        zchf = IFrankencoin(zchfAddress);
        horizon = block.timestamp + 52 weeks;
        decimalMultiplier = 10 ** (zchf.decimals() - chf.decimals());
        limit = limit_;
        minted = 0;
    }

    /**
     * @notice Convenience method for mint(msg.sender, amount)
     */
    function mint(uint256 amount) external {
        mintTo(msg.sender, amount);
    }

    /**
     * @notice Mint the target amount of Frankencoins, taking the equal amount of source coins from the sender.
     * @dev This only works if an allowance for the source coins has been set and the caller has enough of them.
     */
    function mintTo(address target, uint256 amount) public {
        chf.transferFrom(msg.sender, address(this), amount);
        _mint(target, amount * decimalMultiplier);
    }

    function _mint(address target, uint256 zchfAmount) internal {
        if (block.timestamp > horizon) revert Expired(block.timestamp, horizon);
        zchf.mint(target, zchfAmount);
        minted += zchfAmount;
        if (minted > limit) revert Limit(zchfAmount, limit);
        emit Mint(target, zchfAmount);
    }

    /**
     * @notice Convenience method for burnAndSend(msg.sender, amount)
     */
    function burn(uint256 zchfAmount) external {
        uint256 chfAmount = zchfAmount / decimalMultiplier;
        _burn(msg.sender, chfAmount * decimalMultiplier);
        chf.transfer(msg.sender, chfAmount);
    }

    /**
     * @notice Burn the indicated amount of Frankencoin and send the same number of source coin to the caller.
     */
    function burnAndSend(address target, uint256 zchfAmount) external {
        uint256 chfAmount = zchfAmount / decimalMultiplier;
        _burn(msg.sender, chfAmount * decimalMultiplier);
        chf.transfer(target, chfAmount);
    }

    /**
     * Burn the indicated amount of Frankencoin and credit the same amount to the target address.
     * The target address can then call payoutCredit to receive the source coin.
     * 
     * This can be useful in case the source stablecoin has transfer fees or other transfer restrictions.
     */
    function burnAndCredit(address target, uint256 zchfAmount) external {
        uint256 chfAmount = zchfAmount / decimalMultiplier;
        _burn(msg.sender, chfAmount * decimalMultiplier);
        credits[target] += chfAmount;
        emit Credit(target, chfAmount);
    }

    /**
     * Function to check the credit balance of a target address.
     */
    function balanceOf(address account) external view returns (uint256) {
        return credits[account];
    }

    /**
     * Pays out all the outstanding credit of the target address to the target address.
     * 
     * Anyone can trigger this for any target address. This is to cover the use case where the issuer has frozen
     * the source coin in this contract but still allows withdrawals for specific addresses, in which case the issuer
     * could unfreeze, trigger payouts to compliant users, and then freeze the balance again in a single transaction
     * to satisfy the redemption rights of the beneficial owners according to the credit mapping.
     */
    function payoutCredit(address target) external {
        uint256 amount = credits[target];
        credits[target] = 0;
        chf.transfer(target, amount);
        emit Payout(target, amount);
    }

    function _burn(address zchfHolder, uint256 zchfAmount) internal {
        zchf.burnFrom(zchfHolder, zchfAmount);
        minted -= zchfAmount;
        emit Burn(zchfHolder, zchfAmount);
    }
}
