// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {MockV4FeeAdapter} from "../mocks/MockV4FeeAdapter.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {MockFluidDexLite} from "./mocks/MockFluidDexLite.sol";
import {MockFluidDexLiteResolver} from "./mocks/MockFluidDexLiteResolver.sol";
import {
    FluidDexLiteAggregator
} from "../../../src/aggregator-hooks/implementations/FluidDexLite/FluidDexLiteAggregator.sol";
import {
    FluidDexLiteAggregatorFactory
} from "../../../src/aggregator-hooks/implementations/FluidDexLite/FluidDexLiteAggregatorFactory.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";

/// @dev Factory tests deploy full pools (hundreds of millions of gas per run); pinned low to keep CI fast (global default is raised in foundry.toml).
/// forge-config: default.fuzz.runs = 10
contract FluidDexLiteFactoryUnitTest is Test {
    IPoolManager public poolManager;
    MockV4FeeAdapter public feeAdapter;
    MockFluidDexLite public mockDex;
    MockFluidDexLiteResolver public mockResolver;
    MockERC20 public token0;
    MockERC20 public token1;

    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    /// @dev Fluid's convention for native ETH (matches FluidDexLiteAggregator)
    address constant FLUID_NATIVE_CURRENCY = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    function setUp() public {
        poolManager =
            IPoolManager(vm.deployCode("foundry-out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        mockDex = new MockFluidDexLite();
        mockResolver = new MockFluidDexLiteResolver();
        feeAdapter = new MockV4FeeAdapter(poolManager, address(this));

        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        if (address(token0) > address(token1)) (token0, token1) = (token1, token0);
    }

    function test_factory_createPool() public {
        FluidDexLiteAggregatorFactory factory = new FluidDexLiteAggregatorFactory(poolManager, mockDex, mockResolver);

        MockERC20 tkA = new MockERC20("A", "A", 18);
        MockERC20 tkB = new MockERC20("B", "B", 18);
        if (address(tkA) > address(tkB)) (tkA, tkB) = (tkB, tkA);

        bytes32 dexSalt = bytes32(uint256(42));
        bytes memory args = abi.encode(address(poolManager), address(mockDex), address(mockResolver), dexSalt);
        (, bytes32 factorySalt) = HookMiner.find(
            address(factory),
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                    | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            ),
            type(FluidDexLiteAggregator).creationCode,
            args
        );

        address hookAddr = factory.createPool(
            factorySalt,
            dexSalt,
            Currency.wrap(address(tkA)),
            Currency.wrap(address(tkB)),
            FEE,
            TICK_SPACING,
            SQRT_PRICE_1_1
        );
        assertTrue(hookAddr != address(0));
    }

    function test_factory_computeAddress_matchesDeployedAddress() public {
        FluidDexLiteAggregatorFactory factory = new FluidDexLiteAggregatorFactory(poolManager, mockDex, mockResolver);

        bytes32 dexSalt = bytes32(uint256(99));
        bytes memory args = abi.encode(address(poolManager), address(mockDex), address(mockResolver), dexSalt);
        (, bytes32 factorySalt) = HookMiner.find(
            address(factory),
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                    | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            ),
            type(FluidDexLiteAggregator).creationCode,
            args
        );

        address computed = factory.computeAddress(factorySalt, dexSalt);
        address deployed = factory.createPool(
            factorySalt,
            dexSalt,
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

        FluidDexLiteAggregatorFactory factory = new FluidDexLiteAggregatorFactory(poolManager, mockDex, mockResolver);

        assertEq(factory.deploymentCount(), 0);

        bytes32 dexSalt = bytes32(uint256(7));
        bytes32 dexKeyHash = keccak256(abi.encode(Currency.wrap(sorted0), Currency.wrap(sorted1), dexSalt));
        assertEq(factory.hookForDexKeyHash(dexKeyHash), address(0));

        bytes memory args = abi.encode(address(poolManager), address(mockDex), address(mockResolver), dexSalt);
        (, bytes32 factorySalt) = HookMiner.find(
            address(factory),
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                    | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            ),
            type(FluidDexLiteAggregator).creationCode,
            args
        );

        address hook = factory.createPool(
            factorySalt, dexSalt, Currency.wrap(sorted0), Currency.wrap(sorted1), FEE, TICK_SPACING, SQRT_PRICE_1_1
        );

        assertEq(factory.deploymentCount(), 1);
        assertEq(factory.hookForDexKeyHash(dexKeyHash), hook);

        FluidDexLiteAggregatorFactory.Deployment memory deployment = factory.getDeployment(0);
        assertEq(deployment.hook, hook);
        assertEq(deployment.dexSalt, dexSalt);
        assertEq(Currency.unwrap(deployment.poolKey.currency0), sorted0);
        assertEq(Currency.unwrap(deployment.poolKey.currency1), sorted1);
        assertEq(deployment.poolKey.fee, FEE);
        assertEq(deployment.poolKey.tickSpacing, TICK_SPACING);
        assertEq(address(deployment.poolKey.hooks), hook);

        // A second deployment for the same Fluid pool (same currencies + dexSalt) reverts regardless of salt
        vm.expectRevert(
            abi.encodeWithSelector(
                FluidDexLiteAggregatorFactory.DuplicatePool.selector,
                dexSalt,
                Currency.wrap(sorted0),
                Currency.wrap(sorted1),
                hook
            )
        );
        factory.createPool(
            bytes32(0), dexSalt, Currency.wrap(sorted0), Currency.wrap(sorted1), FEE, TICK_SPACING, SQRT_PRICE_1_1
        );
    }

    function test_factory_sameDexSaltDifferentPair_deploysSecondHook() public {
        FluidDexLiteAggregatorFactory factory = new FluidDexLiteAggregatorFactory(poolManager, mockDex, mockResolver);

        // Fluid pools of different token pairs commonly share the same dexSalt
        bytes32 dexSalt = bytes32(0);
        bytes memory args = abi.encode(address(poolManager), address(mockDex), address(mockResolver), dexSalt);
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );

        (, bytes32 factorySalt) =
            HookMiner.find(address(factory), flags, type(FluidDexLiteAggregator).creationCode, args);
        address hookA = factory.createPool(
            factorySalt,
            dexSalt,
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            FEE,
            TICK_SPACING,
            SQRT_PRICE_1_1
        );

        MockERC20 tkC = new MockERC20("C", "C", 18);
        MockERC20 tkD = new MockERC20("D", "D", 18);
        if (address(tkC) > address(tkD)) (tkC, tkD) = (tkD, tkC);

        // The first hook now occupies the mined address, so mine a fresh salt for the second pool
        (, bytes32 factorySalt2) =
            HookMiner.find(address(factory), flags, type(FluidDexLiteAggregator).creationCode, args);
        address hookB = factory.createPool(
            factorySalt2,
            dexSalt,
            Currency.wrap(address(tkC)),
            Currency.wrap(address(tkD)),
            FEE,
            TICK_SPACING,
            SQRT_PRICE_1_1
        );

        assertTrue(hookB != address(0));
        assertTrue(hookA != hookB);
        assertEq(factory.deploymentCount(), 2);

        bytes32 hashA = keccak256(abi.encode(Currency.wrap(address(token0)), Currency.wrap(address(token1)), dexSalt));
        bytes32 hashB = keccak256(abi.encode(Currency.wrap(address(tkC)), Currency.wrap(address(tkD)), dexSalt));
        assertEq(factory.hookForDexKeyHash(hashA), hookA);
        assertEq(factory.hookForDexKeyHash(hashB), hookB);
    }
}
