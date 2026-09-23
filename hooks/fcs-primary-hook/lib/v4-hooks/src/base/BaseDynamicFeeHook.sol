// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseUUPSHook} from "./BaseUUPSHook.sol";
import {HookRoles} from "./HookRoles.sol";
import {IDynamicFeeHook} from "../interfaces/IDynamicFeeHook.sol";
import {BaseHook} from "./BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title BaseDynamicFeeHook
/// @notice Shared base for the upgradeable dynamic-fee hooks: owns the frozen 6-flag permission
///         set, the three-role AccessControl wiring, the pool-creation guard, and inert defaults
///         for the optional callbacks.
/// @custom:security-contact security@uniswap.org
abstract contract BaseDynamicFeeHook is BaseUUPSHook, HookRoles, IDynamicFeeHook {
    /// @notice Thrown when initializing with a disallowed admin: the zero address (would
    ///         permanently freeze upgrades) or the hook itself (could never act)
    /// @param admin The invalid admin
    error InvalidAdmin(address admin);

    /// @notice Thrown when a pool with this hook is initialized directly on the PoolManager
    ///         instead of through the hook's pool-initialization entrypoint
    /// @param caller The address that attempted to initialize the pool
    error InvalidInitializer(address caller);

    constructor(IPoolManager _manager) BaseUUPSHook(_manager) {}

    /// @notice Initializes the proxy's roles and validates its hook-permission flags
    /// @param _admin Granted DEFAULT_ADMIN_ROLE: controls upgrades and administers all roles
    /// @param _poolInitializer Granted POOL_INITIALIZER_ROLE
    /// @param _configManager Granted CONFIG_MANAGER_ROLE
    function initialize(address _admin, address _poolInitializer, address _configManager) external initializer {
        if (_admin == address(0) || _admin == address(this)) revert InvalidAdmin(_admin);
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(POOL_INITIALIZER_ROLE, _poolInitializer);
        _grantRole(CONFIG_MANAGER_ROLE, _configManager);
        __BaseUUPSHook_init();
    }

    /// @notice Restricts upgrades to the admin (governance) and validates that the proposed
    ///         implementation keeps the same PoolManager and hook-permission set
    function _authorizeUpgrade(address newImplementation) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {
        _validateNewImplementation(newImplementation);
    }

    /// @inheritdoc BaseHook
    /// @dev The proxy's mined address freezes this flag set forever — flags not claimed now can
    ///      never be used by a future implementation. beforeInitialize backs the pool-creation
    ///      guard and beforeSwap the fee logic; the other enabled flags are optional callbacks or
    ///      future headroom (afterInitialize never runs today: initializePool self-calls, and v4
    ///      skips callbacks on self-calls). Remove-liquidity, return-delta, and donate flags stay
    ///      off so exits can never be blocked and amounts never altered.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Rejects direct pool initialization
    /// @dev This requires pool initialization to be done through `initializePool`, as this function is not called when the hook itself is caller.
    function _beforeInitialize(address sender, PoolKey calldata, uint160) internal virtual override returns (bytes4) {
        revert InvalidInitializer(sender);
    }

    /// @notice Inert default for the BEFORE_ADD_LIQUIDITY flag; inheriting hooks may override.
    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        virtual
        override
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @notice Inert default for the AFTER_ADD_LIQUIDITY flag; inheriting hooks may override
    ///         (the returned delta is ignored: the RETURNS_DELTA flag is off).
    function _afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal virtual override returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @notice Inert default for the AFTER_SWAP flag; inheriting hooks may override.
    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, int128)
    {
        return (IHooks.afterSwap.selector, int128(0));
    }
}
