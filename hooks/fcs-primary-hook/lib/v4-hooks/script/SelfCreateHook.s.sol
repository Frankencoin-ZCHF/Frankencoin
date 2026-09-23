// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {StableSwapAggregator} from "../src/aggregator-hooks/implementations/StableSwap/StableSwapAggregator.sol";
import {StableSwapNGAggregator} from "../src/aggregator-hooks/implementations/StableSwapNG/StableSwapNGAggregator.sol";
import {FluidDexT1Aggregator} from "../src/aggregator-hooks/implementations/FluidDexT1/FluidDexT1Aggregator.sol";
import {FluidDexLiteAggregator} from "../src/aggregator-hooks/implementations/FluidDexLite/FluidDexLiteAggregator.sol";
import {
    PancakeSwapV3Aggregator
} from "../src/aggregator-hooks/implementations/PancakeSwapV3/PancakeSwapV3Aggregator.sol";
import {SlipstreamAggregator} from "../src/aggregator-hooks/implementations/Slipstream/SlipstreamAggregator.sol";

import {ICurveStableSwap} from "../src/aggregator-hooks/implementations/StableSwap/interfaces/IStableSwap.sol";
import {IMetaRegistry} from "../src/aggregator-hooks/implementations/StableSwap/interfaces/IMetaRegistry.sol";
import {
    ICurveStableSwapNG
} from "../src/aggregator-hooks/implementations/StableSwapNG/interfaces/ICurveStableSwapNG.sol";
import {
    ICurveStableSwapFactoryNG
} from "../src/aggregator-hooks/implementations/StableSwapNG/interfaces/ICurveStableSwapFactoryNG.sol";
import {IFluidDexT1} from "../src/aggregator-hooks/implementations/FluidDexT1/interfaces/IFluidDexT1.sol";
import {
    IFluidDexReservesResolver
} from "../src/aggregator-hooks/implementations/FluidDexT1/interfaces/IFluidDexReservesResolver.sol";
import {IFluidDexResolver} from "../src/aggregator-hooks/implementations/FluidDexT1/interfaces/IFluidDexResolver.sol";
import {IFluidDexLite} from "../src/aggregator-hooks/implementations/FluidDexLite/interfaces/IFluidDexLite.sol";
import {
    IFluidDexLiteResolver
} from "../src/aggregator-hooks/implementations/FluidDexLite/interfaces/IFluidDexLiteResolver.sol";
import {IAggregatorHook} from "../src/aggregator-hooks/interfaces/IAggregatorHook.sol";

