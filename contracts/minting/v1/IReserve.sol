// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../../erc20/IERC20.sol";

interface IReserve is IERC20 {
    function invest(uint256 amount, uint256 expected) external returns (uint256);

    function checkQualified(address sender, address[] calldata helpers) external view;
}
