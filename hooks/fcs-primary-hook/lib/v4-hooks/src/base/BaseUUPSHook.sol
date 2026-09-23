// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "./BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title BaseUUPSHook
/// @notice Generic base for upgradeable v4 hooks: a UUPS implementation behind a mined ERC1967
///         proxy (the registered hook). Role, flag, and upgrade-auth choices belong to
///         inheriting bases (e.g. `BaseDynamicFeeHook`).
/// @dev Rules for every implementation (the proxy's address and storage are forever):
///      - Storage: ERC-7201 namespaced structs only, append-only; validate layouts off-chain.
///      - Keep the same PoolManager and permission set (`_validateNewImplementation` checks both).
///      - Deploy the proxy with the `initialize` calldata as constructor `data`, or the first
///        caller takes admin.
/// @custom:security-contact security@uniswap.org
abstract contract BaseUUPSHook is BaseHook, UUPSUpgradeable, Initializable {
    /// @notice Thrown when a proposed implementation was built against a different PoolManager
    /// @param poolManager The proposed implementation's PoolManager
    error InvalidPoolManager(IPoolManager poolManager);

    constructor(IPoolManager _manager) BaseHook(_manager) {
        // The bare implementation must never be initialized; only proxies may be.
        _disableInitializers();
    }

    /// @notice Validates a proposed implementation against the on-chain-checkable upgrade rules:
    ///         same PoolManager, and a hook-permission set matching the proxy's address flags
    /// @dev This is used in `_authorizeUpgrade` to prevent against incorrect configurations.
    /// @param newImplementation The proposed implementation
    function _validateNewImplementation(address newImplementation) internal view {
        BaseUUPSHook newImpl = BaseUUPSHook(newImplementation);
        IPoolManager newPoolManager = newImpl.poolManager();
        if (newPoolManager != poolManager) revert InvalidPoolManager(newPoolManager);
        Hooks.validateHookPermissions(this, newImpl.getHookPermissions());
    }

    /// @notice Validates the proxy's hook-permission flags
    function __BaseUUPSHook_init() internal view onlyInitializing {
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    /// @notice Skips BaseHook's constructor-time address validation
    /// @dev The proxy's address flags are verified in `__BaseUUPSHook_init`.
    function validateHookAddress(BaseHook) internal pure override {}
}
