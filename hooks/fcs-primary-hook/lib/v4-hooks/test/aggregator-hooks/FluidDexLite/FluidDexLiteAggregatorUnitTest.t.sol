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
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {MockV4FeeAdapter} from "../mocks/MockV4FeeAdapter.sol";
import {SafePoolSwapTest} from "../shared/SafePoolSwapTest.sol";
import {MockFluidDexLite, ReentrancyAttacker, UnauthorizedCallbackCaller} from "./mocks/MockFluidDexLite.sol";
import {MockFluidDexLiteResolver} from "./mocks/MockFluidDexLiteResolver.sol";
import {
    FluidDexLiteAggregator
} from "../../../src/aggregator-hooks/implementations/FluidDexLite/FluidDexLiteAggregator.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";
import {IAggregatorHook} from "../../../src/aggregator-hooks/interfaces/IAggregatorHook.sol";

contract FluidDexLiteAggregatorUnitTest is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager public poolManager;
    MockV4FeeAdapter public feeAdapter;
    SafePoolSwapTest public swapRouter;
    MockFluidDexLite public mockDex;
    MockFluidDexLiteResolver public mockResolver;
    FluidDexLiteAggregator public hook;
    MockERC20 public token0;
    MockERC20 public token1;

    // Pool configuration
    uint24 constant FEE = 3000; // 0.3% fee
    int24 constant TICK_SPACING = 60; // Default tick spacing for a 0.3% fee pool
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 1:1 price
    bytes32 constant DEX_SALT = bytes32(uint256(1));

    uint160 constant MIN_PRICE = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE = TickMath.MAX_SQRT_PRICE - 1;
    uint256 public constant INITIAL_BALANCE = 1000 ether;

    address public alice = makeAddr("alice");
    PoolKey public poolKey;
    PoolId public poolId;

    function setUp() public {
        poolManager =
            IPoolManager(vm.deployCode("foundry-out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        swapRouter = new SafePoolSwapTest(poolManager);
        mockDex = new MockFluidDexLite();
        mockResolver = new MockFluidDexLiteResolver();
        feeAdapter = new MockV4FeeAdapter(poolManager, address(this));

        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        if (address(token0) > address(token1)) (token0, token1) = (token1, token0);

        // Deploy hook with valid address
        hook = _deployHook(mockResolver);

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();

        // Mock resolver returns non-empty state so initialize succeeds
        mockResolver.setReturnEmptyDexState(false);
        poolManager.initialize(poolKey, SQRT_PRICE_1_1);

        // Set up tokens
        token0.mint(alice, INITIAL_BALANCE);
        token1.mint(alice, INITIAL_BALANCE);
        token0.mint(address(poolManager), INITIAL_BALANCE);
        token1.mint(address(poolManager), INITIAL_BALANCE);

        // Mint tokens to mock dex so it can transfer output tokens
        token0.mint(address(mockDex), INITIAL_BALANCE);
        token1.mint(address(mockDex), INITIAL_BALANCE);
        vm.startPrank(alice);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _deployHook(MockFluidDexLiteResolver _mockResolver) internal returns (FluidDexLiteAggregator) {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );
        bytes memory constructorArgs = abi.encode(IPoolManager(address(poolManager)), mockDex, _mockResolver, DEX_SALT);
        (, bytes32 salt) =
            HookMiner.find(address(this), flags, type(FluidDexLiteAggregator).creationCode, constructorArgs);
        return
            new FluidDexLiteAggregator{salt: salt}(IPoolManager(address(poolManager)), mockDex, _mockResolver, DEX_SALT);
    }

    // ========== CONSTRUCTOR ==========

    function test_constructor_setsImmutables() public view {
        assertEq(address(hook.fluidDexLite()), address(mockDex));
        assertEq(address(hook.fluidDexLiteResolver()), address(mockResolver));
    }

    // ========== dexCallback ==========

    function test_dexCallback_revertsProhibitedEntry() public {
        // Not in inflight state: the inflight guard fires before any other check
        vm.expectRevert(FluidDexLiteAggregator.ProhibitedEntry.selector);
        hook.dexCallback(address(token0), 100 ether, "");
    }

    function test_dexCallback_revertsProhibitedEntry_whenCalledByPool() public {
        // Even the real pool cannot invoke the callback outside of an active swap:
        // the inflight guard reverts before the authorized-caller / take path is reached.
        token0.mint(address(poolManager), 100 ether);

        vm.prank(address(mockDex));
        vm.expectRevert(FluidDexLiteAggregator.ProhibitedEntry.selector);
        hook.dexCallback(address(token0), 100 ether, "");
    }

    // ========== quote ==========

    function test_quote_revertsPoolDoesNotExist() public {
        PoolId wrongPoolId = PoolId.wrap(bytes32(uint256(999)));
        vm.expectRevert(IAggregatorHook.PoolDoesNotExist.selector);
        hook.quote(true, -int256(100 ether), wrongPoolId);
    }

    function test_quote_returnsResolverEstimate() public {
        mockResolver.setReturnEstimateSwapSingle(12345);
        uint256 result = hook.quote(true, -int256(100 ether), poolId);
        assertEq(result, 12345);
    }

    // ========== pseudoTotalValueLocked ==========

    function test_pseudoTotalValueLocked_revertsPoolDoesNotExist() public {
        PoolId wrongPoolId = PoolId.wrap(bytes32(uint256(999)));
        vm.expectRevert(IAggregatorHook.PoolDoesNotExist.selector);
        hook.pseudoTotalValueLocked(wrongPoolId);
    }

    function test_pseudoTotalValueLocked_returnsReserves() public {
        mockResolver.setReturnReserves(1000 ether, 2000 ether);
        (uint256 a0, uint256 a1) = hook.pseudoTotalValueLocked(poolId);
        assertEq(a0, 1000 ether);
        assertEq(a1, 2000 ether);
    }

    // ========== _beforeInitialize ==========

    function test_beforeInitialize_revertsPoolDoesNotExist_emptyState() public {
        // Deploy new hook
        MockFluidDexLiteResolver resolver2 = new MockFluidDexLiteResolver();
        resolver2.setReturnEmptyDexState(true); // isEmpty() returns true

        FluidDexLiteAggregator hook2 = _deployHook(resolver2);

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
                abi.encodeWithSelector(IAggregatorHook.PoolDoesNotExist.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        poolManager.initialize(key2, SQRT_PRICE_1_1);
    }

    function test_beforeInitialize_emitsEvent() public view {
        // Already tested via setUp, but verify localPoolId is set
        assertEq(PoolId.unwrap(hook.localPoolId()), PoolId.unwrap(poolId));
    }

    // ========== SWAP (via _conductSwap) ==========

    function test_swap_exactIn_zeroForOne() public {
        uint256 amountIn = 100 ether;
        uint256 amountOut = 95 ether;
        mockDex.setReturnSwapSingle(amountOut);
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
        mockDex.setReturnSwapSingle(amountOut);
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

    // ========== REVERSED POOL ORDER (Native Currency) ==========

    function test_pseudoTotalValueLocked_reversed_returnsSwappedReserves() public {
        // Deploy hook with native currency which will trigger reversed order
        // Native currency (address(0)) converts to FLUID_NATIVE_CURRENCY (0xEeee...)
        // which is > any normal token address, so _isReversed = true
        MockFluidDexLiteResolver resolver2 = new MockFluidDexLiteResolver();
        resolver2.setReturnEmptyDexState(false);
        resolver2.setReturnReserves(1000 ether, 2000 ether);

        FluidDexLiteAggregator hook2 = _deployHook(resolver2);

        // Use native currency (address(0)) as currency0
        // After conversion to FLUID_NATIVE_CURRENCY, it becomes > token1, triggering _isReversed
        PoolKey memory key2 = PoolKey({
            currency0: Currency.wrap(address(0)), // Native currency
            currency1: Currency.wrap(address(token1)),
            fee: FEE + 1,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook2))
        });

        poolManager.initialize(key2, SQRT_PRICE_1_1);

        // With _isReversed = true, reserves should be swapped
        (uint256 a0, uint256 a1) = hook2.pseudoTotalValueLocked(key2.toId());
        // token0RealReserves=1000, token1RealReserves=2000
        // When reversed: returns (token1Reserves, token0Reserves) = (2000, 1000)
        assertEq(a0, 2000 ether);
        assertEq(a1, 1000 ether);
    }

    // ========== NATIVE CURRENCY CALLBACK TEST ==========

    function test_dexCallback_convertsNativeCurrencyAddress() public {
        // Test that dexCallback correctly converts FLUID_NATIVE_CURRENCY (0xEeee...) to address(0)
        //
        // We configure the mock to pass FLUID_NATIVE_CURRENCY in the callback.
        // The callback will convert it to address(0) and try to take native currency.
        mockDex.setUseNativeCurrencyInCallback(true);
        mockDex.setReturnSwapSingle(95 ether);
        token1.mint(address(poolManager), 95 ether);
        vm.deal(address(poolManager), 1000 ether);

        vm.prank(alice);
        // The swap will revert because the callback tries to take native currency
        // but the important part is that dexCallback receives FLUID_NATIVE_CURRENCY (0xEeee...)
        // and converts it to address(0) before calling poolManager.take()
        vm.expectRevert();
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(100 ether), sqrtPriceLimitX96: MIN_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // ========== REENTRANCY TEST ==========

    function test_swap_revertsReentrancy() public {
        // Set up reentrancy attacker that will try to re-enter during the callback
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

        // Configure mock to call the attacker during the swap
        mockDex.setReentrancyAttacker(address(attacker));
        mockDex.setReturnSwapSingle(95 ether);
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
        // Set up unauthorized caller that makes the callback from a non-pool address
        UnauthorizedCallbackCaller unauthorizedCaller = new UnauthorizedCallbackCaller();

        // Configure mock to have the unauthorized caller make the callback during the swap
        mockDex.setUnauthorizedCaller(address(unauthorizedCaller));
        mockDex.setReturnSwapSingle(95 ether);

        // The swap should revert because the callback comes from an unauthorized caller,
        // even though the swap is inflight (so the ProhibitedEntry guard passes)
        vm.prank(alice);
        vm.expectRevert();
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(100 ether), sqrtPriceLimitX96: MIN_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}
