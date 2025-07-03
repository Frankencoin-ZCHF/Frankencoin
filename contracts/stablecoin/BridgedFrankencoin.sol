// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../erc20/CrossChainReference.sol";
import "../erc20/ERC20PermitLight.sol";
import "../equity/Equity.sol";
import "../equity/IGovernance.sol";
import "../equity/BridgedGovernance.sol";
import "./IBasicFrankencoin.sol";

/**
 * @title Bridged Frankencoin ERC-20 Token
 *
 * Like its mainnet counterpart, it has the capability to add minting modules. This allows to
 * potentially add similar collateralized minting methods as in the mainnet Frankencoin.
 * 
 * Minting modules are extremely powerful. They can mint, move, and burn Frankencoins on arbitrary addresses.
 * A typical minting module is the CCIP Token Manager that mints tokens as they arrive from other chains or
 * burns them when sent away again.
 *
 * The bridged Frankencoin relies on the bridged governance module to veto bad proposals for new minters.
 * 
 * System income (e.g. from proposal fees) is accumualted on the governance address (this could be any address,
 * but on mainnet, it is also the governance module that contains the equity capital). Furthermore, the contract
 * keeps track of accumulated costs (losses), for example when the Savings module pays out interests.
 * 
 * The accumulated profit or loss should be synchronized back to mainnet from time to time using a CCIP
 * message.
 */
