// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMetaRegistry} from "../../../../src/aggregator-hooks/implementations/StableSwap/interfaces/IMetaRegistry.sol";

/// @title MockMetaRegistry
/// @notice Mock Curve MetaRegistry with settable return values for unit tests.
contract MockMetaRegistry is IMetaRegistry {
    mapping(address => bool) public isMetaMap;
    mapping(address => bool) public isRegisteredMap;

    function setIsMeta(address pool, bool value) external {
        isMetaMap[pool] = value;
    }

    function setIsRegistered(address pool, bool value) external {
        isRegisteredMap[pool] = value;
    }

    function is_meta(address _pool, uint256) external view override returns (bool) {
        return isMetaMap[_pool];
    }

    function is_registered(address _pool, uint256) external view override returns (bool) {
        return isRegisteredMap[_pool];
    }
}
