// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {CrossChainERC20} from "./CrossChainERC20.sol";
import {ERC20} from "./ERC20.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";

/**
 * @dev A module for Frankencoin crosschain transfers with a reference number
 */
abstract contract CrossChainReference is CrossChainERC20 {
    event Transfer(address indexed from, address indexed to, uint256 amount, string ref);
    event CrossTransfer(address indexed from, uint64 indexed toChain, address indexed to, uint256 amount, string ref); // FIXME: uint64 **indexed** toChain ?

    error InfiniteAllowanceRequired(address owner, address spender);

    constructor(address router, address linkToken) CrossChainERC20(router, linkToken) {}

    // transfer within the erc20 context
    function transfer(address recipient, uint256 amount, string calldata ref) public returns (bool) {
        _transfer(msg.sender, recipient, amount);
        emit Transfer(msg.sender, recipient, amount, ref);
        return true;
    }

    function transferFrom(address owner, address recipient, uint256 amount, string calldata ref) public returns (bool) {
        _useAllowance(owner, msg.sender, amount);
        _transfer(owner, recipient, amount);
        emit Transfer(owner, recipient, amount, ref);
        return true;
    }

    // transfer within the cross chain context
    function transfer(uint64 targetChain, address recipient, uint256 amount, string calldata ref) public returns (bool) {
        return transfer(targetChain, _toReceiver(recipient), amount, "", ref);
    }

    function transfer(uint64 targetChain, address recipient, uint256 amount, Client.EVMExtraArgsV2 calldata extraArgs, string calldata ref) public returns (bool) {
        return transfer(targetChain, _toReceiver(recipient), amount, Client._argsToBytes(extraArgs), ref);
    }

    function transfer(uint64 targetChain, bytes memory recipient, uint256 amount, bytes memory extraArgs, string calldata ref) public returns (bool) {
        _crossTransfer(targetChain, msg.sender, recipient, amount, extraArgs, ref);
        return true;
    }

    // cross transfer from
    function transferFrom(uint64 targetChain, address owner, address recipient, uint256 amount, string calldata ref) public returns (bool) {
        return transferFrom(targetChain, owner, _toReceiver(recipient), amount, "", ref);
    }

    function transferFrom(uint64 targetChain, address owner, address recipient, uint256 amount, Client.EVMExtraArgsV2 calldata extraArgs, string calldata ref) public returns (bool) {
        return transferFrom(targetChain, owner, _toReceiver(recipient), amount, Client._argsToBytes(extraArgs), ref);
    }

    function transferFrom(uint64 targetChain, address owner, bytes memory recipient, uint256 amount, bytes memory extraArgs, string calldata ref) public returns (bool) {
        _useAllowance(owner, msg.sender, amount);
        _crossTransfer(targetChain, owner, recipient, amount, extraArgs, ref);
        return true;
    }

    function _crossTransfer(uint64 targetChain, address from, bytes memory target, uint256 amount, bytes memory extraArgs, string calldata ref) private {
        _transfer(from, address(this), amount);
        _approve(address(this), address(ROUTER), amount);
        _send(targetChain, constructTransferMessage(target, amount, extraArgs));
        /*  FIXME: what needs to be indexable... from, to, value, ...
            address **to** is missing and needs convertion. 
            (msg.sender, targetChain, **to**, amount, ref); 
            
            @mathewmeconry
            sender might not be the owner, should we index "from" instead of msg.sender?
            sender might be a minting module with INFINITY allowance
            
            e.g. i guess we need this, what do you think?
            CrossTransfer(msg.sender, from, targetChain, to, amount, ref); 
        */
        emit CrossTransfer(msg.sender, targetChain, from, amount, ref);
    }
}
