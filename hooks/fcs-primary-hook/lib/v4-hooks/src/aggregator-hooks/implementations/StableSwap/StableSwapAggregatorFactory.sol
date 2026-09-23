// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StableSwapAggregator} from "./StableSwapAggregator.sol";
import {ICurveStableSwap} from "./interfaces/IStableSwap.sol";
import {IMetaRegistry} from "./interfaces/IMetaRegistry.sol";

/// @title StableSwapAggregatorFactory
/// @notice Factory for creating StableSwapAggregator hooks via CREATE2 and initializing Uniswap V4 pools
/// @dev Deploys deterministic hook addresses and initializes pools for all token pairs in the Curve pool
contract StableSwapAggregatorFactory {
    /// @notice Full record of a hook deployment
    struct Deployment {
        address hook;
        address curvePool;
        PoolKey[] poolKeys;
    }

    /// @notice The Uniswap V4 PoolManager contract
    IPoolManager public immutable poolManager;

    /// @notice The Curve MetaRegistry for checking meta pool status
    IMetaRegistry public immutable metaRegistry;

    /// @notice All deployments, indexed by creation order
    /// @dev The auto-generated getter omits the poolKeys array; use getDeployment for the full record
    Deployment[] public deployments;

    /// @notice The hook deployed for a given Curve pool (address(0) if none)
    mapping(address curvePool => address hook) public hookForPool;

    error InsufficientTokens();
    error DuplicateTokens(Currency token);
    error DuplicatePool(address curvePool, address existingHook);
    error TokenCountMismatch(uint256 provided);

    event HookDeployed(address indexed hook, address indexed curvePool, PoolKey poolKey);

    constructor(IPoolManager _poolManager, IMetaRegistry _metaRegistry) {
        poolManager = _poolManager;
        metaRegistry = _metaRegistry;
    }

    /// @notice Creates a new StableSwapAggregator hook and initializes pools for all token pairs
    /// @param salt The CREATE2 salt (pre-mined to produce valid hook address)
    /// @param curvePool The Curve StableSwap pool to aggregate
    /// @param tokens Array of currencies in the pool (must contain exactly the pool's coins)
    /// @param fee The pool fee
    /// @param tickSpacing The pool tick spacing
    /// @param sqrtPriceX96 The initial sqrt price for each pool
    /// @return hook The deployed hook address
    /// @dev Note: The token count must match the Curve pool's coin count,
    ///  so every token pair is initialized in this single call
    function createPool(
        bytes32 salt,
        ICurveStableSwap curvePool,
        Currency[] calldata tokens,
        uint24 fee,
        int24 tickSpacing,
        uint160 sqrtPriceX96
    ) external returns (address hook) {
        if (tokens.length < 2) revert InsufficientTokens();

        // A duplicated token would produce a pool with currency0 == currency1 in the pair loop below
        for (uint256 i = 0; i < tokens.length; i++) {
            for (uint256 j = i + 1; j < tokens.length; j++) {
                if (tokens[i] == tokens[j]) revert DuplicateTokens(tokens[i]);
            }
        }

        // Legacy pools expose no coin count, but coin arrays are contiguous, so two boundary
        // probes prove tokens.length matches: coins(length - 1) must exist and coins(length)
        // must not. Revert and address(0) both mean "past the end" — the same sentinel
        // semantics as the hook's coin scan in _beforeInitialize.
        try curvePool.coins(tokens.length - 1) returns (address coin) {
            if (coin == address(0)) revert TokenCountMismatch(tokens.length);
        } catch {
            revert TokenCountMismatch(tokens.length);
        }
        try curvePool.coins(tokens.length) returns (address coin) {
            if (coin != address(0)) revert TokenCountMismatch(tokens.length);
        } catch {}

        address existingHook = hookForPool[address(curvePool)];
        if (existingHook != address(0)) revert DuplicatePool(address(curvePool), existingHook);

        hook = address(new StableSwapAggregator{salt: salt}(poolManager, curvePool, metaRegistry));

        hookForPool[address(curvePool)] = hook;
        // Pushing a Deployment memory literal needs a memory-to-storage copy of the nested
        // poolKeys array, which legacy codegen (via_ir = false) does not support
        Deployment storage deployment = deployments.push();
        deployment.hook = hook;
        deployment.curvePool = address(curvePool);

        // Initialize one pool per token pair
        for (uint256 i = 0; i < tokens.length; i++) {
            for (uint256 j = i + 1; j < tokens.length; j++) {
                (Currency currency0, Currency currency1) = Currency.unwrap(tokens[i]) < Currency.unwrap(tokens[j])
                    ? (tokens[i], tokens[j])
                    : (tokens[j], tokens[i]);

                PoolKey memory poolKey = PoolKey({
                    currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: IHooks(hook)
                });

                poolManager.initialize(poolKey, sqrtPriceX96);

                deployment.poolKeys.push(poolKey);

                emit HookDeployed(hook, address(curvePool), poolKey);
            }
        }
    }

    /// @notice Total number of hooks deployed by this factory
    function deploymentCount() external view returns (uint256) {
        return deployments.length;
    }

    /// @notice Returns the full deployment record (including all pool keys) for a deployment index
    /// @param index The deployment index (in creation order)
    function getDeployment(uint256 index) external view returns (Deployment memory) {
        return deployments[index];
    }

    /// @notice Computes the CREATE2 address for a hook without deploying
    /// @param salt The CREATE2 salt
    /// @param curvePool The Curve StableSwap pool
    /// @return computedAddress The predicted hook address
    function computeAddress(bytes32 salt, ICurveStableSwap curvePool) external view returns (address computedAddress) {
        bytes32 bytecodeHash = keccak256(
            abi.encodePacked(type(StableSwapAggregator).creationCode, abi.encode(poolManager, curvePool, metaRegistry))
        );
        computedAddress =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash)))));
    }
}
