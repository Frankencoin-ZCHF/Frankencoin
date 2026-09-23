// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StableFeeConfiguration} from "../../../src/stable/base/StableFeeConfiguration.sol";
import {StableFeeConfig, StableFeeState} from "../../../src/stable/interfaces/IStableFeeConfiguration.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title StableFeeConfigurationImplementation
/// @notice Implementation of the StableFeeConfiguration contract
contract StableFeeConfigurationImplementation is StableFeeConfiguration {
    constructor(address _configManager) initializer {
        _grantRole(CONFIG_MANAGER_ROLE, _configManager);
    }

    /// @notice Test helper to set fee state directly
    function setFeeState(PoolId poolId, StableFeeState calldata _feeState) external {
        _getStableFeeConfigurationStorage().feeState[poolId] = _feeState;
    }

    /// @notice Test helper mirroring the hook's pool-initialization seeding path: creates
    ///         first-time config directly, since updateFeeConfig only updates existing config.
    function initializeFeeConfig(PoolId poolId, StableFeeConfig calldata config) external {
        _updateFeeConfig(poolId, config);
    }
}
