// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";

/// @dev Forces Foundry to compile PoolManager.sol so its artifact is available for deployCode().
///      This file exists because no test directly imports the concrete PoolManager (to avoid
///      solc version conflicts with ^0.8.29 dependencies), but deployCode needs the artifact.
contract ForceCompile {
    function poolManagerCreationCode() external pure returns (bytes memory) {
        return type(PoolManager).creationCode;
    }
}
