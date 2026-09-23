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
import {MockCurveStableSwap} from "./mocks/MockCurveStableSwap.sol";
import {MockMetaRegistry} from "./mocks/MockMetaRegistry.sol";
import {MockV4FeeAdapter} from "../mocks/MockV4FeeAdapter.sol";
import {StableSwapAggregator} from "../../../src/aggregator-hooks/implementations/StableSwap/StableSwapAggregator.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

contract StableSwapAggregatorUnitTest is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager public poolManager;
    MockV4FeeAdapter public feeAdapter;
    SafePoolSwapTest public swapRouter;
    MockCurveStableSwap public mockPool;
    MockMetaRegistry public mockMetaRegistry;
    StableSwapAggregator public hook;
    MockERC20 public token0;
    MockERC20 public token1;

    // Pool configuration
    uint24 constant FEE = 3000; // 0.3% fee
    int24 constant TICK_SPACING = 60; // Default tick spacing for a 0.3% fee pool
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 1:1 price

    uint160 constant MIN_PRICE = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE = TickMath.MAX_SQRT_PRICE - 1;

    address constant CURVE_NATIVE_CURRENCY = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    address public alice = makeAddr("alice");
    PoolKey public poolKey;
    PoolId public poolId;

    function setUp() public {
        poolManager =
            IPoolManager(vm.deployCode("foundry-out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        swapRouter = new SafePoolSwapTest(poolManager);
        feeAdapter = new MockV4FeeAdapter(poolManager, address(this));

        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        if (address(token0) > address(token1)) (token0, token1) = (token1, token0);

        // Create mock pool with tokens
        address[] memory coins = new address[](2);
        coins[0] = address(token0);
        coins[1] = address(token1);
        mockPool = new MockCurveStableSwap(coins);

        // Create mock meta registry (defaults to false for all pools)
        mockMetaRegistry = new MockMetaRegistry();
        mockMetaRegistry.setIsRegistered(address(mockPool), true);

        // Deploy hook with valid address
        hook = _deployHook(mockPool, mockMetaRegistry);

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
        token0.mint(alice, 1000 ether);
        token1.mint(alice, 1000 ether);
        token0.mint(address(poolManager), 1000 ether);
        token1.mint(address(poolManager), 1000 ether);
        token0.mint(address(hook), 1000 ether);
        token1.mint(address(hook), 1000 ether);

        // Mint tokens to mock pool so it can transfer output tokens
        token0.mint(address(mockPool), 1000 ether);
        token1.mint(address(mockPool), 1000 ether);
        vm.startPrank(alice);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _deployHook(MockCurveStableSwap _mockPool, MockMetaRegistry _mockMetaRegistry)
        internal
        returns (StableSwapAggregator)
    {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );
        bytes memory constructorArgs = abi.encode(poolManager, _mockPool, _mockMetaRegistry);
        (, bytes32 salt) =
            HookMiner.find(address(this), flags, type(StableSwapAggregator).creationCode, constructorArgs);
        StableSwapAggregator newHook = new StableSwapAggregator{salt: salt}(poolManager, _mockPool, _mockMetaRegistry);
        return newHook;
    }

    // ========== CONSTRUCTOR ==========

    function test_constructor_setsPool() public view {
        assertEq(address(hook.pool()), address(mockPool));
    }

    // ========== quote ==========

    function test_quote_revertsExactOutputNotSupported() public {
        vm.expectRevert(StableSwapAggregator.ExactOutputNotSupported.selector);
        hook.quote(true, int256(100 ether), poolId);
    }

    function test_quote_exactIn_zeroToOne() public {
        mockPool.setReturnGetDy(12345);
        uint256 result = hook.quote(true, -int256(100 ether), poolId);
        assertEq(result, 12345);
    }

    function test_quote_exactIn_oneToZero() public {
        mockPool.setReturnGetDy(54321);
        uint256 result = hook.quote(false, -int256(100 ether), poolId);
        assertEq(result, 54321);
    }

    // ========== pseudoTotalValueLocked ==========

    function test_pseudoTotalValueLocked_returnsBalances() public {
        mockPool.setBalance(0, 1000 ether);
        mockPool.setBalance(1, 2000 ether);
        (uint256 a0, uint256 a1) = hook.pseudoTotalValueLocked(poolId);
        assertEq(a0, 1000 ether);
        assertEq(a1, 2000 ether);
    }

    function test_pseudoTotalValueLocked_revertsInvalidPoolId() public {
        // Use a poolId that was never initialized (no token info in mapping)
        PoolKey memory uninitializedKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE + 999,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        PoolId uninitializedPoolId = uninitializedKey.toId();

        vm.expectRevert(StableSwapAggregator.InvalidPoolId.selector);
        hook.pseudoTotalValueLocked(uninitializedPoolId);
    }

    // ========== _beforeInitialize ==========

    function test_beforeInitialize_revertsTokensNotInPool() public {
        // Create mock pool without our tokens
        address[] memory wrongCoins = new address[](2);
        wrongCoins[0] = address(0xdead);
        wrongCoins[1] = address(0xbeef);
        MockCurveStableSwap wrongPool = new MockCurveStableSwap(wrongCoins);
        mockMetaRegistry.setIsRegistered(address(wrongPool), true);

        StableSwapAggregator hook2 = _deployHook(wrongPool, mockMetaRegistry);

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
                abi.encodeWithSelector(
                    StableSwapAggregator.TokensNotInPool.selector,
                    Currency.unwrap(key2.currency0),
                    Currency.unwrap(key2.currency1)
                ),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        poolManager.initialize(key2, SQRT_PRICE_1_1);
    }

    function test_beforeInitialize_revertsToken0NotInPool() public {
        // Create mock pool with only token1 (token0 is missing)
        address[] memory partialCoins = new address[](2);
        partialCoins[0] = address(0xdead); // wrong token0
        partialCoins[1] = address(token1); // correct token1
        MockCurveStableSwap partialPool = new MockCurveStableSwap(partialCoins);
        mockMetaRegistry.setIsRegistered(address(partialPool), true);

        StableSwapAggregator hook2 = _deployHook(partialPool, mockMetaRegistry);

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
                abi.encodeWithSelector(StableSwapAggregator.TokenNotInPool.selector, address(token0)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        poolManager.initialize(key2, SQRT_PRICE_1_1);
    }

    function test_beforeInitialize_revertsToken1NotInPool() public {
        // Create mock pool with only token0 (token1 is missing)
        address[] memory partialCoins = new address[](2);
        partialCoins[0] = address(token0); // correct token0
        partialCoins[1] = address(0xbeef); // wrong token1
        MockCurveStableSwap partialPool = new MockCurveStableSwap(partialCoins);
        mockMetaRegistry.setIsRegistered(address(partialPool), true);

        StableSwapAggregator hook2 = _deployHook(partialPool, mockMetaRegistry);

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
                abi.encodeWithSelector(StableSwapAggregator.TokenNotInPool.selector, address(token1)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        poolManager.initialize(key2, SQRT_PRICE_1_1);
    }

    function test_beforeInitialize_revertsPoolNotRegistered() public {
        // Create a meta registry that does not have the pool registered
        MockMetaRegistry unregisteredRegistry = new MockMetaRegistry();
        // Do NOT call setIsRegistered - pool will not be registered

        StableSwapAggregator hook2 = _deployHook(mockPool, unregisteredRegistry);

        PoolKey memory key2 = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE + 5,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook2))
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook2),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(StableSwapAggregator.PoolNotRegistered.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        poolManager.initialize(key2, SQRT_PRICE_1_1);
    }

    function test_beforeInitialize_revertsPoolIsMetaPool() public {
        // Create a meta registry that reports the pool as a meta pool
        MockMetaRegistry metaPoolRegistry = new MockMetaRegistry();
        metaPoolRegistry.setIsRegistered(address(mockPool), true);
        metaPoolRegistry.setIsMeta(address(mockPool), true);

        StableSwapAggregator hook2 = _deployHook(mockPool, metaPoolRegistry);

        PoolKey memory key2 = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE + 4,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook2))
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook2),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(StableSwapAggregator.PoolIsMetaPool.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        poolManager.initialize(key2, SQRT_PRICE_1_1);
    }

    function test_beforeInitialize_setsTokenIndices() public view {
        (int128 idx0, int128 idx1) = hook.poolIdToTokenInfo(poolId);
        assertEq(idx0, 0);
        assertEq(idx1, 1);
    }

    // ========== SWAP (via _conductSwap) ==========

    function test_swap_exactIn_zeroForOne() public {
        uint256 amountIn = 100 ether;
        uint256 amountOut = 95 ether;
        mockPool.setReturnExchange(amountOut);
        token1.mint(address(hook), amountOut);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(token0.balanceOf(alice), 1000 ether - amountIn);
        assertEq(token1.balanceOf(alice), 1000 ether + amountOut);
    }

    function test_swap_exactIn_oneForZero() public {
        uint256 amountIn = 100 ether;
        uint256 amountOut = 95 ether;
        mockPool.setReturnExchange(amountOut);
        token0.mint(address(hook), amountOut);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MAX_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(token1.balanceOf(alice), 1000 ether - amountIn);
        assertEq(token0.balanceOf(alice), 1000 ether + amountOut);
    }

    function test_swap_exactIn_revertsExchangeFailed() public {
        mockPool.setRevertExchange(true);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(StableSwapAggregator.ExchangeFailed.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(100 ether), sqrtPriceLimitX96: MIN_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_swap_exactOut_reverts() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(StableSwapAggregator.ExactOutputNotSupported.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(50 ether), sqrtPriceLimitX96: MIN_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // ========== NATIVE INPUT SWAP TESTS ==========

    /// @notice Test exact input swap with native ETH input: ETH -> ERC20 (zeroForOne)
    function test_swap_exactIn_nativeInput_zeroForOne() public {
        // Create mock pool with native (Curve uses 0xEee) as coin0 and token1 as coin1
        address[] memory coins = new address[](2);
        coins[0] = CURVE_NATIVE_CURRENCY;
        coins[1] = address(token1);
        MockCurveStableSwap nativeMockPool = new MockCurveStableSwap(coins);
        mockMetaRegistry.setIsRegistered(address(nativeMockPool), true);

        StableSwapAggregator nativeHook = _deployHook(nativeMockPool, mockMetaRegistry);

        PoolKey memory nativePoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE + 100,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(nativeHook))
        });

        poolManager.initialize(nativePoolKey, SQRT_PRICE_1_1);

        uint256 amountIn = 100 ether;
        uint256 amountOut = 95 ether;
        nativeMockPool.setReturnExchange(amountOut);
        nativeMockPool.setReturnGetDy(amountOut);
        token1.mint(address(nativeMockPool), amountOut);

        vm.deal(alice, amountIn);
        vm.deal(address(poolManager), amountIn);
        vm.deal(address(nativeHook), amountIn);

        uint256 aliceEthBefore = alice.balance;
        uint256 aliceToken1Before = token1.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap{value: amountIn}(
            nativePoolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(aliceEthBefore - alice.balance, amountIn, "Alice should spend exact ETH");
        assertEq(token1.balanceOf(alice) - aliceToken1Before, amountOut, "Alice should receive token1");
    }

    /// @notice Test exact input swap with native ETH output: ERC20 -> ETH (oneForZero)
    function test_swap_exactIn_nativeOutput_oneForZero() public {
        // Create mock pool with native (Curve uses 0xEee) as coin0 and token1 as coin1
        address[] memory coins = new address[](2);
        coins[0] = CURVE_NATIVE_CURRENCY;
        coins[1] = address(token1);
        MockCurveStableSwap nativeMockPool = new MockCurveStableSwap(coins);
        mockMetaRegistry.setIsRegistered(address(nativeMockPool), true);

        StableSwapAggregator nativeHook = _deployHook(nativeMockPool, mockMetaRegistry);

        PoolKey memory nativePoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE + 101,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(nativeHook))
        });

        poolManager.initialize(nativePoolKey, SQRT_PRICE_1_1);

        uint256 amountIn = 100 ether;
        uint256 amountOut = 95 ether;
        nativeMockPool.setReturnExchange(amountOut);
        nativeMockPool.setReturnGetDy(amountOut);

        // Mock pool needs ETH to send as native output
        vm.deal(address(nativeMockPool), amountOut);
        token1.mint(address(poolManager), amountIn);
        token1.mint(address(nativeHook), amountIn);

        uint256 aliceEthBefore = alice.balance;
        uint256 aliceToken1Before = token1.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            nativePoolKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MAX_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(aliceToken1Before - token1.balanceOf(alice), amountIn, "Alice should spend exact token1");
        assertEq(alice.balance - aliceEthBefore, amountOut, "Alice should receive native ETH");
    }
}