/// @notice Self-deploys an aggregator hook and initializes the pool without using a factory
/// @dev Broadcasts from PRIVATE_KEY and deploys using CREATE2 with the provided salt
contract SelfCreateHookScript is Script {
    uint8 constant ID_STABLESWAP = 0xC1;
    uint8 constant ID_STABLESWAPNG = 0xC2;
    uint8 constant ID_FLUIDDEXT1 = 0xF1;
    uint8 constant ID_FLUIDDEXLITE = 0xF3;
    uint8 constant ID_PANCAKE_V3 = 0x93;
    uint8 constant ID_SLIPSTREAM = 0xA1;

    function run() public {
        // Load private key for broadcasting
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Common parameters
        uint8 protocolId = uint8(vm.envUint("PROTOCOL_ID"));
        bytes32 salt = vm.envBytes32("SALT");
        address poolManager = vm.envAddress("POOL_MANAGER");

        // Singleton protocols (PancakeSwapV3, Slipstream) only deploy the aggregator here;
        // pool initialization is handled separately by the TypeScript orchestrator.
        bool isSingleton = (protocolId == ID_PANCAKE_V3 || protocolId == ID_SLIPSTREAM);

        uint24 fee;
        int24 tickSpacing;
        uint160 sqrtPriceX96;
        if (!isSingleton) {
            fee = uint24(vm.envUint("FEE"));
            tickSpacing = int24(int256(vm.envUint("TICK_SPACING")));
            sqrtPriceX96 = uint160(vm.envUint("SQRT_PRICE_X96"));
        }

        address hookAddress;

        vm.startBroadcast(deployerPrivateKey);

        if (protocolId == ID_STABLESWAP) {
            hookAddress = _deployStableSwap(salt, poolManager);
        } else if (protocolId == ID_STABLESWAPNG) {
            hookAddress = _deployStableSwapNG(salt, poolManager);
        } else if (protocolId == ID_FLUIDDEXT1) {
            hookAddress = _deployFluidDexT1(salt, poolManager);
        } else if (protocolId == ID_FLUIDDEXLITE) {
            hookAddress = _deployFluidDexLite(salt, poolManager);
        } else if (protocolId == ID_PANCAKE_V3) {
            hookAddress = _deployPancakeSwapV3(salt, poolManager);
        } else if (protocolId == ID_SLIPSTREAM) {
            hookAddress = _deploySlipstream(salt, poolManager);
        } else {
            revert("Invalid protocol ID");
        }

        if (!isSingleton) {
            // Initialize one Uniswap pool per token pair. TOKENS is comma-separated (2+ for fluid, 2+ for stableswap).
            address[] memory tokens = vm.envAddress("TOKENS", ",");
            require(tokens.length >= 2, "TOKENS must have at least 2 addresses");
            for (uint256 i = 0; i < tokens.length; i++) {
                for (uint256 j = i + 1; j < tokens.length; j++) {
                    (address c0, address c1) = tokens[i] < tokens[j] ? (tokens[i], tokens[j]) : (tokens[j], tokens[i]);
                    PoolKey memory poolKey = PoolKey({
                        currency0: Currency.wrap(c0),
                        currency1: Currency.wrap(c1),
                        fee: fee,
                        tickSpacing: tickSpacing,
                        hooks: IHooks(hookAddress)
                    });
                    IPoolManager(poolManager).initialize(poolKey, sqrtPriceX96);
                    console.log("Initialized pool:", c0, c1);
                }
            }
        }

        vm.stopBroadcast();

        // Output results
        console.log("=== Self-Deploy Hook Results ===");
        console.log("Hook Address:", hookAddress);
        console.log("Salt:", vm.toString(salt));
        console.log("Protocol ID:", protocolId);
        console.log("Pool Manager:", poolManager);
        if (!isSingleton) {
            console.log("Fee:", fee);
            console.log("Tick Spacing:", uint24(tickSpacing));
            console.log("Sqrt Price X96:", sqrtPriceX96);
        }
        console.log("================================");
    }

    function _deployStableSwap(bytes32 salt, address poolManager) internal returns (address) {
        address curvePool = vm.envAddress("CURVE_POOL");
        address metaRegistry = vm.envAddress("METAREGISTRY");

        StableSwapAggregator hook = new StableSwapAggregator{salt: salt}(
            IPoolManager(poolManager), ICurveStableSwap(curvePool), IMetaRegistry(metaRegistry)
        );

        return address(hook);
    }

    function _deployStableSwapNG(bytes32 salt, address poolManager) internal returns (address) {
        address curvePool = vm.envAddress("CURVE_POOL");
        address curveFactory = vm.envAddress("CURVE_FACTORY");

        StableSwapNGAggregator hook = new StableSwapNGAggregator{salt: salt}(
            IPoolManager(poolManager), ICurveStableSwapNG(curvePool), ICurveStableSwapFactoryNG(curveFactory)
        );

        return address(hook);
    }

    function _deployFluidDexT1(bytes32 salt, address poolManager) internal returns (address) {
        address fluidPool = vm.envAddress("FLUID_POOL");
        address fluidDexReservesResolver = vm.envAddress("FLUID_DEX_T1_RESERVES_RESOLVER");
        address fluidDexResolver = vm.envAddress("FLUID_DEX_T1_RESOLVER");
        address fluidLiquidity = vm.envAddress("FLUID_LIQUIDITY");

        FluidDexT1Aggregator hook = new FluidDexT1Aggregator{salt: salt}(
            IPoolManager(poolManager),
            IFluidDexT1(fluidPool),
            IFluidDexReservesResolver(fluidDexReservesResolver),
            IFluidDexResolver(fluidDexResolver),
            fluidLiquidity
        );

        return address(hook);
    }

    function _deployFluidDexLite(bytes32 salt, address poolManager) internal returns (address) {
        address fluidDexLite = vm.envAddress("FLUID_DEX_LITE");
        address fluidDexLiteResolver = vm.envAddress("FLUID_DEX_LITE_RESOLVER");
        bytes32 dexSalt = vm.envBytes32("DEX_SALT");

        FluidDexLiteAggregator hook = new FluidDexLiteAggregator{salt: salt}(
            IPoolManager(poolManager), IFluidDexLite(fluidDexLite), IFluidDexLiteResolver(fluidDexLiteResolver), dexSalt
        );

        return address(hook);
    }

    function _deployPancakeSwapV3(bytes32 salt, address poolManager) internal returns (address) {
        address externalFactory = vm.envAddress("EXTERNAL_FACTORY");
        string memory hookVersion = vm.envOr("HOOK_VERSION", string("PancakeSwapV3Aggregator v1.0"));

        PancakeSwapV3Aggregator hook =
            new PancakeSwapV3Aggregator{salt: salt}(IPoolManager(poolManager), externalFactory, hookVersion);

        return address(hook);
    }

    function _deploySlipstream(bytes32 salt, address poolManager) internal returns (address) {
        address externalFactory = vm.envAddress("EXTERNAL_FACTORY");

        SlipstreamAggregator hook = new SlipstreamAggregator{salt: salt}(IPoolManager(poolManager), externalFactory);

        return address(hook);
    }
}
