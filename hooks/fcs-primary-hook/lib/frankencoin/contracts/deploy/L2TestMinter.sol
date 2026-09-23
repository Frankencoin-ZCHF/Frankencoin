// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IBasicFrankencoin} from "../stablecoin/IBasicFrankencoin.sol";


contract L2TestMinter {
    bool public used;

    constructor() {

    }

    function mint(IBasicFrankencoin token, address target) external {
        require(!used, "Used");
        token.mint(target, 1 ether);
        used = true;
    }
}