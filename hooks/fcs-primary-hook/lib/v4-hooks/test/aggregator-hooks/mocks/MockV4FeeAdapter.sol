// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IV4FeeAdapter} from "@protocol-fees/interfaces/IV4FeeAdapter.sol";
import {IV4FeePolicy} from "@protocol-fees/interfaces/IV4FeePolicy.sol";

/// @title MockV4FeeAdapter
/// @notice Minimal mock of IV4FeeAdapter for unit testing protocol fees
/// @dev Returns a configurable fee from getFee and stores a configurable TOKEN_JAR.
contract MockV4FeeAdapter is IV4FeeAdapter {
    IPoolManager public immutable override POOL_MANAGER;
    address public override TOKEN_JAR;
    uint24 public constant override ZERO_FEE_SENTINEL = type(uint24).max;

    address public override feeSetter;
    IV4FeePolicy public override policy;
    mapping(PoolId => uint24) public override poolOverrides;

    /// @notice The fee returned by getFee (settable for tests)
    uint24 public mockFee;

    constructor(IPoolManager _poolManager, address _tokenJar) {
        POOL_MANAGER = _poolManager;
        TOKEN_JAR = _tokenJar;
    }

    /// @notice Set the fee that getFee() will return
    function setMockFee(uint24 fee) external {
        mockFee = fee;
    }

    /// @notice Set the TOKEN_JAR address
    function setTokenJar(address _tokenJar) external {
        TOKEN_JAR = _tokenJar;
    }

    function getFee(PoolKey memory) external view override returns (uint24) {
        return mockFee;
    }

    function setPolicy(IV4FeePolicy) external override {}
    function setFeeSetter(address) external override {}
    function setPoolOverride(PoolId, uint24) external override {}
    function clearPoolOverride(PoolId) external override {}
    function triggerFeeUpdate(PoolKey calldata) external override {}
    function batchTriggerFeeUpdate(PoolKey[] calldata) external override {}
    function collect(CollectParams[] calldata) external override {}
}
