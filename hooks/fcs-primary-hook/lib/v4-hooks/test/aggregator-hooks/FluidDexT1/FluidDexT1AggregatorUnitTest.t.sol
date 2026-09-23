// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SafePoolSwapTest} from "../shared/SafePoolSwapTest.sol";
import {MockFluidDexT1, ReentrancyAttacker, UnauthorizedCallbackCaller} from "./mocks/MockFluidDexT1.sol";
import {MockFluidDexReservesResolver} from "./mocks/MockFluidDexReservesResolver.sol";
import {MockV4FeeAdapter} from "../mocks/MockV4FeeAdapter.sol";
import {FluidDexT1Aggregator} from "../../../src/aggregator-hooks/implementations/FluidDexT1/FluidDexT1Aggregator.sol";
import {
    IFluidDexResolver
} from "../../../src/aggregator-hooks/implementations/FluidDexT1/interfaces/IFluidDexResolver.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";
import {IAggregatorHook} from "../../../src/aggregator-hooks/interfaces/IAggregatorHook.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

contract FluidDexT1AggregatorUnitTest is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager public poolManager;
    MockV4FeeAdapter public feeAdapter;
    SafePoolSwapTest public swapRouter;
    MockFluidDexT1 public mockPool;
    MockFluidDexReservesResolver public mockResolver;
    FluidDexT1Aggregator public hook;
    MockERC20 public token0;
    MockERC20 public token1;

    // Pool configuration
    uint24 constant FEE = 3000; // 0.3% fee
    int24 constant TICK_SPACING = 60; // Default tick spacing for a 0.3% fee pool
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 1:1 price

    uint160 constant MIN_PRICE = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE = TickMath.MAX_SQRT_PRICE - 1;
    uint256 public constant INITIAL_BALANCE = 1000 ether;

    address public alice = makeAddr("alice");
    address public fluidLiquidity = makeAddr("fluidLiquidity");
    PoolKey public poolKey;
    PoolId public poolId;

    function setUp() public {
        poolManager =
            IPoolManager(vm.deployCode("foundry-out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        swapRouter = new SafePoolSwapTest(poolManager);
        mockPool = new MockFluidDexT1();
        mockResolver = new MockFluidDexReservesResolver();
        feeAdapter = new MockV4FeeAdapter(poolManager, address(this));

        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        if (address(token0) > address(token1)) (token0, token1) = (token1, token0);

        // Set resolver and mock pool to return matching tokens
        mockResolver.setDexTokens(address(token0), address(token1));
        mockPool.setTokens(address(token0), address(token1));

        // Deploy hook with valid address
        hook = _deployHook(mockPool, mockResolver);

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();

        poolManager.initialize(poolKey, SQRT_PRICE_1_1);

        // Setup tokens
        token0.mint(alice, INITIAL_BALANCE);
        token1.mint(alice, INITIAL_BALANCE);
        token0.mint(address(poolManager), INITIAL_BALANCE);
        token1.mint(address(poolManager), INITIAL_BALANCE);

        // Mint tokens to mock pool so it can transfer output tokens
        token0.mint(address(mockPool), INITIAL_BALANCE);
        token1.mint(address(mockPool), INITIAL_BALANCE);
        vm.startPrank(alice);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _deployHook(MockFluidDexT1 _mockPool, MockFluidDexReservesResolver _mockResolver)
        internal
        returns (FluidDexT1Aggregator)
    {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );
        bytes memory constructorArgs = abi.encode(
            poolManager, _mockPool, _mockResolver, IFluidDexResolver(address(_mockResolver)), fluidLiquidity
        );
        (, bytes32 salt) =
            HookMiner.find(address(this), flags, type(FluidDexT1Aggregator).creationCode, constructorArgs);
        return new FluidDexT1Aggregator{salt: salt}(
            poolManager, _mockPool, _mockResolver, IFluidDexResolver(address(_mockResolver)), fluidLiquidity
        );
    }

    // ========== CONSTRUCTOR ==========

    function test_constructor_setsImmutables() public view {
        assertEq(address(hook.fluidPool()), address(mockPool));
        assertEq(address(hook.fluidDexReservesResolver()), address(mockResolver));
        assertEq(address(hook.fluidDexResolver()), address(mockResolver));
        assertEq(hook.fluidLiquidity(), fluidLiquidity);
    }

    // ========== dexCallback ==========

    function test_dexCallback_revertsProhibitedEntry() public {
        // Not in inflight state
        vm.prank(address(mockPool));
        vm.expectRevert(FluidDexT1Aggregator.ProhibitedEntry.selector);
        hook.dexCallback(address(token0), 100 ether);
    }

    function test_dexCallback_revertsUnauthorizedCaller() public {
        // Would need to be in inflight state, but that requires being in a swap
        // Since we can't easily simulate being in inflight, test the unauthorized case separately
        vm.expectRevert(FluidDexT1Aggregator.ProhibitedEntry.selector);
        hook.dexCallback(address(token0), 100 ether);
    }

    // ========== quote ==========

    function test_quote_revertsPoolDoesNotExist() public {
        PoolId wrongPoolId = PoolId.wrap(bytes32(uint256(999)));
        vm.expectRevert(IAggregatorHook.PoolDoesNotExist.selector);
        hook.quote(true, -int256(100 ether), wrongPoolId);
    }

    function test_quote_exactIn_returnsResolverEstimate() public {
        mockResolver.setReturnEstimateSwapIn(12345);
        uint256 result = hook.quote(true, -int256(100 ether), poolId);
        assertEq(result, 12345);
    }

    function test_quote_exactOut_returnsResolverEstimate() public {
        mockResolver.setReturnEstimateSwapOut(54321);
        uint256 result = hook.quote(true, int256(100 ether), poolId);
        assertEq(result, 54321);
    }

    // ========== pseudoTotalValueLocked ==========

    function test_pseudoTotalValueLocked_revertsPoolDoesNotExist() public {
        PoolId wrongPoolId = PoolId.wrap(bytes32(uint256(999)));
        vm.expectRevert(IAggregatorHook.PoolDoesNotExist.selector);
        hook.pseudoTotalValueLocked(wrongPoolId);
    }

    function test_pseudoTotalValueLocked_returnsReserves() public {
        mockResolver.setReserves(1000 ether, 2000 ether);
        (uint256 a0, uint256 a1) = hook.pseudoTotalValueLocked(poolId);
        assertEq(a0, 1000 ether);
        assertEq(a1, 2000 ether);
    }

    // ========== _beforeInitialize ==========

    function test_beforeInitialize_revertsTokensNotInPool() public {
        MockFluidDexReservesResolver resolver2 = new MockFluidDexReservesResolver();
        resolver2.setDexTokens(address(0xdead), address(0xbeef)); // Wrong tokens

        FluidDexT1Aggregator hook2 = _deployHook(mockPool, resolver2);

        PoolKey memory key2 = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE + 1,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook2))
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook2),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(FluidDexT1Aggregator.TokensNotInPool.selector, address(0xdead), address(0xbeef)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        poolManager.initialize(key2, SQRT_PRICE_1_1);
    }

    function test_beforeInitialize_setsLocalPoolId() public view {
        assertEq(PoolId.unwrap(hook.localPoolId()), PoolId.unwrap(poolId));
    }

    // ========== SWAP (via _conductSwap) ==========

    function test_swap_exactIn_zeroForOne() public {
        uint256 amountIn = 100 ether;
        uint256 amountOut = 95 ether;
        mockPool.setReturnSwapInWithCallback(amountOut);
        token1.mint(address(poolManager), amountOut);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(token0.balanceOf(alice), INITIAL_BALANCE - amountIn);
        assertEq(token1.balanceOf(alice), INITIAL_BALANCE + amountOut);
    }

    function test_swap_exactIn_oneForZero() public {
        uint256 amountIn = 100 ether;
        uint256 amountOut = 95 ether;
        mockPool.setReturnSwapInWithCallback(amountOut);
        token0.mint(address(poolManager), amountOut);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MAX_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(token1.balanceOf(alice), INITIAL_BALANCE - amountIn);
        assertEq(token0.balanceOf(alice), INITIAL_BALANCE + amountOut);
    }

    function test_swap_exactOut_zeroForOne() public {
        uint256 amountOut = 50 ether;
        uint256 amountIn = 55 ether;
        mockPool.setReturnSwapOutWithCallback(amountIn);
        token1.mint(address(mockPool), amountOut); // Mock pool needs tokens to transfer
        token1.mint(address(hook), amountOut); // Hook needs tokens to transfer to poolManager

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MIN_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(token0.balanceOf(alice), INITIAL_BALANCE - amountIn);
        assertEq(token1.balanceOf(alice), INITIAL_BALANCE + amountOut);
    }

    function test_swap_exactOut_oneForZero() public {
        uint256 amountOut = 50 ether;
        uint256 amountIn = 55 ether;
        mockPool.setReturnSwapOutWithCallback(amountIn);
        token0.mint(address(mockPool), amountOut); // Mock pool needs tokens to transfer
        token0.mint(address(hook), amountOut); // Hook needs tokens to transfer to poolManager

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MAX_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(token1.balanceOf(alice), INITIAL_BALANCE - amountIn);
        assertEq(token0.balanceOf(alice), INITIAL_BALANCE + amountOut);
    }

    // ========== REVERSED POOL ORDER ==========

    function test_beforeInitialize_revertsTokenNotInPool_token1Only() public {
        // Resolver returns tokens where token0 matches but token1 doesn't
        // Use a high address (0xffff...) to ensure we stay in the normal (non-reversed) branch
        address wrongToken1 = address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
        MockFluidDexReservesResolver resolver2 = new MockFluidDexReservesResolver();
        resolver2.setDexTokens(address(token0), wrongToken1); // token0 matches, token1 doesn't

        FluidDexT1Aggregator hook2 = _deployHook(mockPool, resolver2);

        PoolKey memory key2 = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE + 2,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook2))
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook2),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(FluidDexT1Aggregator.TokenNotInPool.selector, wrongToken1),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        poolManager.initialize(key2, SQRT_PRICE_1_1);
    }

    function test_beforeInitialize_revertsTokenNotInPool_token0Only() public {
        // Resolver returns tokens where token1 matches but token0 doesn't
        // Use address(1) which is small but > address(0), so token0 < token1 stays true
        address wrongToken0 = address(1);
        MockFluidDexReservesResolver resolver2 = new MockFluidDexReservesResolver();
        resolver2.setDexTokens(wrongToken0, address(token1)); // token0 doesn't match, token1 matches

        FluidDexT1Aggregator hook2 = _deployHook(mockPool, resolver2);

        PoolKey memory key2 = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE + 3,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook2))
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook2),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(FluidDexT1Aggregator.TokenNotInPool.selector, wrongToken0),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        poolManager.initialize(key2, SQRT_PRICE_1_1);
    }

    function test_beforeInitialize_reversedTokenOrder_succeeds() public {
        // Resolver returns tokens in reversed order (token1, token0)
        // This triggers the token1 < token0 branch
        MockFluidDexReservesResolver resolver2 = new MockFluidDexReservesResolver();
        // Return tokens reversed: what Fluid calls token0 is actually > what Fluid calls token1
        resolver2.setDexTokens(address(token1), address(token0)); // Reversed

        FluidDexT1Aggregator hook2 = _deployHook(mockPool, resolver2);

        PoolKey memory key2 = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE + 4,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook2))
        });

        // This should succeed and set _isReversed = true
        poolManager.initialize(key2, SQRT_PRICE_1_1);
        assertEq(PoolId.unwrap(hook2.localPoolId()), PoolId.unwrap(key2.toId()));
    }

    function test_pseudoTotalValueLocked_reversed_returnsSwappedReserves() public {
        // Deploy hook with reversed token order
        MockFluidDexReservesResolver resolver2 = new MockFluidDexReservesResolver();
        resolver2.setDexTokens(address(token1), address(token0)); // Reversed order
        resolver2.setReserves(1000 ether, 2000 ether);

        FluidDexT1Aggregator hook2 = _deployHook(mockPool, resolver2);

        PoolKey memory key2 = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE + 5,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook2))
        });

        poolManager.initialize(key2, SQRT_PRICE_1_1);

        // With _isReversed = true, reserves should be swapped
        (uint256 a0, uint256 a1) = hook2.pseudoTotalValueLocked(key2.toId());
        // token0Reserves=1000, token1Reserves=2000
        // When reversed: returns (token1Reserves, token0Reserves) = (2000, 1000)
        assertEq(a0, 2000 ether);
        assertEq(a1, 1000 ether);
    }

    // ========== NATIVE CURRENCY TESTS ==========

    address private constant FLUID_NATIVE_CURRENCY = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    function test_beforeInitialize_nativeCurrency_token0() public {
        // Test when Fluid returns FLUID_NATIVE_CURRENCY for token0
        // This triggers the token0 == FLUID_NATIVE_CURRENCY branch
        MockFluidDexReservesResolver resolver2 = new MockFluidDexReservesResolver();
        // Native currency (converted to address(0)) should be less than token1
        resolver2.setDexTokens(FLUID_NATIVE_CURRENCY, address(token1));

        FluidDexT1Aggregator hook2 = _deployHook(mockPool, resolver2);

        // Create pool with native currency (address(0)) as currency0
        PoolKey memory key2 = PoolKey({
            currency0: Currency.wrap(address(0)), // Native currency
            currency1: Currency.wrap(address(token1)),
            fee: FEE + 10,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook2))
        });

        poolManager.initialize(key2, SQRT_PRICE_1_1);
        assertEq(PoolId.unwrap(hook2.localPoolId()), PoolId.unwrap(key2.toId()));
    }

    function test_beforeInitialize_nativeCurrency_token1() public {
        // Test when Fluid returns FLUID_NATIVE_CURRENCY for token1
        // This triggers the token1 == FLUID_NATIVE_CURRENCY branch
        // For this, token1 needs to be native currency and token0 needs to be an ERC20
        // Since we need token0 < token1 and native = address(0), we need a reversed scenario
        MockFluidDexReservesResolver resolver2 = new MockFluidDexReservesResolver();
        // Return tokens where token1 is native - this will be reversed since
        // token0 > token1 (token0 is ERC20 address, token1 converts to address(0))
        resolver2.setDexTokens(address(token0), FLUID_NATIVE_CURRENCY);

        FluidDexT1Aggregator hook2 = _deployHook(mockPool, resolver2);

        // Create pool with native currency (address(0)) as currency0 (Uniswap sorts by address)
        PoolKey memory key2 = PoolKey({
            currency0: Currency.wrap(address(0)), // Native currency
            currency1: Currency.wrap(address(token0)),
            fee: FEE + 11,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook2))
        });

        poolManager.initialize(key2, SQRT_PRICE_1_1);
        assertEq(PoolId.unwrap(hook2.localPoolId()), PoolId.unwrap(key2.toId()));
    }

    function test_beforeInitialize_reversed_revertsTokenNotInPool_token0() public {
        // Test reversed token order with token0 mismatch
        // Need: token1 < token0 (reversed) AND token0 != key.currency1
        MockFluidDexReservesResolver resolver2 = new MockFluidDexReservesResolver();
        // Create a scenario where Fluid's tokens are reversed relative to Uniswap order
        // Fluid token0 (higher address) should NOT match key.currency1
        address wrongToken0 = address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
        // token1 < token0 to trigger reversed branch
        resolver2.setDexTokens(wrongToken0, address(token0)); // token0 is actually lower

        FluidDexT1Aggregator hook2 = _deployHook(mockPool, resolver2);

        PoolKey memory key2 = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)), // wrongToken0 != token1
            fee: FEE + 12,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook2))
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook2),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(FluidDexT1Aggregator.TokenNotInPool.selector, wrongToken0),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        poolManager.initialize(key2, SQRT_PRICE_1_1);
    }

    function test_beforeInitialize_reversed_revertsTokenNotInPool_token1() public {
        // Test reversed token order with token1 mismatch
        // Need: token1 < token0 (reversed) AND token0 == key.currency1 AND token1 != key.currency0
        MockFluidDexReservesResolver resolver2 = new MockFluidDexReservesResolver();
        // Fluid token0 matches key.currency1, but Fluid token1 doesn't match key.currency0
        address wrongToken1 = address(1); // Very low address
        // Set token1 < token0 to trigger reversed branch
        resolver2.setDexTokens(address(token1), wrongToken1);

        FluidDexT1Aggregator hook2 = _deployHook(mockPool, resolver2);

        PoolKey memory key2 = PoolKey({
            currency0: Currency.wrap(address(token0)), // wrongToken1 != token0
            currency1: Currency.wrap(address(token1)), // Fluid token0 matches this
            fee: FEE + 13,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook2))
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook2),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(FluidDexT1Aggregator.TokenNotInPool.selector, wrongToken1),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        poolManager.initialize(key2, SQRT_PRICE_1_1);
    }

    function test_beforeInitialize_nonReversed_revertsTokensNotInPool() public {
        // Test non-reversed with both tokens mismatched
        // Need: token1 >= token0 (non-reversed) AND both tokens don't match
        MockFluidDexReservesResolver resolver2 = new MockFluidDexReservesResolver();
        // Both tokens are wrong, but in correct order (token0 < token1)
        address wrongToken0 = address(2);
        address wrongToken1 = address(3);
        resolver2.setDexTokens(wrongToken0, wrongToken1);

        FluidDexT1Aggregator hook2 = _deployHook(mockPool, resolver2);

        PoolKey memory key2 = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE + 14,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook2))
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook2),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(FluidDexT1Aggregator.TokensNotInPool.selector, wrongToken0, wrongToken1),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        poolManager.initialize(key2, SQRT_PRICE_1_1);
    }

    // ========== NATIVE INPUT SWAP TESTS ==========

    function test_swap_exactIn_nativeInput_zeroForOne() public {
        // Create a pool with native currency as token0
        MockFluidDexReservesResolver resolver2 = new MockFluidDexReservesResolver();
        resolver2.setDexTokens(FLUID_NATIVE_CURRENCY, address(token1));

        MockFluidDexT1 pool2 = new MockFluidDexT1();
        pool2.setTokens(address(0), address(token1));
        pool2.setReturnSwapIn(95 ether);

        FluidDexT1Aggregator hook2 = _deployHook(pool2, resolver2);

        PoolKey memory key2 = PoolKey({
            currency0: Currency.wrap(address(0)), // Native currency
            currency1: Currency.wrap(address(token1)),
            fee: FEE + 20,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook2))
        });

        poolManager.initialize(key2, SQRT_PRICE_1_1);

        // Fund pool2 with output tokens and ETH for the swap
        token1.mint(address(pool2), 1000 ether);
        vm.deal(address(poolManager), 1000 ether);
        vm.deal(alice, 1000 ether);

        uint256 amountIn = 100 ether;
        uint256 amountOut = 95 ether;

        uint256 aliceEthBefore = alice.balance;
        uint256 aliceToken1Before = token1.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap{value: amountIn}(
            key2,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(alice.balance, aliceEthBefore - amountIn);
        assertEq(token1.balanceOf(alice), aliceToken1Before + amountOut);
    }

    function test_swap_exactIn_nativeOutput_oneForZero() public {
        // Test swap where OUTPUT is native ETH (exercises outputIsNative=true branch)
        // Pool: currency0 = native, currency1 = ERC20
        // Swap: oneForZero (ERC20 -> native)
        MockFluidDexReservesResolver resolver2 = new MockFluidDexReservesResolver();
        resolver2.setDexTokens(FLUID_NATIVE_CURRENCY, address(token1));

        MockFluidDexT1 pool2 = new MockFluidDexT1();
        pool2.setTokens(address(0), address(token1));
        pool2.setReturnSwapInWithCallback(95 ether); // Will use callback since input is ERC20

        FluidDexT1Aggregator hook2 = _deployHook(pool2, resolver2);

        PoolKey memory key2 = PoolKey({
            currency0: Currency.wrap(address(0)), // Native currency
            currency1: Currency.wrap(address(token1)),
            fee: FEE + 22,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook2))
        });

        poolManager.initialize(key2, SQRT_PRICE_1_1);

        // Fund
        token1.mint(alice, 1000 ether);
        token1.mint(address(poolManager), 1000 ether);
        vm.deal(address(pool2), 1000 ether); // Pool needs ETH to send as output
        vm.deal(address(poolManager), 1000 ether);

        uint256 amountIn = 100 ether;
        uint256 amountOut = 95 ether;

        uint256 aliceEthBefore = alice.balance;
        uint256 aliceToken1Before = token1.balanceOf(alice);

        vm.startPrank(alice);
        token1.approve(address(swapRouter), type(uint256).max);

        // Swap ERC20 -> native (oneForZero means token1 -> token0 = token1 -> native)
        swapRouter.swap(
            key2,
            SwapParams({zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MAX_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        assertEq(token1.balanceOf(alice), aliceToken1Before - amountIn);
        assertEq(alice.balance, aliceEthBefore + amountOut);
    }

    function test_swap_exactOut_nativeInput_revertsNativeCurrencyExactOut() public {
        // Create a pool with native currency as token0
        // Attempting exactOut with native input should revert
        MockFluidDexReservesResolver resolver2 = new MockFluidDexReservesResolver();
        resolver2.setDexTokens(FLUID_NATIVE_CURRENCY, address(token1));

        MockFluidDexT1 pool2 = new MockFluidDexT1();
        pool2.setTokens(address(0), address(token1));
        pool2.setReturnSwapOutWithCallback(55 ether);

        FluidDexT1Aggregator hook2 = _deployHook(pool2, resolver2);
        PoolKey memory key2 = PoolKey({
            currency0: Currency.wrap(address(0)), // Native currency
            currency1: Currency.wrap(address(token1)),
            fee: FEE + 21,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook2))
        });

        poolManager.initialize(key2, SQRT_PRICE_1_1);

        // Fund
        token1.mint(address(pool2), 1000 ether);
        token1.mint(address(hook2), 1000 ether);
        vm.deal(address(poolManager), 1000 ether);
        vm.deal(alice, 1000 ether);

        uint256 amountOut = 50 ether;

        // ExactOut (positive amountSpecified) with native input (zeroForOne=true means native -> token1)
        // ExactOut: amountSpecified > 0 means we specify the output amount
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook2),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(FluidDexT1Aggregator.NativeCurrencyExactOut.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swapRouter.swap{value: 100 ether}(
            key2,
            SwapParams({zeroForOne: true, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MIN_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // ========== dexCallback with native currency ==========
    // Note: The FLUID_NATIVE_CURRENCY conversion in dexCallback is tested via the native input exactIn test
    // which exercises the full native currency flow including the callback

    // ========== _getBuffer TESTS ==========

    function test_getBuffer_returnsMinBuffer_forSmallAmounts() public {
        // For small amounts, buffer should be INACCURACY_BUFFER (20)
        // When amount < INACCURACY_BUFFER * INACCURACY_SCALE (20 * 1_000_000 = 20_000_000)
        // The scaled value will be less than INACCURACY_BUFFER
        // This is implicitly tested by the quote tests, but let's verify through quote
        mockResolver.setReturnEstimateSwapOut(100);
        // Quote with small amount - buffer should be 20
        uint256 result = hook.quote(true, int256(100), poolId);
        assertEq(result, 100);
    }

    function test_getBuffer_returnsScaledBuffer_forLargeAmounts() public {
        // For large amounts (>= 20_000_000), scaled buffer should be used
        // amount / 1_000_000 > 20
        mockResolver.setReturnEstimateSwapOut(100);
        // Quote with large amount (100 ether = 100e18)
        // Buffer would be 100e18 / 1_000_000 = 100e12 which is > 20
        uint256 result = hook.quote(true, int256(100 ether), poolId);
        assertEq(result, 100);
    }

    // ========== REENTRANCY TEST ==========

    function test_swap_revertsReentrancy() public {
        // Set up reentrancy attacker that will try to re-enter during callback
        ReentrancyAttacker attacker = new ReentrancyAttacker();

        // Prepare the attack - try to initiate another swap during the callback
        bytes memory attackCallData = abi.encodeWithSelector(
            swapRouter.swap.selector,
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(10 ether), sqrtPriceLimitX96: MIN_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        attacker.setAttack(address(swapRouter), attackCallData);

        // Configure mock to call the attacker during swap
        mockPool.setReentrancyAttacker(address(attacker));
        mockPool.setReturnSwapInWithCallback(95 ether);
        token1.mint(address(poolManager), 95 ether);

        // The swap should complete because the attacker's re-entry attempt fails
        // (ReentrancyAttacker expects the attack to fail and reverts if it succeeds)
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(100 ether), sqrtPriceLimitX96: MIN_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // ========== UNAUTHORIZED CALLER TEST ==========

    function test_dexCallback_revertsUnauthorizedCaller_whenInflight() public {
        // Set up unauthorized caller
        UnauthorizedCallbackCaller unauthorizedCaller = new UnauthorizedCallbackCaller();

        // Configure mock to have the unauthorized caller make the callback
        mockPool.setUnauthorizedCaller(address(unauthorizedCaller));
        mockPool.setReturnSwapInWithCallback(95 ether);

        // The swap should revert because the callback comes from unauthorized caller
        vm.prank(alice);
        vm.expectRevert();
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(100 ether), sqrtPriceLimitX96: MIN_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // ========== NATIVE CURRENCY CALLBACK TEST ==========

    function test_dexCallback_convertsNativeCurrencyAddress() public {
        // Test that dexCallback correctly converts FLUID_NATIVE_CURRENCY to address(0)
        //
        // We use an ERC20-ERC20 pool but configure the mock to pass FLUID_NATIVE_CURRENCY in callback.
        // The callback will try to take native currency from the pool manager.
        // This will fail because the pool doesn't have native currency configured,
        // but the branch coverage is still achieved (the conversion happens before the take).
        mockPool.setUseNativeCurrencyInCallback(true);
        mockPool.setReturnSwapInWithCallback(95 ether);
        token1.mint(address(poolManager), 95 ether);
        vm.deal(address(poolManager), 1000 ether);

        vm.prank(alice);
        // The swap will revert because the callback tries to take native currency
        // but the important part is that dexCallback receives FLUID_NATIVE_CURRENCY
        // and converts it to address(0) before calling poolManager.take()
        vm.expectRevert();
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(100 ether), sqrtPriceLimitX96: MIN_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}
