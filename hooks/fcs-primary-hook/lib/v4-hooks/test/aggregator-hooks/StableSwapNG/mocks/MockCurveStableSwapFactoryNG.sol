// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockCurveStableSwapFactoryNG
/// @notice Mock Curve StableSwap NG Factory with settable return values for unit tests.
contract MockCurveStableSwapFactoryNG {
    mapping(address => bool) public isMetaMap;
    mapping(address => uint256) public nCoinsMap;

    function setIsMeta(address pool, bool value) external {
        isMetaMap[pool] = value;
    }

    function setNCoins(address pool, uint256 n) external {
        nCoinsMap[pool] = n;
    }

    function is_meta(address _pool) external view returns (bool) {
        return isMetaMap[_pool];
    }

    function get_n_coins(address _pool) external view returns (uint256) {
        return nCoinsMap[_pool];
    }
}
