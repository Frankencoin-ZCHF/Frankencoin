// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {FluidDexLiteAggregator} from "./FluidDexLiteAggregator.sol";
import {IFluidDexLite} from "./interfaces/IFluidDexLite.sol";
import {IFluidDexLiteResolver} from "./interfaces/IFluidDexLiteResolver.sol";

/// @title FluidDexLiteAggregatorFactory
/// @notice Factory for creating FluidDexLiteAggregator hooks via CREATE2 and initializing Uniswap V4 pools
/// @dev Deploys deterministic hook addresses that meet Uniswap V4's hook address requirements
contract FluidDexLiteAggregatorFactory {
    /// @notice Full record of a hook deployment
    struct Deployment {
        address hook;
        bytes32 dexSalt;
        PoolKey poolKey;
    }

    /// @notice The Uniswap V4 PoolManager contract
    IPoolManager public immutable poolManager;
    /// @notice The Fluid DEX Lite contract
    IFluidDexLite public immutable fluidDexLite;
    /// @notice The Fluid DEX Lite resolver for pool state queries
    IFluidDexLiteResolver public immutable fluidDexLiteResolver;

    /// @notice All deployments, indexed by creation order
    Deployment[] public deployments;

    /// @notice The hook deployed for a given Fluid DEX Lite pool, keyed by
    ///         keccak256(abi.encode(currency0, currency1, dexSalt)) (address(0) if none)
    mapping(bytes32 dexKeyHash => address hook) public hookForDexKeyHash;

    error DuplicatePool(bytes32 dexSalt, Currency currency0, Currency currency1, address existingHook);

    event HookDeployed(address indexed hook, bytes32 indexed dexSalt, PoolKey poolKey);

    constructor(IPoolManager _poolManager, IFluidDexLite _fluidDexLite, IFluidDexLiteResolver _fluidDexLiteResolver) {
        poolManager = _poolManager;
        fluidDexLite = _fluidDexLite;
        fluidDexLiteResolver = _fluidDexLiteResolver;
    }

    /// @notice Creates a new FluidDexLiteAggregator hook and initializes the pool
    /// @param salt The CREATE2 salt (pre-mined to produce valid hook address)
    /// @param dexSalt The salt for the Fluid DEX Lite pool's DexKey
    /// @param currency0 The first currency of the pool (must be < currency1)
    /// @param currency1 The second currency of the pool
    /// @param fee The pool fee
    /// @param tickSpacing The pool tick spacing
    /// @param sqrtPriceX96 The initial sqrt price for the pool
    /// @return hook The deployed hook address
    function createPool(
        bytes32 salt,
        bytes32 dexSalt,
        Currency currency0,
        Currency currency1,
        uint24 fee,
        int24 tickSpacing,
        uint160 sqrtPriceX96
    ) external returns (address hook) {
        // The raw currencies + dexSalt uniquely identify the Fluid pool: the hook derives its DexKey
        // deterministically from them and rejects Fluid's native currency representation (0xEeee...),
        // so no two distinct currency pairs can map to the same DexKey. Sorting is unnecessary since
        // the PoolManager rejects unsorted currencies before anything is registered.
        bytes32 dexKeyHash = keccak256(abi.encode(currency0, currency1, dexSalt));
        address existingHook = hookForDexKeyHash[dexKeyHash];
        if (existingHook != address(0)) revert DuplicatePool(dexSalt, currency0, currency1, existingHook);

        hook = address(new FluidDexLiteAggregator{salt: salt}(poolManager, fluidDexLite, fluidDexLiteResolver, dexSalt));

        PoolKey memory poolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: IHooks(hook)
        });

        poolManager.initialize(poolKey, sqrtPriceX96);

        hookForDexKeyHash[dexKeyHash] = hook;
        deployments.push(Deployment({hook: hook, dexSalt: dexSalt, poolKey: poolKey}));

        emit HookDeployed(hook, dexSalt, poolKey);
    }

    /// @notice Total number of hooks deployed by this factory
    function deploymentCount() external view returns (uint256) {
        return deployments.length;
    }

    /// @notice Returns the full deployment record for a deployment index
    /// @param index The deployment index (in creation order)
    function getDeployment(uint256 index) external view returns (Deployment memory) {
        return deployments[index];
    }

    /// @notice Computes the CREATE2 address for a hook without deploying
    /// @param salt The CREATE2 salt
    /// @param dexSalt The salt for the Fluid DEX Lite pool's DexKey
    /// @return computedAddress The predicted hook address
    function computeAddress(bytes32 salt, bytes32 dexSalt) external view returns (address computedAddress) {
        bytes32 bytecodeHash = keccak256(
            abi.encodePacked(
                type(FluidDexLiteAggregator).creationCode,
                abi.encode(poolManager, fluidDexLite, fluidDexLiteResolver, dexSalt)
            )
        );
        computedAddress =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash)))));
    }
}
