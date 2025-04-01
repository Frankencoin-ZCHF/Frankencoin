// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../interface/IERC20.sol";

/**
 * @dev A module for Frankencoin transfers with a reference number
 */
contract ReferenceTransfer {

    IERC20 public immutable ZCHF;
    ISavings public immutable SAVINGS;

    uint256 internal constant INFINITY = (1 << 255);
    uint256 internal constant EMPTY_SETTINGS = 0;
    uint256 internal constant FORWARD_TO_SAVINGS = 1;

    mapping(address => uint256) settings;

    event Transfer(address indexed from, address indexed to, uint256 amount, string ref);

    error TransferFromRequiresInfiniteAllowance(address owner, address spender);

    constructor(address token, address savings) {
        ZCHF = IERC20(token);
        SAVINGS = ISavings(savings);
    }

    function transfer(address recipient, uint256 amount, string calldata ref) public returns (bool) {
        emit Transfer(msg.sender, recipient, amount, ref);
        executeTransfer(msg.sender, recipient, amount);
        return true;
    }

    function transferFrom(address owner, address recipient, uint256 amount, string calldata ref) public returns (bool) {
        if (ZCHF.allowance(owner, msg.sender) < INFINITY) revert TransferFromRequiresInfiniteAllowance(owner, msg.sender);        
        emit Transfer(owner, recipient, amount, ref);
        executeTransfer(owner, recipient, amount);
        return true;
    }

    function setAutoSave(bool enabled) external {
        settings[msg.sender] = enabled ? FORWARD_TO_SAVINGS : EMPTY_SETTINGS;
    }

    function hasAutoSave() external view returns(bool){
        return hasAutoSave(msg.sender);
    }

    function hasAutoSave(address owner) public view returns(bool){
        return settings[owner] & FORWARD_TO_SAVINGS == FORWARD_TO_SAVINGS;
    }

    function executeTransfer(address from, address to, uint256 amount) internal {
        if (hasAutoSave(to)){
            ZCHF.transferFrom(from, address(this), amount);
            SAVINGS.save(to, uint192(amount));
        } else {
            ZCHF.transferFrom(from, to, amount);
        }
    }

}

interface ISavings {
    function save(address owner, uint192 amount) external;
}


