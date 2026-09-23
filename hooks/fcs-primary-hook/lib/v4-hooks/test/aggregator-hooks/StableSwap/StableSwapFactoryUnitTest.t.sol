// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {MockCurveStableSwap} from "./mocks/MockCurveStableSwap.sol";
import {MockMetaRegistry} from "./mocks/MockMetaRegistry.sol";
import {MockV4FeeAdapter} from "../mocks/MockV4FeeAdapter.sol";
import {IMetaRegistry} from "../../../src/aggregator-hooks/implementations/StableSwap/interfaces/IMetaRegistry.sol";
import {StableSwapAggregator} from "../../../src/aggregator-hooks/implementations/StableSwap/StableSwapAggregator.sol";
import {
    StableSwapAggregatorFactory
} from "../../../src/aggregator-hooks/implementations/StableSwap/StableSwapAggregatorFactory.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";

/// @dev Factory tests deploy full pools; pinned low to keep CI fast (global default is raised in foundry.toml).
/// forge-config: default.fuzz.runs = 10
contract StableSwapFactoryUnitTest is Test {
    IPoolManager public poolManager;
    MockV4FeeAdapter public feeAdapter;
    MockCurveStableSwap public mockPool;
    MockMetaRegistry public mockMetaRegistry;
    MockERC20 public token0;
    MockERC20 public token1;

    uint24 constant FEE = 3000; // 0.3% fee
    int24 constant TICK_SPACING = 60; // Default tick spacing for a 0.3% fee pool
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 1:1 price
    /// @dev Curve's convention for native ETH (matches StableSwapAggregator)
    address constant CURVE_NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    function setUp() public {
        poolManager =
            IPoolManager(vm.deployCode("foundry-out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));

        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        if (address(token0) > address(token1)) (token0, token1) = (token1, token0);

        address[] memory coins = new address[](2);
        coins[0] = address(token0);
        coins[1] = address(token1);
        mockPool = new MockCurveStableSwap(coins);
        mockMetaRegistry = new MockMetaRegistry();
        mockMetaRegistry.setIsRegistered(address(mockPool), true);
        feeAdapter = new MockV4FeeAdapter(poolManager, address(this));
    }

    function test_factory_createPool() public {
        StableSwapAggregatorFactory factory =
            new StableSwapAggregatorFactory(poolManager, IMetaRegistry(address(mockMetaRegistry)));

        MockERC20 tkA = new MockERC20("A", "A", 18);
        MockERC20 tkB = new MockERC20("B", "B", 18);
        if (address(tkA) > address(tkB)) (tkA, tkB) = (tkB, tkA);

        address[] memory coins2 = new address[](2);
        coins2[0] = address(tkA);
        coins2[1] = address(tkB);
        MockCurveStableSwap pool2 = new MockCurveStableSwap(coins2);
        mockMetaRegistry.setIsRegistered(address(pool2), true);

        Currency[] memory tokens = new Currency[](2);
        tokens[0] = Currency.wrap(address(tkA));
        tokens[1] = Currency.wrap(address(tkB));

        bytes memory args = abi.encode(address(poolManager), address(pool2), address(mockMetaRegistry));
        (, bytes32 factorySalt) = HookMiner.find(
            address(factory),
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                    | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            ),
            type(StableSwapAggregator).creationCode,
            args
        );

        address hookAddr = factory.createPool(factorySalt, pool2, tokens, FEE, TICK_SPACING, SQRT_PRICE_1_1);
        assertTrue(hookAddr != address(0));
    }

    function test_factory_computeAddress_matchesDeployedAddress() public {
        StableSwapAggregatorFactory factory =
            new StableSwapAggregatorFactory(poolManager, IMetaRegistry(address(mockMetaRegistry)));

        Currency[] memory tokens = new Currency[](2);
        tokens[0] = Currency.wrap(address(token0));
        tokens[1] = Currency.wrap(address(token1));

        bytes memory args = abi.encode(address(poolManager), address(mockPool), address(mockMetaRegistry));
        (, bytes32 factorySalt) = HookMiner.find(
            address(factory),
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                    | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            ),
            type(StableSwapAggregator).creationCode,
            args
        );

        address computed = factory.computeAddress(factorySalt, mockPool);
        address deployed = factory.createPool(factorySalt, mockPool, tokens, FEE, TICK_SPACING, SQRT_PRICE_1_1);

        assertEq(computed, deployed);
    }

    function test_factory_revertsInsufficientTokens() public {
        StableSwapAggregatorFactory factory =
            new StableSwapAggregatorFactory(poolManager, IMetaRegistry(address(mockMetaRegistry)));

        Currency[] memory tokens = new Currency[](1);
        tokens[0] = Currency.wrap(address(token0));

        vm.expectRevert(StableSwapAggregatorFactory.InsufficientTokens.selector);
        factory.createPool(bytes32(0), mockPool, tokens, FEE, TICK_SPACING, SQRT_PRICE_1_1);
    }

    function testFuzz_factory_registryAndDuplicateProtection(address rawTokenA, address rawTokenB) public {
        vm.assume(rawTokenA != rawTokenB);
        vm.assume(rawTokenA != address(0) && rawTokenB != address(0));
        vm.assume(rawTokenA != CURVE_NATIVE_ETH && rawTokenB != CURVE_NATIVE_ETH);
        assumeUnusedAddress(rawTokenA);
        assumeUnusedAddress(rawTokenB);

        // The hook forceApproves both currencies to the Curve pool on initialize, so give them ERC20 code
        vm.etch(rawTokenA, address(token0).code);
        vm.etch(rawTokenB, address(token0).code);

        (address sorted0, address sorted1) = rawTokenA < rawTokenB ? (rawTokenA, rawTokenB) : (rawTokenB, rawTokenA);

        address[] memory coins = new address[](2);
        coins[0] = rawTokenA;
        coins[1] = rawTokenB;
        MockCurveStableSwap fuzzPool = new MockCurveStableSwap(coins);
        mockMetaRegistry.setIsRegistered(address(fuzzPool), true);

        StableSwapAggregatorFactory factory =
            new StableSwapAggregatorFactory(poolManager, IMetaRegistry(address(mockMetaRegistry)));

        assertEq(factory.deploymentCount(), 0);
        assertEq(factory.hookForPool(address(fuzzPool)), address(0));

        // Pass the tokens in fuzzed (possibly unsorted) order to exercise the factory's pair sorting
        Currency[] memory tokens = new Currency[](2);
        tokens[0] = Currency.wrap(rawTokenA);
        tokens[1] = Currency.wrap(rawTokenB);

        bytes memory args = abi.encode(address(poolManager), address(fuzzPool), address(mockMetaRegistry));
        (, bytes32 factorySalt) = HookMiner.find(
            address(factory),
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                    | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            ),
            type(StableSwapAggregator).creationCode,
            args
        );

        address hook = factory.createPool(factorySalt, fuzzPool, tokens, FEE, TICK_SPACING, SQRT_PRICE_1_1);

        assertEq(factory.deploymentCount(), 1);
        assertEq(factory.hookForPool(address(fuzzPool)), hook);

        StableSwapAggregatorFactory.Deployment memory deployment = factory.getDeployment(0);
        assertEq(deployment.hook, hook);
        assertEq(deployment.curvePool, address(fuzzPool));
        assertEq(deployment.poolKeys.length, 1);
        assertEq(Currency.unwrap(deployment.poolKeys[0].currency0), sorted0);
        assertEq(Currency.unwrap(deployment.poolKeys[0].currency1), sorted1);
        assertEq(deployment.poolKeys[0].fee, FEE);
        assertEq(deployment.poolKeys[0].tickSpacing, TICK_SPACING);
        assertEq(address(deployment.poolKeys[0].hooks), hook);

        // A second deployment for the same Curve pool reverts regardless of salt
        vm.expectRevert(
            abi.encodeWithSelector(StableSwapAggregatorFactory.DuplicatePool.selector, address(fuzzPool), hook)
        );
        factory.createPool(bytes32(0), fuzzPool, tokens, FEE, TICK_SPACING, SQRT_PRICE_1_1);
    }

    function test_factory_revertsTokenCountMismatch() public {
        StableSwapAggregatorFactory factory =
            new StableSwapAggregatorFactory(poolManager, IMetaRegistry(address(mockMetaRegistry)));

        // Too few: pool has 3 coins, only 2 tokens passed
        MockERC20 tkC = new MockERC20("C", "C", 18);
        address[] memory threeCoins = new address[](3);
        threeCoins[0] = address(token0);
        threeCoins[1] = address(token1);
        threeCoins[2] = address(tkC);
        mockPool.setCoins(threeCoins);

        Currency[] memory tooFew = new Currency[](2);
        tooFew[0] = Currency.wrap(address(token0));
        tooFew[1] = Currency.wrap(address(token1));
        vm.expectRevert(abi.encodeWithSelector(StableSwapAggregatorFactory.TokenCountMismatch.selector, 2));
        factory.createPool(bytes32(0), mockPool, tooFew, FEE, TICK_SPACING, SQRT_PRICE_1_1);

        // Too many: pool has 2 coins, 3 tokens passed
        address[] memory twoCoins = new address[](2);
        twoCoins[0] = address(token0);
        twoCoins[1] = address(token1);
        mockPool.setCoins(twoCoins);

        Currency[] memory tooMany = new Currency[](3);
        tooMany[0] = Currency.wrap(address(token0));
        tooMany[1] = Currency.wrap(address(token1));
        tooMany[2] = Currency.wrap(address(tkC));
        vm.expectRevert(abi.encodeWithSelector(StableSwapAggregatorFactory.TokenCountMismatch.selector, 3));
        factory.createPool(bytes32(0), mockPool, tooMany, FEE, TICK_SPACING, SQRT_PRICE_1_1);
    }

    function test_factory_revertsDuplicateTokens() public {
        StableSwapAggregatorFactory factory =
            new StableSwapAggregatorFactory(poolManager, IMetaRegistry(address(mockMetaRegistry)));

        Currency[] memory tokens = new Currency[](3);
        tokens[0] = Currency.wrap(address(token0));
        tokens[1] = Currency.wrap(address(token1));
        tokens[2] = Currency.wrap(address(token0));

        vm.expectRevert(
            abi.encodeWithSelector(StableSwapAggregatorFactory.DuplicateTokens.selector, Currency.wrap(address(token0)))
        );
        factory.createPool(bytes32(0), mockPool, tokens, FEE, TICK_SPACING, SQRT_PRICE_1_1);
    }
}
