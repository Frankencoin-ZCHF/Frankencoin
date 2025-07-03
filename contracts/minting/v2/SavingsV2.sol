// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../../erc20/ERC20.sol";
import "../v1/IFrankencoin.sol";
import "../v1/IReserve.sol";
import "./LeadrateV2.sol";

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
contract SavingsV2 is LeadrateV2 {
    uint64 public immutable INTEREST_DELAY = uint64(3 days);

    IERC20 public immutable zchf;

    mapping(address => Account) public savings;

    struct Account {
        uint192 saved;
        uint64 ticks;
    }

    event Saved(address indexed account, uint192 amount);
    event InterestCollected(address indexed account, uint256 interest);
    event Withdrawn(address indexed account, uint192 amount);

    error FundsLocked(uint40 remainingSeconds);

    // The module is considered disabled if the interest is zero or about to become zero within three days.
    error ModuleDisabled();

    constructor(IFrankencoin zchf_, uint24 initialRatePPM) LeadrateV2(IReserve(zchf_.reserve()), initialRatePPM) {
        zchf = IERC20(zchf_);
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
                (IFrankencoin(address(zchf))).coverLoss(address(this), earnedInterest);
                account.saved += earnedInterest;
                emit InterestCollected(accountOwner, earnedInterest);
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

    function calculateInterest(Account memory account, uint64 ticks) public view returns (uint192) {
        if (ticks <= account.ticks || account.ticks == 0) {
            return 0;
        } else {
            uint192 earnedInterest = uint192((uint256(ticks - account.ticks) * account.saved) / 1000000 / 365 days);
            uint256 equity = IFrankencoin(address(zchf)).equity();
            if (earnedInterest > equity) {
                return uint192(equity); // save conversion as equity is smaller than uint192 earnedInterest
            } else {
                return earnedInterest;
            }
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
        if (nextRatePPM == 0 && (nextChange <= block.timestamp + INTEREST_DELAY)) revert ModuleDisabled();
        Account storage balance = refresh(owner);
        zchf.transferFrom(msg.sender, address(this), amount);
        uint64 ticks = currentTicks();
        assert(balance.ticks >= ticks);
        uint256 saved = balance.saved;
        uint64 weightedAverage = uint64((saved * (balance.ticks - ticks) + uint256(amount) * currentRatePPM * INTEREST_DELAY) / (saved + amount));
        balance.saved += amount;
        balance.ticks = ticks + weightedAverage;
        emit Saved(owner, amount);
    }

    /**
     * Withdraw up to 'amount' to the target address.
     * When trying to withdraw more than available, all that is available is withdrawn.
     * Returns the acutally transferred amount.
     *
     * Fails if the funds in the account have not been in the account for long enough.
     */
    function withdraw(address target, uint192 amount) public returns (uint256) {
        Account storage account = refresh(msg.sender);
        if (account.ticks > currentTicks()) {
            revert FundsLocked(uint40(account.ticks - currentTicks()) / currentRatePPM);
        } else if (amount >= account.saved) {
            amount = account.saved;
            delete savings[msg.sender];
        } else {
            account.saved -= amount;
        }
        zchf.transfer(target, amount);
        emit Withdrawn(msg.sender, amount);
        return amount;
    }
}
