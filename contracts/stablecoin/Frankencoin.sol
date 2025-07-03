// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../erc20/ERC20PermitLight.sol";
import "../equity/IGovernance.sol";
import "../equity/Equity.sol";
import "./IBasicFrankencoin.sol";
import "./IFrankencoin.sol";

/**
 * @title FrankenCoin
 * @notice The Frankencoin (ZCHF) is an ERC-20 token that is designed to track the value of the Swiss franc.
 * It is not upgradable, but open to arbitrary minting plugins. These are automatically accepted if none of the
 * qualified pool share holders casts a veto, leading to a flexible but conservative governance.
 */
contract Frankencoin is ERC20PermitLight, IFrankencoin {
    /**
     * @notice Minimal fee and application period when suggesting a new minter.
     */
    uint256 public constant MIN_FEE = 1000 * (10 ** 18);
    uint256 public immutable MIN_APPLICATION_PERIOD; // for example 10 days

    /**
     * @notice The contract that holds the reserve.
     */
    IGovernance public immutable override reserve;

    /**
     * @notice How much of the reserve belongs to the minters. Everything else belongs to the pool share holders.
     * Stored with 6 additional digits of accuracy so no rounding is necessary when dealing with parts per
     * million (ppm) in reserve calculations.
     */
    uint256 private minterReserveE6;

    /**
     * @notice Map of minters to approval time stamps. If the time stamp is in the past, the minter contract is allowed
     * to mint Frankencoins.
     */
    mapping(address minter => uint256 validityStart) public minters;

    /**
     * @notice List of positions that are allowed to mint and the minter that registered them.
     */
    mapping(address position => address registeringMinter) public positions;

    event MinterApplied(address indexed minter, uint256 applicationPeriod, uint256 applicationFee, string message);
    event MinterDenied(address indexed minter, string message);
    event Loss(address indexed reportingMinter, uint256 amount);
    event Profit(address indexed reportingMinter, uint256 amount);

    error PeriodTooShort();
    error FeeTooLow();
    error AlreadyRegistered();
    error NotMinter();
    error TooLate();

    modifier minterOnly() {
        if (!isMinter(msg.sender) && !isMinter(positions[msg.sender])) revert NotMinter();
        _;
    }

    /**
     * @notice Initiates the Frankencoin with the provided minimum application period for new plugins
     * in seconds, for example 10 days, i.e. 3600*24*10 = 864000
     */
    constructor(uint256 _minApplicationPeriod) ERC20(18) {
        MIN_APPLICATION_PERIOD = _minApplicationPeriod;
        reserve = new Equity(this);
    }

    function name() external pure override returns (string memory) {
        return "Frankencoin";
    }

    function symbol() external pure override returns (string memory) {
        return "ZCHF";
    }

    function initialize(address _minter, string calldata _message) external {
        require(totalSupply() == 0 && (Equity(address(reserve)).totalSupply() == 0));
        minters[_minter] = block.timestamp;
        emit MinterApplied(_minter, 0, 0, _message);
    }

    /**
     * @notice Publicly accessible method to suggest a new way of minting Frankencoin.
     * @dev The caller has to pay an application fee that is irrevocably lost even if the new minter is vetoed.
     * The caller must assume that someone will veto the new minter unless there is broad consensus that the new minter
     * adds value to the Frankencoin system. Complex proposals should have application periods and applications fees
     * above the minimum. It is assumed that over time, informal ways to coordinate on new minters emerge. The message
     * parameter might be useful for initiating further communication. Maybe it contains a link to a website describing
     * the proposed minter.
     *
     * @param _minter              An address that is given the permission to mint Frankencoins
     * @param _applicationPeriod   The time others have to veto the suggestion, at least MIN_APPLICATION_PERIOD
     * @param _applicationFee      The fee paid by the caller, at least MIN_FEE
     * @param _message             An optional human readable message to everyone watching this contract
     */
    function suggestMinter(
        address _minter,
        uint256 _applicationPeriod,
        uint256 _applicationFee,
        string calldata _message
    ) external override {
        if (_applicationPeriod < MIN_APPLICATION_PERIOD) revert PeriodTooShort();
        if (_applicationFee < MIN_FEE) revert FeeTooLow();
        if (minters[_minter] != 0) revert AlreadyRegistered();
        _collectProfits(address(this), msg.sender, _applicationFee);
        minters[_minter] = block.timestamp + _applicationPeriod;
        emit MinterApplied(_minter, _applicationPeriod, _applicationFee, _message);
    }

    /**
     * @notice Make the system more user friendly by skipping the allowance in many cases.
     * @dev We trust minters and the positions they have created to mint and burn as they please, so
     * giving them arbitrary allowances does not pose an additional risk.
     */
    function _allowance(address owner, address spender) internal view override returns (uint256) {
        uint256 explicit = super._allowance(owner, spender);
        if (explicit > 0) {
            return explicit; // don't waste gas checking minter
        } else if (isMinter(spender) || isMinter(getPositionParent(spender)) || spender == address(reserve)) {
            return INFINITY;
        } else {
            return 0;
        }
    }

    /**
     * @notice The reserve provided by the owners of collateralized positions.
     * @dev The minter reserve can be used to cover losses after the equity holders have been wiped out.
     */
    function minterReserve() public view returns (uint256) {
        return minterReserveE6 / 1000000;
    }

    /**
     * @notice Allows minters to register collateralized debt positions, thereby giving them the ability to mint Frankencoins.
     * @dev It is assumed that the responsible minter that registers the position ensures that the position can be trusted.
     */
    function registerPosition(address _position) external override {
        if (!isMinter(msg.sender)) revert NotMinter();
        positions[_position] = msg.sender;
    }

    /**
     * @notice The amount of equity of the Frankencoin system in ZCHF, owned by the holders of Frankencoin Pool Shares.
     * @dev Note that the equity contract technically holds both the minter reserve as well as the equity, so the minter
     * reserve must be subtracted. All fees and other kind of income is added to the Equity contract and essentially
     * constitutes profits attributable to the pool share holders.
     */
    function equity() public view returns (uint256) {
        uint256 balance = balanceOf(address(reserve));
        uint256 minReserve = minterReserve();
        if (balance <= minReserve) {
            return 0;
        } else {
            return balance - minReserve;
        }
    }

    /**
     * @notice Qualified pool share holders can deny minters during the application period.
     * @dev Calling this function is relatively cheap thanks to the deletion of a storage slot.
     */
    function denyMinter(address _minter, address[] calldata _helpers, string calldata _message) external override {
        if (block.timestamp > minters[_minter]) revert TooLate();
        reserve.checkQualified(msg.sender, _helpers);
        delete minters[_minter];
        emit MinterDenied(_minter, _message);
    }

    /**
     * @notice Mints the provided amount of ZCHF to the target address, automatically forwarding
     * the minting fee and the reserve to the right place.
     */
    function mintWithReserve(
        address _target,
        uint256 _amount,
        uint32 _reservePPM,
        uint32 _feesPPM
    ) external override minterOnly {
        uint256 usableMint = (_amount * (1000_000 - _feesPPM - _reservePPM)) / 1000_000; // rounding down is fine
        _mint(_target, usableMint);
        _mint(address(reserve), _amount - usableMint); // rest goes to equity as reserves or as fees
        minterReserveE6 += _amount * _reservePPM;
        emit Profit(msg.sender, (_feesPPM * _amount) / 1000_000);
    }

    function mint(address _target, uint256 _amount) external override minterOnly {
        _mint(_target, _amount);
    }

    /**
     * Anyone is allowed to burn their ZCHF.
     */
    function burn(uint256 _amount) external {
        _burn(msg.sender, _amount);
    }

    /**
     * @notice Burn someone elses ZCHF.
     */
    function burnFrom(address _owner, uint256 _amount) external override minterOnly {
        _burn(_owner, _amount);
    }

    /**
     * @notice Burn that amount without reclaiming the reserve, but freeing it up and thereby essentially donating it to the
     * pool share holders. This can make sense in combination with 'coverLoss', i.e. when it is the pool share
     * holders that bear the risk and depending on the outcome they make a profit or a loss.
     *
     * Design rule: Minters calling this method are only allowed to so for tokens amounts they previously minted with
     * the same _reservePPM amount.
     *
     * For example, if someone minted 50 ZCHF earlier with a 20% reserve requirement (200000 ppm), they got 40 ZCHF
     * and paid 10 ZCHF into the reserve. Now they want to repay the debt by burning 50 ZCHF. When doing so using this
     * method, 50 ZCHF get burned and on top of that, 10 ZCHF previously assigned to the minter's reserved are
     * reassigned to the pool share holders.
     *
     * CS-ZCHF2-009: the Profit event can overstate profits in case there is no equity capital left.
     */
    function burnWithoutReserve(uint256 amount, uint32 reservePPM) public override minterOnly {
        _burn(msg.sender, amount);
        uint256 reserveReduction = amount * reservePPM;
        if (reserveReduction > minterReserveE6) {
            emit Profit(msg.sender, minterReserveE6 / 1000_000);
            minterReserveE6 = 0; // should never happen, but we want robust behavior in case it does
        } else {
            minterReserveE6 -= reserveReduction;
            emit Profit(msg.sender, reserveReduction / 1000_000);
        }
    }

    /**
     * @notice Burns the provided number of tokens plus whatever reserves are associated with that amount given the reserve
     * requirement. The caller is only allowed to use this method for tokens also minted through the caller with the
     * same _reservePPM amount.
     *
     * Example: the calling contract has previously minted 100 ZCHF with a reserve ratio of 20% (i.e. 200000 ppm).
     * Now they have 41 ZCHF that they do not need so they decide to repay that amount. Assuming the reserves are
     * only 90% covered, the call to burnWithReserve will burn the 41 plus 9 from the reserve, reducing the outstanding
     * 'debt' of the caller by 50 ZCHF in total. This total is returned by the method so the caller knows how much less
     * they owe.
     */
    function burnWithReserve(
        uint256 _amountExcludingReserve,
        uint32 _reservePPM
    ) external override minterOnly returns (uint256) {
        uint256 freedAmount = calculateFreedAmount(_amountExcludingReserve, _reservePPM); // 50 in the example
        minterReserveE6 -= freedAmount * _reservePPM; // reduce reserve requirements by original ratio
        _transfer(address(reserve), msg.sender, freedAmount - _amountExcludingReserve); // collect assigned reserve
        _burn(msg.sender, freedAmount); // burn the rest of the freed amount
        return freedAmount;
    }

    /**
     * @notice Burns the target amount taking the tokens to be burned from the payer and the payer's reserve.
     * Only use this method for tokens also minted by the caller with the same _reservePPM.
     *
     * Example: the calling contract has previously minted 100 ZCHF with a reserve ratio of 20% (i.e. 200000 ppm).
     * To burn half of that again, the minter calls burnFrom with a target amount of 50 ZCHF. Assuming that reserves
     * are only 90% covered, this call will deduct 41 ZCHF from the payer's balance and 9 from the reserve, while
     * reducing the minter reserve by 10.
     */
    function burnFromWithReserve(
        address payer,
        uint256 targetTotalBurnAmount,
        uint32 reservePPM
    ) external override minterOnly returns (uint256) {
        uint256 assigned = calculateAssignedReserve(targetTotalBurnAmount, reservePPM);
        _transfer(address(reserve), payer, assigned); // send reserve to owner
        _burn(payer, targetTotalBurnAmount); // and burn the full amount from the owner's address
        minterReserveE6 -= targetTotalBurnAmount * reservePPM; // reduce reserve requirements by original ratio
        return assigned;
    }

    /**
     * @notice Calculates the reserve attributable to someone who minted the given amount with the given reserve requirement.
     * Under normal circumstances, this is just the reserve requirement multiplied by the amount. However, after a
     * severe loss of capital that burned into the minter's reserve, this can also be less than that.
     */
    function calculateAssignedReserve(uint256 mintedAmount, uint32 _reservePPM) public view returns (uint256) {
        uint256 theoreticalReserve = (_reservePPM * mintedAmount) / 1000000;
        uint256 currentReserve = balanceOf(address(reserve));
        uint256 minterReserve_ = minterReserve();
        if (currentReserve < minterReserve_) {
            // not enough reserves, owner has to take a loss
            return (theoreticalReserve * currentReserve) / minterReserve_;
        } else {
            return theoreticalReserve;
        }
    }

    /**
     * @notice Calculate the amount that is freed when returning amountExcludingReserve given a reserve ratio of reservePPM,
     * taking into account potential losses. Example values in the comments.
     */
    function calculateFreedAmount(
        uint256 amountExcludingReserve /* 41 */,
        uint32 reservePPM /* 20% */
    ) public view returns (uint256) {
        uint256 currentReserve = balanceOf(address(reserve)); // 18, 10% below what we should have
        uint256 minterReserve_ = minterReserve(); // 20
        uint256 adjustedReservePPM = currentReserve < minterReserve_
            ? (reservePPM * currentReserve) / minterReserve_
            : reservePPM; // 18%
        return (1000000 * amountExcludingReserve) / (1000000 - adjustedReservePPM); // 41 / (1-18%) = 50
    }

    /**
     * @notice Notify the Frankencoin that a minter lost economic access to some coins. This does not mean that the coins are
     * literally lost. It just means that some ZCHF will likely never be repaid and that in order to bring the system
     * back into balance, the lost amount of ZCHF must be removed from the reserve instead.
     *
     * For example, if a minter printed 1 million ZCHF for a mortgage and the mortgage turned out to be unsound with
     * the house only yielding 800'000 in the subsequent auction, there is a loss of 200'000 that needs to be covered
     * by the reserve.
     */
    function coverLoss(address source, uint256 _amount) external override minterOnly {
        uint256 reserveLeft = balanceOf(address(reserve));
        if (reserveLeft >= _amount) {
            _transfer(address(reserve), source, _amount);
        } else {
            _transfer(address(reserve), source, reserveLeft);
            _mint(source, _amount - reserveLeft);
        }
        emit Loss(source, _amount);
    }

    function collectProfits(address source, uint256 _amount) external override minterOnly {
        _collectProfits(msg.sender, source, _amount);
    }

    function _collectProfits(address minter, address source, uint256 _amount) internal {
        _transfer(source, address(reserve), _amount);
        emit Profit(minter, _amount);
    }

    /**
     * @notice Returns true if the address is an approved minter.
     */
    function isMinter(address _minter) public view override returns (bool) {
        return minters[_minter] != 0 && block.timestamp >= minters[_minter];
    }

    /**
     * @notice Returns the address of the minter that created this position or null if the provided address is unknown.
     */
    function getPositionParent(address _position) public view override returns (address) {
        return positions[_position];
    }
}
