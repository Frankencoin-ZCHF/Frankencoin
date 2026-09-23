// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StableFeeConfig} from "../../../src/stable/interfaces/IStableFeeConfiguration.sol";

struct DeployParameters {
    IPoolManager poolManager;
    bytes32 stablePairHookProxySalt; // cached CREATE2 salt for the StablePairHook ERC1967 proxy (0 = mine at runtime)
    // cached CREATE2 salt for the StablePairHook implementation, mined so the implementation
    // address carries no hook-flag bits (0 = mine at runtime)
    bytes32 stablePairHookImplementationSalt;
    // StablePairHook roles, baked into the proxy constructor args (and thus the mined hook
    // address); must be set for a chain before deploying, the deploy script reverts on zero
    address owner;
    address poolInitializer;
    address configManager;
}

/// @notice Per-chain parameters for InitStablePairHook: the pool to initialize
struct PoolParameters {
    address currency0; // must sort below currency1
    address currency1;
    int24 tickSpacing;
    uint160 sqrtPriceX96; // initial pool price
    StableFeeConfig feeConfig;
}

/// @title Parameters
/// @notice Per-chain deployment parameters for the StablePairHook deploy scripts
contract Parameters {
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint256 public constant ETHEREUM_CHAIN_ID = 1;
    uint256 public constant OPTIMISM_CHAIN_ID = 10;
    uint256 public constant UNICHAIN_CHAIN_ID = 130;
    uint256 public constant MONAD_CHAIN_ID = 143;
    uint256 public constant BASE_CHAIN_ID = 8453;
    uint256 public constant ARBITRUM_CHAIN_ID = 42161;
    uint256 public constant SEPOLIA_CHAIN_ID = 11155111;

    string public constant POOL_USDC_USDT = "USDC/USDT";
    string public constant POOL_USDC_USDG = "USDC/USDG";

    /// @notice Thrown when parameters are not set for a given chainId
    error ParametersNotSetForChainId(uint256 chainId);
    /// @notice Thrown when pool parameters are not set for a given chainId and pool name
    error PoolParametersNotSetForChainId(uint256 chainId, string poolName);

    mapping(uint256 chainId => DeployParameters) public parameters;
    mapping(uint256 chainId => mapping(string poolName => PoolParameters)) internal poolParameters;

    constructor() {
        // PoolManager addresses: https://docs.uniswap.org/contracts/v4/deployments
        parameters[ETHEREUM_CHAIN_ID] = DeployParameters({
            poolManager: IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90),
            // mined for 0x0000113dCf4ADd69999Fad8F20F2b63F979bfcC0 (prefix 0x000011, flags 0x3CC0)
            stablePairHookProxySalt: 0x000000000000000000000000000000000000000023fd42c02e1b74f1f9ac0080,
            stablePairHookImplementationSalt: bytes32(uint256(0xdd0)),
            // Uniswap Governance Timelock (admin: GovernorBravo 0x408ED6354d4973f66138C91495F2f2FCbd8724C3)
            owner: 0x1a9C8182C09F50C8318d769245beA52c32BE35BC,
            poolInitializer: 0xFc43582532E90Fa8726FE9cdb5FAd48f4e487d27,
            configManager: 0x1a9C8182C09F50C8318d769245beA52c32BE35BC
        });
        parameters[OPTIMISM_CHAIN_ID] = DeployParameters({
            poolManager: IPoolManager(0x9a13F98Cb987694C9F086b1F5eB990EeA8264Ec3),
            stablePairHookProxySalt: bytes32(0),
            stablePairHookImplementationSalt: bytes32(0),
            owner: address(0),
            poolInitializer: address(0),
            configManager: address(0)
        });
        parameters[UNICHAIN_CHAIN_ID] = DeployParameters({
            poolManager: IPoolManager(0x1F98400000000000000000000000000000000004),
            stablePairHookProxySalt: bytes32(0),
            stablePairHookImplementationSalt: bytes32(0),
            owner: address(0),
            poolInitializer: address(0),
            configManager: address(0)
        });
        parameters[MONAD_CHAIN_ID] = DeployParameters({
            poolManager: IPoolManager(0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e),
            stablePairHookProxySalt: bytes32(0),
            stablePairHookImplementationSalt: bytes32(0),
            owner: address(0),
            poolInitializer: address(0),
            configManager: address(0)
        });
        parameters[BASE_CHAIN_ID] = DeployParameters({
            poolManager: IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b),
            stablePairHookProxySalt: bytes32(0),
            stablePairHookImplementationSalt: bytes32(0),
            owner: address(0),
            poolInitializer: address(0),
            configManager: address(0)
        });
        parameters[ARBITRUM_CHAIN_ID] = DeployParameters({
            poolManager: IPoolManager(0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32),
            stablePairHookProxySalt: bytes32(0),
            stablePairHookImplementationSalt: bytes32(0),
            owner: address(0),
            poolInitializer: address(0),
            configManager: address(0)
        });
        parameters[SEPOLIA_CHAIN_ID] = DeployParameters({
            poolManager: IPoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543),
            stablePairHookProxySalt: bytes32(uint256(0x30ad)),
            stablePairHookImplementationSalt: bytes32(uint256(0x6e7e)),
            owner: 0xE49ACc3B16c097ec88Dc9352CE4Cd57aB7e35B95,
            poolInitializer: 0xE49ACc3B16c097ec88Dc9352CE4Cd57aB7e35B95,
            configManager: 0xE49ACc3B16c097ec88Dc9352CE4Cd57aB7e35B95
        });

        poolParameters[ETHEREUM_CHAIN_ID][POOL_USDC_USDT] = PoolParameters({
            currency0: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, // USDC
            currency1: 0xdAC17F958D2ee523a2206206994597C13D831ec7, // USDT
            tickSpacing: 1,
            sqrtPriceX96: 79228162514264337593543950336, // 1:1
            feeConfig: StableFeeConfig({
                k: 11_744_051, // 0.7 in Q24 (0.7 * 2**24)
                optimalFeeE6: 7, // = .07bps = .0007%
                targetMultiplier: 100,
                referenceSqrtPriceX96: 79228162514264337593543950336 // 1:1
            })
        });
        poolParameters[ETHEREUM_CHAIN_ID][POOL_USDC_USDG] = PoolParameters({
            currency0: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, // USDC
            currency1: 0xe343167631d89B6Ffc58B88d6b7fB0228795491D, // USDG
            tickSpacing: 1,
            sqrtPriceX96: 79228162514264337593543950336, // 1:1
            feeConfig: StableFeeConfig({
                k: 11_744_051, // 0.7 in Q24 (0.7 * 2**24)
                optimalFeeE6: 50, // = .5bps = .005%
                targetMultiplier: 100,
                referenceSqrtPriceX96: 79228162514264337593543950336 // 1:1
            })
        });
        poolParameters[SEPOLIA_CHAIN_ID][POOL_USDC_USDT] = PoolParameters({
            currency0: 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238, // USDC (Circle)
            currency1: 0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0, // USDT (Aave testnet)
            tickSpacing: 1,
            sqrtPriceX96: 79228162514264337593543950336, // 1:1
            feeConfig: StableFeeConfig({
                k: 167772, // .01
                optimalFeeE6: 7, // = .07bps = .0007%
                targetMultiplier: 100,
                referenceSqrtPriceX96: 79228162514264337593543950336 // 1:1
            })
        });
    }

    function getParameters(uint256 chainId) public view returns (DeployParameters memory params) {
        params = parameters[chainId];
        if (address(params.poolManager) == address(0)) {
            revert ParametersNotSetForChainId(chainId);
        }
    }

    /// @notice Pool parameters for a named pool on a chain
    /// @param chainId The chain the pool lives on
    /// @param poolName One of the POOL_* constants
    function getPoolParameters(uint256 chainId, string memory poolName)
        public
        view
        returns (PoolParameters memory params)
    {
        params = poolParameters[chainId][poolName];
        if (params.currency0 == address(0)) {
            revert PoolParametersNotSetForChainId(chainId, poolName);
        }
    }
}
