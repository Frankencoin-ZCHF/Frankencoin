// SPDX-License-Identifier: MIT
//
// From https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/access/Ownable.sol
//
// Modifications:
// - Replaced Context._msgSender() with msg.sender
// - Made leaner

pragma solidity ^0.8.0;

import "../interface/IERC20.sol";

/**
 * @dev A module that allows to transfer frankencoins with a reference number
 */
contract ReferenceTransfer {

    IERC20 public immutable TOKEN;

    uint256 internal constant INFINITY = (1 << 255);

    event Transfer(address indexed from, address indexed to, uint256 amount, string ref);

    error TransferFromRequiresInfiniteAllowance(address owner, address spender);

    constructor(address token) {
        TOKEN = IERC20(token);
    }

    function transfer(address recipient, uint256 amount, string calldata ref) public returns (bool) {
        emit Transfer(msg.sender, recipient, amount, ref);
        return TOKEN.transferFrom(msg.sender, recipient, amount);
    }

    function transferFrom(address owner, address recipient, uint256 amount, string calldata ref) public returns (bool) {
        if (TOKEN.allowance(owner, msg.sender) < INFINITY) revert TransferFromRequiresInfiniteAllowance(owner, msg.sender);        
        emit Transfer(owner, recipient, amount, ref);
        return TOKEN.transferFrom(owner, recipient, amount);
    }

}


