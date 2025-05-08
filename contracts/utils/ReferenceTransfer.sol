// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../interface/IERC20.sol";

/**
 * @dev A module for Frankencoin transfers with a reference number
 */
contract ReferenceTransfer {
    IERC20 public immutable ZCHF;
    uint256 internal constant INFINITY = (1 << 255); // @dev: copied from "./ERC20.sol"

    mapping(address => address) public hasAutoSave;

    event AutoSave(address indexed to, address target);
    event Transfer(address indexed from, address indexed to, uint256 amount, string ref);

    error InfiniteAllowanceRequired(address owner, address spender);

    constructor(address token) {
        ZCHF = IERC20(token);
    }

    function transfer(address recipient, uint256 amount, string calldata ref) public returns (bool) {
        _executeTransfer(msg.sender, recipient, amount);
        emit Transfer(msg.sender, recipient, amount, ref);
        return true;
    }

    function transferFrom(address owner, address recipient, uint256 amount, string calldata ref) public returns (bool) {
        if (ZCHF.allowance(owner, msg.sender) < INFINITY) revert InfiniteAllowanceRequired(owner, msg.sender);
        _executeTransfer(owner, recipient, amount);
        emit Transfer(owner, recipient, amount, ref);
        return true;
    }

    function _executeTransfer(address from, address to, uint256 amount) internal {
        if (hasAutoSave[to] != address(0)) {
            ZCHF.transferFrom(from, address(this), amount);
            ISavings(hasAutoSave[to]).save(to, uint192(amount));
        } else {
            ZCHF.transferFrom(from, to, amount);
        }
    }

    function setAutoSave(address target) public {
        hasAutoSave[msg.sender] = target;
        emit AutoSave(msg.sender, target);
    }

    function clearAutoSave() external {
        setAutoSave(address(0));
    }
}

interface ISavings {
    function save(address owner, uint192 amount) external;
}
