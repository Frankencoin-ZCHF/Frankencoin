// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @title MockTIP20
/// @notice Mock TIP-20 token for testing with quoteToken support
contract MockTIP20 is MockERC20 {
    address public quoteToken;

    constructor(string memory _name, string memory _symbol, uint8 _decimals, address _quoteToken)
        MockERC20(_name, _symbol, _decimals)
    {
        quoteToken = _quoteToken;
    }

    function setQuoteToken(address _quoteToken) external {
        quoteToken = _quoteToken;
    }
}
