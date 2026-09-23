// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {FluidDexT1Aggregator} from "./FluidDexT1Aggregator.sol";
import {IFluidDexT1} from "./interfaces/IFluidDexT1.sol";
import {IFluidDexReservesResolver} from "./interfaces/IFluidDexReservesResolver.sol";
import {IFluidDexResolver} from "./interfaces/IFluidDexResolver.sol";

/// @title FluidDexT1AggregatorFactory
/// @notice Factory for creating FluidDexT1Aggregator hooks via CREATE2 and initializing Uniswap V4 pools
/// @dev Deploys deterministic hook addresses that meet Uniswap V4's hook address requirements
contract FluidDexT1AggregatorFactory {
    /// @notice The Uniswap V4 PoolManager contract
    IPoolManager public immutable poolManager;
    /// @notice The Fluid DEX reserves resolver for pool state queries
    IFluidDexReservesResolver public immutable fluidDexReservesResolver;
    /// @notice The Fluid DEX resolver for swap queries
    IFluidDexResolver public immutable fluidDexResolver;
    /// @notice The Fluid Liquidity Layer contract address
    address public immutable fluidLiquidity;

    /// @notice Full record of a hook deployment
    struct Deployment {
        address hook;
        address fluidPool;
        PoolKey poolKey;
    }

    /// @notice All deployments, indexed by creation order
    Deployment[] public deployments;

    /// @notice The hook deployed for a given Fluid DEX T1 pool (address(0) if none)
    mapping(address fluidPool => address hook) public hookForPool;

    event HookDeployed(address indexed hook, address indexed fluidPool, PoolKey poolKey);

    error DuplicatePool(address fluidPool, address existingHook);

    constructor(
        IPoolManager _poolManager,
        IFluidDexReservesResolver _fluidDexReservesResolver,
        IFluidDexResolver _fluidDexResolver,
        address _fluidLiquidity
    ) {
        poolManager = _poolManager;
        fluidDexReservesResolver = _fluidDexReservesResolver;
        fluidDexResolver = _fluidDexResolver;
        fluidLiquidity = _fluidLiquidity;
    }

    /// @notice Creates a new FluidDexT1Aggregator hook and initializes the pool
    /// @param salt The CREATE2 salt (pre-mined to produce valid hook address)
    /// @param fluidPool The Fluid DEX T1 pool to aggregate
    /// @param currency0 The first currency of the pool (must be < currency1)
    /// @param currency1 The second currency of the pool
    /// @param fee The pool fee
    /// @param tickSpacing The pool tick spacing
    /// @param sqrtPriceX96 The initial sqrt price for the pool
    /// @return hook The deployed hook address
    function createPool(
        bytes32 salt,
        IFluidDexT1 fluidPool,
        Currency currency0,
        Currency currency1,
        uint24 fee,
        int24 tickSpacing,
        uint160 sqrtPriceX96
    ) external returns (address hook) {
        address existingHook = hookForPool[address(fluidPool)];
        if (existingHook != address(0)) revert DuplicatePool(address(fluidPool), existingHook);

        hook = address(
            new FluidDexT1Aggregator{salt: salt}(
                poolManager, fluidPool, fluidDexReservesResolver, fluidDexResolver, fluidLiquidity
            )
        );

        PoolKey memory poolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: IHooks(hook)
        });

        poolManager.initialize(poolKey, sqrtPriceX96);

        hookForPool[address(fluidPool)] = hook;
        deployments.push(Deployment({hook: hook, fluidPool: address(fluidPool), poolKey: poolKey}));

        emit HookDeployed(hook, address(fluidPool), poolKey);
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
    /// @param fluidPool The Fluid DEX T1 pool
    /// @return computedAddress The predicted hook address
    function computeAddress(bytes32 salt, IFluidDexT1 fluidPool) external view returns (address computedAddress) {
        bytes32 bytecodeHash = keccak256(
            abi.encodePacked(
                type(FluidDexT1Aggregator).creationCode,
                abi.encode(poolManager, fluidPool, fluidDexReservesResolver, fluidDexResolver, fluidLiquidity)
            )
        );
        computedAddress =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash)))));
    }
}
