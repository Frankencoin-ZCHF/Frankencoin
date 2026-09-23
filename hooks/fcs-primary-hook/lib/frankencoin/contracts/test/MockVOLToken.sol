// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../erc20/ERC20.sol";

contract MockVOLToken is ERC20 {
    constructor() ERC20(18) {
        _mint(msg.sender, 1_000_000 * 1e18);
    }

    function name() external pure override returns (string memory) {
        return "VOL volatile mock token";
    }

    function symbol() external pure override returns (string memory) {
        return "VOL";
    }

    function mint(address _account, uint256 _amount) external {
        _mint(_account, _amount);
    }
}