contract BridgedFrankencoin is CrossChainReference, ERC20PermitLight, IBasicFrankencoin {
    /**
     * @notice Minimal fee and application period when suggesting a new minter.
     */
    uint256 public constant MIN_FEE = 1000 * (10 ** 18);
    uint256 public immutable MIN_APPLICATION_PERIOD; // for example 10 days
    address public immutable BRIDGE_ACCOUNTING;
    uint64 public immutable MAINNET_CHAIN_SELECTOR;
    address public immutable CCIP_ADMIN;

    /**
     * @notice The contract that holds the reserve.
     */
    IGovernance public immutable override reserve;

    /**
     * @notice Map of minters to approval time stamps. If the time stamp is in the past, the minter contract is allowed
     * to mint Frankencoins.
     */
    mapping(address minter => uint256 validityStart) public minters;

    /**
     * @notice List of positions that are allowed to mint and the minter that registered them.
     * 
     * This is not used in the bridged Frankencoins for now, but can be useful once we want to introduce collateralized
     * minting like on mainnet.
     */
    mapping(address position => address registeringMinter) public positions;

    uint256 public accruedLoss;
    bool public initialized;

    event AccountingSynchronized(uint256 profit, uint256 losses);
    event MinterApplied(address indexed minter, uint256 applicationPeriod, uint256 applicationFee, string message);
    event MinterDenied(address indexed minter, string message);
    event Loss(address indexed reportingMinter, uint256 amount);
    event Profit(address indexed reportingMinter, uint256 amount);

    error PeriodTooShort();
    error FeeTooLow();
    error AlreadyRegistered();
    error NotMinter();
    error TooLate();
    error AlreadyInitialized();
    error InvalidInput();

    modifier minterOnly() {
        if (!isMinter(msg.sender) && !isMinter(positions[msg.sender])) revert NotMinter();
        _;
    }

    /**
     * @notice Initiates the Frankencoin with the provided minimum application period for new plugins
     * in seconds, for example 10 days, i.e. 3600*24*10 = 864000
     */
    constructor(IGovernance reserve_, address router_, uint256 _minApplicationPeriod, address _linkToken, uint64 _mainnetChainSelector, address _bridgeAccounting, address _ccipAdmin) ERC20(18) CrossChainReference(router_, _linkToken) {
        MIN_APPLICATION_PERIOD = _minApplicationPeriod;
        reserve = reserve_;
        MAINNET_CHAIN_SELECTOR = _mainnetChainSelector;
        BRIDGE_ACCOUNTING = _bridgeAccounting;
        CCIP_ADMIN = _ccipAdmin;
    }

    function name() external pure override returns (string memory) {
        return "Frankencoin";
    }

    function symbol() external pure override returns (string memory) {
        return "ZCHF";
    }

    /// @notice Initializes the bridged Frankencoin token.
    /// @dev This function is only callable once.
    /// @param _minters List of addresses that are allowed to mint Frankencoins.
    /// @param _messages List of messages that are displayed to the user when the minter is applied.
    function initialize(address[] calldata _minters, string[] calldata _messages) external {
        if (initialized) revert AlreadyInitialized();
        if (_minters.length != _messages.length) revert InvalidInput();

        for (uint256 i = 0; i < _minters.length; i++) {
            minters[_minters[i]] = block.timestamp;
            emit MinterApplied(_minters[i], 0, 0, _messages[i]);
        }
        initialized = true;
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
    function suggestMinter(address _minter, uint256 _applicationPeriod, uint256 _applicationFee, string calldata _message) external override {
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
     * @notice Allows minters to register collateralized debt positions, thereby giving them the ability to mint Frankencoins.
     * @dev It is assumed that the responsible minter that registers the position ensures that the position can be trusted.
     */
    function registerPosition(address _position) external override {
        if (!isMinter(msg.sender)) revert NotMinter();
        positions[_position] = msg.sender;
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

    function canMint(address _minterOrPosition) public view returns (bool) {
        return isMinter(_minterOrPosition) || isMinter(positions[_minterOrPosition]);
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
    function coverLoss(address source, uint256 _amount) external minterOnly {
        uint256 reserveLeft = balanceOf(address(reserve));
        if (_amount > reserveLeft) {
            accruedLoss += (_amount - reserveLeft);
            _mint(address(reserve), _amount - reserveLeft);
        }
        _transfer(address(reserve), source, _amount);
        emit Loss(source, _amount);
    }

    function collectProfits(address source, uint256 _amount) external override minterOnly {
        _collectProfits(msg.sender, source, _amount);
    }

    function _collectProfits(address minter, address source, uint256 _amount) internal {
        _transfer(source, address(reserve), _amount);
        if (accruedLoss > _amount) {
            accruedLoss -= _amount;
            _burn(address(reserve), _amount);
        } else if (accruedLoss > 0) {
            _burn(address(reserve), accruedLoss);
            accruedLoss = 0;
        }
        emit Profit(minter, _amount);
    }

    function synchronizeAccounting() public payable {
        synchronizeAccounting("");
    }

    function synchronizeAccounting(Client.EVMExtraArgsV2 calldata extraArgs) public payable {
        synchronizeAccounting(Client._argsToBytes(extraArgs));
    }

    /**
     * Uses a multichain call to send home all accrued profits, if any
     */
    function synchronizeAccounting(bytes memory extraArgs) public payable {
        (uint256 reserveLeft, uint256 _accruedLoss, Client.EVMTokenAmount[] memory tokenAmounts) = getSynchronizeAccountingData();

        if (_accruedLoss > 0) {
            accruedLoss = 0;
        }
        if (reserveLeft > 0) {
            _transfer(address(reserve), address(this), reserveLeft);
            _approve(address(this), address(ROUTER), reserveLeft);
        }

        Client.EVM2AnyMessage memory message = _constructMessage(_toReceiver(BRIDGE_ACCOUNTING), abi.encode(reserveLeft, _accruedLoss), tokenAmounts, extraArgs);
        _send(MAINNET_CHAIN_SELECTOR, message);
        emit AccountingSynchronized(reserveLeft, _accruedLoss);
    }

    /**
     * @notice Returns the CCIP fee required to synchronize accounting.
     */
    function getSynchronizeAccountingFee(bool nativeToken) public view returns (uint256) {
        return getSynchronizeAccountingFee(nativeToken, "");
    }

    /**
     * @notice Returns the CCIP fee required to synchronize accounting.
     */
    function getSynchronizeAccountingFee(bool nativeToken, bytes memory extraArgs) public view returns (uint256) {
        (uint256 reserveLeft, uint256 _accruedLoss, Client.EVMTokenAmount[] memory tokenAmounts) = getSynchronizeAccountingData();
        Client.EVM2AnyMessage memory message = _constructMessage(_toReceiver(BRIDGE_ACCOUNTING), abi.encode(reserveLeft, _accruedLoss), tokenAmounts, nativeToken, extraArgs);
        return _calculateFee(MAINNET_CHAIN_SELECTOR, message);
    }

    /**
     * @notice Returns the data required to synchronize accounting. Including the tokenAmounts array.
     */
    function getSynchronizeAccountingData() public view returns (uint256, uint256, Client.EVMTokenAmount[] memory) {
        uint256 reserveLeft = balanceOf(address(reserve));
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](0);
        if (reserveLeft > 0) {
            tokenAmounts = new Client.EVMTokenAmount[](1);
            tokenAmounts[0] = Client.EVMTokenAmount({token: address(this), amount: reserveLeft});
        }
        return (reserveLeft, accruedLoss, tokenAmounts);
    }

    /**
     * @notice Returns true if the address is an approved minter.
     */
    function isMinter(address _minter) public view returns (bool) {
        return minters[_minter] != 0 && block.timestamp >= minters[_minter];
    }

    /**
     * @notice Returns the address of the minter that created this position or null if the provided address is unknown.
     */
    function getPositionParent(address _position) public view returns (address) {
        return positions[_position];
    }

    /*
     * @notice Used to register the token initially in the CCIP environment
     */
    function getCCIPAdmin() external view returns (address) {
        return CCIP_ADMIN;
    }
}
