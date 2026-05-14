// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../IGovernance.sol";

contract GovernanceModule {

    IGovernance public immutable GOVERNANCE;
    address private immutable MAINNET_FPS2;

    constructor(IGovernance governance, address mainnetFPS2) {
        GOVERNANCE = governance;
        MAINNET_FPS2 = mainnetFPS2;
    }

    function defaultHelper() internal view returns (address[] memory) {
        address[] memory helper = new address[](1);
        helper[0] = MAINNET_FPS2;
        return helper;
    }

}