// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {MockV4FeeAdapter} from "../mocks/MockV4FeeAdapter.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {MockCurveStableSwapNG} from "./mocks/MockCurveStableSwapNG.sol";
import {MockCurveStableSwapFactoryNG} from "./mocks/MockCurveStableSwapFactoryNG.sol";
import {
    StableSwapNGAggregator
} from "../../../src/aggregator-hooks/implementations/StableSwapNG/StableSwapNGAggregator.sol";
import {
    StableSwapNGAggregatorFactory
} from "../../../src/aggregator-hooks/implementations/StableSwapNG/StableSwapNGAggregatorFactory.sol";
import {
    ICurveStableSwapFactoryNG
} from "../../../src/aggregator-hooks/implementations/StableSwapNG/interfaces/ICurveStableSwapFactoryNG.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";

/// @dev Factory tests deploy full pools; pinned low to keep CI fast (global default is raised in foundry.toml).
/// forge-config: default.fuzz.runs = 10
contract StableSwapNGFactoryUnitTest is Test {
    IPoolManager public poolManager;
    MockV4FeeAdapter public feeAdapter;
    MockCurveStableSwapNG public mockPool;
    MockCurveStableSwapFactoryNG public mockFactory;
    MockERC20 public token0;
    MockERC20 public token1;

    uint24 constant FEE = 3000; // 0.3% fee
    int24 constant TICK_SPACING = 60; // Default tick spacing for a 0.3% fee pool
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 1:1 price

    function setUp() public {
        poolManager =
            IPoolManager(vm.deployCode("foundry-out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));

        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        if (address(token0) > address(token1)) (token0, token1) = (token1, token0);

        address[] memory coins = new address[](2);
        coins[0] = address(token0);
        coins[1] = address(token1);
        mockPool = new MockCurveStableSwapNG(coins);
        mockFactory = new MockCurveStableSwapFactoryNG();
        mockFactory.setNCoins(address(mockPool), 2);
        feeAdapter = new MockV4FeeAdapter(poolManager, address(this));
    }

    function test_factory_createPool() public {
        StableSwapNGAggregatorFactory factory =
            new StableSwapNGAggregatorFactory(poolManager, ICurveStableSwapFactoryNG(address(mockFactory)));

        MockERC20 tkA = new MockERC20("A", "A", 18);
        MockERC20 tkB = new MockERC20("B", "B", 18);
        if (address(tkA) > address(tkB)) (tkA, tkB) = (tkB, tkA);

        address[] memory coins2 = new address[](2);
        coins2[0] = address(tkA);
        coins2[1] = address(tkB);
        MockCurveStableSwapNG pool2 = new MockCurveStableSwapNG(coins2);
        mockFactory.setNCoins(address(pool2), 2);

        Currency[] memory tokens = new Currency[](2);
        tokens[0] = Currency.wrap(address(tkA));
        tokens[1] = Currency.wrap(address(tkB));

        bytes memory args = abi.encode(address(poolManager), address(pool2), address(mockFactory));
        (, bytes32 factorySalt) = HookMiner.find(
            address(factory),
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                    | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            ),
            type(StableSwapNGAggregator).creationCode,
            args
        );

        address hookAddr = factory.createPool(factorySalt, pool2, tokens, FEE, TICK_SPACING, SQRT_PRICE_1_1);
        assertTrue(hookAddr != address(0));
    }

    function test_factory_computeAddress_matchesDeployedAddress() public {
        StableSwapNGAggregatorFactory factory =
            new StableSwapNGAggregatorFactory(poolManager, ICurveStableSwapFactoryNG(address(mockFactory)));

        Currency[] memory tokens = new Currency[](2);
        tokens[0] = Currency.wrap(address(token0));
        tokens[1] = Currency.wrap(address(token1));

        bytes memory args = abi.encode(address(poolManager), address(mockPool), address(mockFactory));
        (, bytes32 factorySalt) = HookMiner.find(
            address(factory),
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                    | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            ),
            type(StableSwapNGAggregator).creationCode,
            args
        );

        address computed = factory.computeAddress(factorySalt, mockPool);
        address deployed = factory.createPool(factorySalt, mockPool, tokens, FEE, TICK_SPACING, SQRT_PRICE_1_1);

        assertEq(computed, deployed);
    }

    function test_factory_revertsInsufficientTokens() public {
        StableSwapNGAggregatorFactory factory =
            new StableSwapNGAggregatorFactory(poolManager, ICurveStableSwapFactoryNG(address(mockFactory)));

        Currency[] memory tokens = new Currency[](1);
        tokens[0] = Currency.wrap(address(token0));

        vm.expectRevert(StableSwapNGAggregatorFactory.InsufficientTokens.selector);
        factory.createPool(bytes32(0), mockPool, tokens, FEE, TICK_SPACING, SQRT_PRICE_1_1);
    }

    function testFuzz_factory_registryAndDuplicateProtection(address rawTokenA, address rawTokenB) public {
        vm.assume(rawTokenA != rawTokenB);
        vm.assume(rawTokenA != address(0) && rawTokenB != address(0));
        assumeUnusedAddress(rawTokenA);
        assumeUnusedAddress(rawTokenB);

        // The hook forceApproves both currencies to the Curve pool on initialize, so give them ERC20 code
        vm.etch(rawTokenA, address(token0).code);
        vm.etch(rawTokenB, address(token0).code);

        (address sorted0, address sorted1) = rawTokenA < rawTokenB ? (rawTokenA, rawTokenB) : (rawTokenB, rawTokenA);

        address[] memory coins = new address[](2);
        coins[0] = rawTokenA;
        coins[1] = rawTokenB;
        MockCurveStableSwapNG fuzzPool = new MockCurveStableSwapNG(coins);
        mockFactory.setNCoins(address(fuzzPool), 2);

        StableSwapNGAggregatorFactory factory =
            new StableSwapNGAggregatorFactory(poolManager, ICurveStableSwapFactoryNG(address(mockFactory)));

        assertEq(factory.deploymentCount(), 0);
        assertEq(factory.hookForPool(address(fuzzPool)), address(0));

        // Pass the tokens in fuzzed (possibly unsorted) order to exercise the factory's pair sorting
        Currency[] memory tokens = new Currency[](2);
        tokens[0] = Currency.wrap(rawTokenA);
        tokens[1] = Currency.wrap(rawTokenB);

        bytes memory args = abi.encode(address(poolManager), address(fuzzPool), address(mockFactory));
        (, bytes32 factorySalt) = HookMiner.find(
            address(factory),
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                    | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            ),
            type(StableSwapNGAggregator).creationCode,
            args
        );

        address hook = factory.createPool(factorySalt, fuzzPool, tokens, FEE, TICK_SPACING, SQRT_PRICE_1_1);

        assertEq(factory.deploymentCount(), 1);
        assertEq(factory.hookForPool(address(fuzzPool)), hook);

        StableSwapNGAggregatorFactory.Deployment memory deployment = factory.getDeployment(0);
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
            abi.encodeWithSelector(StableSwapNGAggregatorFactory.DuplicatePool.selector, address(fuzzPool), hook)
        );
        factory.createPool(bytes32(0), fuzzPool, tokens, FEE, TICK_SPACING, SQRT_PRICE_1_1);
    }

    function test_factory_revertsTokenCountMismatch() public {
        StableSwapNGAggregatorFactory factory =
            new StableSwapNGAggregatorFactory(poolManager, ICurveStableSwapFactoryNG(address(mockFactory)));

        // Too few: pool reports 3 coins, only 2 tokens passed
        mockFactory.setNCoins(address(mockPool), 3);
        Currency[] memory tooFew = new Currency[](2);
        tooFew[0] = Currency.wrap(address(token0));
        tooFew[1] = Currency.wrap(address(token1));
        vm.expectRevert(abi.encodeWithSelector(StableSwapNGAggregatorFactory.TokenCountMismatch.selector, 2, 3));
        factory.createPool(bytes32(0), mockPool, tooFew, FEE, TICK_SPACING, SQRT_PRICE_1_1);

        // Too many: pool reports 2 coins, 3 tokens passed
        mockFactory.setNCoins(address(mockPool), 2);
        MockERC20 tkC = new MockERC20("C", "C", 18);
        Currency[] memory tooMany = new Currency[](3);
        tooMany[0] = Currency.wrap(address(token0));
        tooMany[1] = Currency.wrap(address(token1));
        tooMany[2] = Currency.wrap(address(tkC));
        vm.expectRevert(abi.encodeWithSelector(StableSwapNGAggregatorFactory.TokenCountMismatch.selector, 3, 2));
        factory.createPool(bytes32(0), mockPool, tooMany, FEE, TICK_SPACING, SQRT_PRICE_1_1);
    }

    function test_factory_revertsDuplicateTokens() public {
        StableSwapNGAggregatorFactory factory =
            new StableSwapNGAggregatorFactory(poolManager, ICurveStableSwapFactoryNG(address(mockFactory)));

        Currency[] memory tokens = new Currency[](3);
        tokens[0] = Currency.wrap(address(token0));
        tokens[1] = Currency.wrap(address(token1));
        tokens[2] = Currency.wrap(address(token0));

        vm.expectRevert(
            abi.encodeWithSelector(
                StableSwapNGAggregatorFactory.DuplicateTokens.selector, Currency.wrap(address(token0))
            )
        );
        factory.createPool(bytes32(0), mockPool, tokens, FEE, TICK_SPACING, SQRT_PRICE_1_1);
    }
}
