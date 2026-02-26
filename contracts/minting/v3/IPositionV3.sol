// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../../erc20/IERC20.sol";

interface IPositionV3 {
    function hub() external view returns (address);

    // Only callable by hub — releases collateral
    function transfer(address token, address to, uint256 amount) external;

    // Only callable by hub — sets allowance (used for repay flows if needed)
    function approve(address token, address spender, uint256 amount) external;
}
