// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../erc20/IERC20.sol";
import {UniswapAmplifier, IFrankencoinMinter} from "./UniswapAmplifier.sol";

/**
 * @title TestAmplifier
 *
 * Allows to test the amplifier without having to register the amplifier as a minter in the Frankencoin system.
 * 
 * "Minted" Frankencoins are taken from voluntary users that are willing to lend their Frankencoins to the amplifier.
 */
contract TestAmplifier is IFrankencoinMinter {
    
    IERC20 public immutable ZCHF;

    mapping(address => uint256) public deposits;

    UniswapAmplifier public immutable AMP;

    error NotAmplifier();
    error InsufficientDeposit(uint256 available, uint256 required);

    event Deposited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);

    constructor(address uniswapPool_, address zchf_, uint40 expiration, uint256 borrowingLimit) {
        ZCHF = IERC20(zchf_);
        AMP = new UniswapAmplifier(uniswapPool_, zchf_, address(this), expiration, borrowingLimit);
    }

    /// @notice Deposit Frankencoins to be handed out again when 'mint' is called for the depositor.
    function deposit(uint256 amount) external {
        ZCHF.transferFrom(msg.sender, address(this), amount);
        deposits[msg.sender] += amount;
        emit Deposited(msg.sender, amount);
    }

    /// @notice Reclaim deposited Frankencoins that have not been handed out.
    function withdraw(uint256 amount) external {
        deposits[msg.sender] -= amount; // reverts if amount exceeds the deposit
        ZCHF.transfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Hands out 'amount' ZCHF to 'to' from the shared deposit pool, simulating a mint.
    /// @dev Only the amplifier may call this; otherwise anyone could drain the pooled deposits. The deposits are
    ///      lent collectively, so this draws from the total balance rather than from 'to's own deposit.
    function mint(address to, uint256 amount) external {
        if (msg.sender != address(AMP)) revert NotAmplifier();
        uint256 available = ZCHF.balanceOf(address(this));
        if (available < amount) revert InsufficientDeposit(available, amount);
        ZCHF.transfer(to, amount);
    }

    /// @notice Takes 'amount' ZCHF from 'from' back into the pool, simulating a burn.
    /// @dev Only the amplifier may call this; otherwise anyone could pull the ZCHF of any address that has an
    ///      allowance to this contract. Requires an allowance from 'from' to this contract.
    function burnFrom(address from, uint256 amount) external {
        if (msg.sender != address(AMP)) revert NotAmplifier();
        ZCHF.transferFrom(from, address(this), amount);
    }
}
