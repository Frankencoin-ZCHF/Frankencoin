// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {MockV4FeeAdapter} from "../mocks/MockV4FeeAdapter.sol";
import {MockFluidDexT1} from "./mocks/MockFluidDexT1.sol";
import {MockFluidDexReservesResolver} from "./mocks/MockFluidDexReservesResolver.sol";
import {FluidDexT1Aggregator} from "../../../src/aggregator-hooks/implementations/FluidDexT1/FluidDexT1Aggregator.sol";
import {
    FluidDexT1AggregatorFactory
} from "../../../src/aggregator-hooks/implementations/FluidDexT1/FluidDexT1AggregatorFactory.sol";
import {
    IFluidDexResolver
} from "../../../src/aggregator-hooks/implementations/FluidDexT1/interfaces/IFluidDexResolver.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";

/// @dev Factory tests deploy full pools (hundreds of millions of gas per run); pinned low to keep CI fast (global default is raised in foundry.toml).
/// forge-config: default.fuzz.runs = 10
contract FluidDexT1FactoryUnitTest is Test {
    IPoolManager public poolManager;
    MockV4FeeAdapter public feeAdapter;
    MockFluidDexT1 public mockPool;
    MockFluidDexReservesResolver public mockResolver;
    MockERC20 public token0;
    MockERC20 public token1;

    uint24 constant FEE = 3000; // 0.3%
    int24 constant TICK_SPACING = 60; // Default tick spacing for a 0.3% fee pool
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 1:1
    /// @dev Fluid's convention for native ETH (matches FluidDexT1Aggregator)
    address constant FLUID_NATIVE_CURRENCY = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    address public fluidLiquidity = makeAddr("fluidLiquidity");

    function setUp() public {
        poolManager =
            IPoolManager(vm.deployCode("foundry-out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        mockPool = new MockFluidDexT1();
        mockResolver = new MockFluidDexReservesResolver();
        feeAdapter = new MockV4FeeAdapter(poolManager, address(this));

        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        if (address(token0) > address(token1)) (token0, token1) = (token1, token0);

        mockResolver.setDexTokens(address(token0), address(token1));
        mockPool.setTokens(address(token0), address(token1));
    }

    function test_factory_createPool() public {
        FluidDexT1AggregatorFactory factory = new FluidDexT1AggregatorFactory(
            poolManager, mockResolver, IFluidDexResolver(address(mockResolver)), fluidLiquidity
        );

        MockERC20 tkA = new MockERC20("A", "A", 18);
        MockERC20 tkB = new MockERC20("B", "B", 18);
        if (address(tkA) > address(tkB)) (tkA, tkB) = (tkB, tkA);

        MockFluidDexT1 pool2 = new MockFluidDexT1();
        mockResolver.setDexTokens(address(tkA), address(tkB));

        bytes memory args = abi.encode(
            address(poolManager), address(pool2), address(mockResolver), address(mockResolver), fluidLiquidity
        );
        (, bytes32 factorySalt) = HookMiner.find(
            address(factory),
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                    | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            ),
            type(FluidDexT1Aggregator).creationCode,
            args
        );

        address hookAddr = factory.createPool(
            factorySalt,
            pool2,
            Currency.wrap(address(tkA)),
            Currency.wrap(address(tkB)),
            FEE,
            TICK_SPACING,
            SQRT_PRICE_1_1
        );
        assertTrue(hookAddr != address(0));
    }

    function test_factory_computeAddress_matchesDeployedAddress() public {
        FluidDexT1AggregatorFactory factory = new FluidDexT1AggregatorFactory(
            poolManager, mockResolver, IFluidDexResolver(address(mockResolver)), fluidLiquidity
        );

        bytes memory args = abi.encode(
            address(poolManager), address(mockPool), address(mockResolver), address(mockResolver), fluidLiquidity
        );
        (, bytes32 factorySalt) = HookMiner.find(
            address(factory),
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                    | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            ),
            type(FluidDexT1Aggregator).creationCode,
            args
        );

        address computed = factory.computeAddress(factorySalt, mockPool);
        address deployed = factory.createPool(
            factorySalt,
            mockPool,
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            FEE,
            TICK_SPACING,
            SQRT_PRICE_1_1
        );

        assertEq(computed, deployed);
    }

    function testFuzz_factory_registryAndDuplicateProtection(address rawTokenA, address rawTokenB) public {
        vm.assume(rawTokenA != rawTokenB);
        vm.assume(rawTokenA != address(0) && rawTokenB != address(0));
        vm.assume(rawTokenA != FLUID_NATIVE_CURRENCY && rawTokenB != FLUID_NATIVE_CURRENCY);

        (address sorted0, address sorted1) = rawTokenA < rawTokenB ? (rawTokenA, rawTokenB) : (rawTokenB, rawTokenA);

        mockResolver.setDexTokens(sorted0, sorted1);
        mockPool.setTokens(sorted0, sorted1);

        FluidDexT1AggregatorFactory factory = new FluidDexT1AggregatorFactory(
            poolManager, mockResolver, IFluidDexResolver(address(mockResolver)), fluidLiquidity
        );

        assertEq(factory.deploymentCount(), 0);
        assertEq(factory.hookForPool(address(mockPool)), address(0));

        bytes memory args = abi.encode(
            address(poolManager), address(mockPool), address(mockResolver), address(mockResolver), fluidLiquidity
        );
        (, bytes32 factorySalt) = HookMiner.find(
            address(factory),
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                    | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            ),
            type(FluidDexT1Aggregator).creationCode,
            args
        );

        address hook = factory.createPool(
            factorySalt, mockPool, Currency.wrap(sorted0), Currency.wrap(sorted1), FEE, TICK_SPACING, SQRT_PRICE_1_1
        );

        assertEq(factory.deploymentCount(), 1);
        assertEq(factory.hookForPool(address(mockPool)), hook);

        FluidDexT1AggregatorFactory.Deployment memory deployment = factory.getDeployment(0);
        assertEq(deployment.hook, hook);
        assertEq(deployment.fluidPool, address(mockPool));
        assertEq(Currency.unwrap(deployment.poolKey.currency0), sorted0);
        assertEq(Currency.unwrap(deployment.poolKey.currency1), sorted1);
        assertEq(deployment.poolKey.fee, FEE);
        assertEq(deployment.poolKey.tickSpacing, TICK_SPACING);
        assertEq(address(deployment.poolKey.hooks), hook);

        // A second deployment for the same Fluid pool reverts regardless of salt
        vm.expectRevert(
            abi.encodeWithSelector(FluidDexT1AggregatorFactory.DuplicatePool.selector, address(mockPool), hook)
        );
        factory.createPool(
            bytes32(0), mockPool, Currency.wrap(sorted0), Currency.wrap(sorted1), FEE, TICK_SPACING, SQRT_PRICE_1_1
        );
    }
}
