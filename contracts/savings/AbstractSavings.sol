// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../stablecoin/IFrankencoin.sol";
import "../rate/AbstractLeadrate.sol";

/**
 * @title Savings
 *
 * Module to enable savings based on a Leadrate ("Leitzins") module.
 *
 * As the interest rate changes, the speed at which 'ticks' are accumulated is
 * adjusted. The ticks counter serves as the basis for calculating the interest
 * due for the individual accoutns.
 *
 * The saved ZCHF are subject to a lockup of up to 3 days and only start to yield
 * an interest after the lockup ended. The purpose of this lockup is to discourage
 * short-term holdings and to avoid paying interest to transactional accounts.
 * Transactional accounts typically do not need an incentive to hold Frankencoins.
 */
abstract contract AbstractSavings is AbstractLeadrate {
    
    uint64 public immutable INTEREST_DELAY = uint64(3 days);

    IFrankencoin public immutable ZCHF;

    mapping(address => Account) public savings;

    struct Account {
        uint192 saved;
        uint64 ticks;
        address referrer;
        uint32 referralFeePPM;
    }

    event Saved(address indexed account , uint192 amount);
    event InterestCollected(address indexed account, uint256 interest, uint256 referrerFee);
    event Withdrawn(address indexed account, uint192 amount);

    error FundsLocked(uint40 remainingSeconds);

    // The module is considered disabled if the interest is zero or about to become zero within three days.
    error ModuleDisabled();

    error ReferralFeeTooHigh(uint32 fee);

    constructor(IFrankencoin zchf){
        ZCHF = zchf;
    }

    /**
     * Shortcut for refreshBalance(msg.sender)
     */
    function refreshMyBalance() public returns (uint192) {
        return refreshBalance(msg.sender);
    }

    /**
     * Collects the accrued interest and adds it to the account.
     *
     * It can be beneficial to do so every now and then in order to start collecting
     * interest on the accrued interest.
     */
    function refreshBalance(address owner) public returns (uint192) {
        return refresh(owner).saved;
    }

    function refresh(address accountOwner) internal returns (Account storage) {
        Account storage account = savings[accountOwner];
        uint64 ticks = currentTicks();
        if (ticks > account.ticks) {
            uint192 earnedInterest = calculateInterest(account, ticks);
            if (earnedInterest > 0) {
                // collect interest as you go and trigger accounting event
                ZCHF.coverLoss(address(this), earnedInterest);
                uint192 referralFee = deductTransferReferralFee(account, earnedInterest);
                account.saved += (earnedInterest - referralFee);
                emit InterestCollected(accountOwner, earnedInterest, referralFee);
            }
            account.ticks = ticks;
        }
        return account;
    }

    function accruedInterest(address accountOwner) public view returns (uint192) {
        return accruedInterest(accountOwner, block.timestamp);
    }

    function accruedInterest(address accountOwner, uint256 timestamp) public view returns (uint192) {
        Account memory account = savings[accountOwner];
        return calculateInterest(account, ticks(timestamp));
    }

    function calculateInterest(Account memory account, uint64 ticks) public pure returns (uint192) {
        if (ticks <= account.ticks || account.ticks == 0) {
            return 0;
        } else {
            return uint192((uint256(ticks - account.ticks) * account.saved) / 1000000 / 365 days);
        }
    }
    
    /**
     * Save 'amount'.
     */
    function save(uint192 amount) public {
        save(msg.sender, amount);
    }

    function adjust(uint192 targetAmount) public {
        Account storage balance = refresh(msg.sender);
        if (balance.saved < targetAmount) {
            save(targetAmount - balance.saved);
        } else if (balance.saved > targetAmount) {
            withdraw(msg.sender, balance.saved - targetAmount);
        }
    }

    /**
     * Send 'amount' to the account of the provided owner.
     * The funds sent to the account are locked for a while, depending on how much already is in there.
     */
    function save(address owner, uint192 amount) public {
        if (currentRatePPM == 0) revert ModuleDisabled();
       // if (nextRatePPM == 0 && (nextChange <= block.timestamp + INTEREST_DELAY)) revert ModuleDisabled(); TODO: figure out why this was in there
        Account storage balance = refresh(owner);
        ZCHF.transferFrom(msg.sender, address(this), amount);
        uint64 ticks = currentTicks();
        assert(balance.ticks >= ticks);
        uint256 saved = balance.saved;
        uint64 weightedAverage = uint64(
            (saved * (balance.ticks - ticks) + uint256(amount) * currentRatePPM * INTEREST_DELAY) / (saved + amount)
        );
        balance.saved += amount;
        balance.ticks = ticks + weightedAverage;
        emit Saved(owner, amount);
    }

    /**
     * Withdraw up to 'amount' to the target address.
     * When trying to withdraw more than available, all that is available is withdrawn.
     * Returns the acutally transferred amount.
     */
    function withdraw(address target, uint192 amount) public returns (uint256) {
        Account storage account = refresh(msg.sender);
        if (amount >= account.saved) {
            amount = account.saved;
            delete savings[msg.sender];
        } else {
            account.saved -= amount;
        }
        ZCHF.transfer(target, amount);
        emit Withdrawn(msg.sender, amount);
        return amount;
    }

    /**
     * REFERRAL LOGIC
     * 
     * The following functions can be used by a frontend or wallet contains functions to
     * access the savings features of the Frankencoin system. It allows the frontend or
     * wallet to set a referrer and a referral fee when calling save or adjust, but not
     * when withdrawing. The referral fee can be up to 25% (250'000 ppm). It is deducted
     * from the collected interest.
     * 
     * The user can drop or change the referrer at any time, so the fee is not very sticky.
     * The magnitude of the fee that can be charged mainly depends on how convenient the
     * frontend or wallet is in comparison to the user directly interfering with the system
     * himself. So economically, it really is a frontend fee that can only be charged to
     * the extent that the frontend provides a more convenient way of interaction with the
     * protocol and the users are willing to pay for that convenience.
     */

    /**
     * Save the given amount and set the referrer to earn a fee on the collected interest.
     * 
     * Referral fee is given in parts per million and can be at most 250'000, which is 25%.
     */
    function save(uint192 amount, address referrer, uint24 referralFeePPM) public {
        save(msg.sender, amount);
        setReferrer(referrer, referralFeePPM);
    }

    /**
     * Withdraw the given amount and set the referrer to earn a fee on the collected interest.
     * 
     * Referral fee is given in parts per million and can be at most 250'000, which is 25%.
     */
    function withdraw(uint192 amount, address referrer, uint24 referralFeePPM) public {
        withdraw(msg.sender, amount);
        setReferrer(referrer, referralFeePPM);
    }

    /**
     * Adjust to the given amount and set the referrer to earn a fee on the collected interest.
     * 
     * Referral fee is given in parts per million and can be at most 250'000, which is 25%.
     */
    function adjust(uint192 targetAmount, address referrer, uint24 referralFeePPM) public {
        adjust(targetAmount);
        setReferrer(referrer, referralFeePPM);
    }

    /**
     * Remove the referrer.
     */
    function dropReferrer() public {
        refresh(msg.sender); // pay accrued referral fee before dropping referrer
        setReferrer(address(0x0), 0);
    }

    function setReferrer(address referrer, uint32 referralFeePPM) internal {
        if (referralFeePPM > 250_000) revert ReferralFeeTooHigh(referralFeePPM); // don't allow more than 25%
        savings[msg.sender].referrer = referrer;
        savings[msg.sender].referralFeePPM = referralFeePPM;
    }

    function deductTransferReferralFee(Account memory balance, uint192 earnedInterest) internal returns (uint192) {
        if (balance.referrer != address(0x0)){
            uint256 referralFee = uint256(earnedInterest) * balance.referralFeePPM / 1000000;
            ZCHF.transfer(balance.referrer, referralFee);
            return uint192(referralFee);
        } else {
            return 0;
        }
    }

}

interface IInterestSource {
    function coverLoss(address source, uint256 amount) external;
}
