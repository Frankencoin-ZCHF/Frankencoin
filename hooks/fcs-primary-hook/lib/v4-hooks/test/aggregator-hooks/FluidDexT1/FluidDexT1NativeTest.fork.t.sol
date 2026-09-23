// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockV4FeeAdapter} from "../mocks/MockV4FeeAdapter.sol";
import {SafePoolSwapTest} from "../shared/SafePoolSwapTest.sol";
import {FluidDexT1Aggregator} from "../../../src/aggregator-hooks/implementations/FluidDexT1/FluidDexT1Aggregator.sol";
import {IFluidDexT1} from "../../../src/aggregator-hooks/implementations/FluidDexT1/interfaces/IFluidDexT1.sol";
import {
    IFluidDexReservesResolver
} from "../../../src/aggregator-hooks/implementations/FluidDexT1/interfaces/IFluidDexReservesResolver.sol";
import {
    IFluidDexResolver
} from "../../../src/aggregator-hooks/implementations/FluidDexT1/interfaces/IFluidDexResolver.sol";

/// @title FluidDexT1NativeForkedTest
/// @notice Tests for Fluid DEX T1 with native ETH token pairs
/// @dev Native ETH is always currency0 (address(0) is the lowest address)
contract FluidDexT1NativeForkedTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    // Fluid's native currency representation
    address constant FLUID_NATIVE_CURRENCY = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // Fluid infrastructure addresses (loaded from env vars)
    address fluidLiquidity;
    address fluidDexReservesResolver;
    address fluidDexResolver;

    // Pool configuration
    uint24 constant POOL_FEE = 500; // 0.05%
    int24 constant TICK_SPACING = 10; // Default tick spacing for a 0.05% fee pool
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 1:1 price

    // Price limits for swaps
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    // Loaded from .env
    address fluidPoolAddress;
    address erc20TokenAddress; // The ERC20 token in the pair (not native)
    address poolManagerAddress;

    // Test amounts (in 18 decimals)
    int256 constant SWAP_AMOUNT = 1 ether;
    uint256 constant INITIAL_BALANCE = 100 ether;

    IPoolManager public manager;
    MockV4FeeAdapter public feeAdapter;
    SafePoolSwapTest public swapRouter;
    FluidDexT1Aggregator public hook;
    IFluidDexT1 public fluidPool;
    IFluidDexReservesResolver public fluidReservesResolver;
    IFluidDexResolver public fluidResolver;

    PoolKey public poolKey;
    PoolId public poolId;

    // currency0 = Native ETH (address(0)), currency1 = ERC20 token
    Currency public currency0;
    Currency public currency1;

    address public alice;

    error PoolDoesNotContainNativeToken();

    function setUp() public {
        string memory rpcUrl;
        // Forking requires an RPC URL env var and an optional block number
        try vm.envString("FORK_RPC_URL_1") returns (string memory _rpcUrl) {
            rpcUrl = _rpcUrl;
        } catch {
            console.log("Not forking skipping tests");
            vm.skip(true);
            return;
        }
        uint256 forkBlockNumber = vm.envOr("FORK_BLOCK_NUMBER_1", uint256(0));
        // Load Fluid infrastructure addresses from env vars
        fluidPoolAddress = vm.envAddress("FLUID_DEX_T1_POOL_NATIVE");
        fluidLiquidity = vm.envAddress("FLUID_LIQUIDITY");
        fluidDexReservesResolver = vm.envAddress("FLUID_DEX_T1_RESERVES_RESOLVER");
        fluidDexResolver = vm.envAddress("FLUID_DEX_T1_RESOLVER");
        // Load V4 infrastructure address from env vars
        poolManagerAddress = vm.envAddress("POOL_MANAGER_1");

        if (forkBlockNumber > 0) {
            vm.createSelectFork(rpcUrl, forkBlockNumber);
        } else {
            vm.createSelectFork(rpcUrl);
        }

        // Create alice address that doesn't have code on mainnet
        alice = address(uint160(uint256(keccak256("fluid_test_alice_native_v1"))));

        fluidPool = IFluidDexT1(fluidPoolAddress);
        fluidReservesResolver = IFluidDexReservesResolver(fluidDexReservesResolver);
        fluidResolver = IFluidDexResolver(fluidDexResolver);
        manager = IPoolManager(poolManagerAddress);

        // Dynamically fetch tokens from the pool via resolver (getDexTokens is on IFluidDexResolver)
        (address fluidToken0, address fluidToken1) = fluidResolver.getDexTokens(fluidPoolAddress);

        // Identify which token is native and which is ERC20
        // Native should usually be token1 in fluid
        if (fluidToken1 == FLUID_NATIVE_CURRENCY) {
            erc20TokenAddress = fluidToken0;
        } else if (fluidToken0 == FLUID_NATIVE_CURRENCY) {
            erc20TokenAddress = fluidToken1;
        } else {
            revert PoolDoesNotContainNativeToken();
        }

        currency0 = Currency.wrap(address(0));
        currency1 = Currency.wrap(erc20TokenAddress);

        swapRouter = new SafePoolSwapTest(manager);
        feeAdapter = new MockV4FeeAdapter(manager, address(this));

        _deployHook();

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();

        manager.initialize(poolKey, SQRT_PRICE_1_1);

        // Deal tokens to alice for testing
        vm.deal(alice, INITIAL_BALANCE);
        deal(erc20TokenAddress, alice, INITIAL_BALANCE);

        // Approve swap router for alice (only ERC20 token needs approval)
        // Use forceApprove for non-standard tokens like USDT
        vm.startPrank(alice);
        IERC20(erc20TokenAddress).forceApprove(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _deployHook() internal {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );

        bytes memory constructorArgs = abi.encode(
            address(manager), address(fluidPool), address(fluidReservesResolver), address(fluidResolver), fluidLiquidity
        );
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(FluidDexT1Aggregator).creationCode, constructorArgs);

        hook = new FluidDexT1Aggregator{salt: salt}(
            manager, fluidPool, fluidReservesResolver, fluidResolver, fluidLiquidity
        );
        require(address(hook) == hookAddress, "Hook address mismatch");
    }

    // ========== NATIVE TOKEN SWAP TESTS ==========

    /// @notice Test exact input swap: Native ETH in -> ERC20 out (zeroForOne)
    function test_nativeIn_exactIn() public {
        int256 amountIn = SWAP_AMOUNT;

        // Get quote before swap
        uint256 expectedOut = hook.quote(true, -(amountIn), poolId);
        assertGt(expectedOut, 0, "Quote should return non-zero");

        uint256 ethBefore = alice.balance;
        uint256 ercBefore = IERC20(erc20TokenAddress).balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap{value: uint256(amountIn)}(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -(amountIn), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 ethAfter = alice.balance;
        uint256 ercAfter = IERC20(erc20TokenAddress).balanceOf(alice);

        // ETH should decrease by approximately the input amount (small variance allowed for native handling)
        uint256 ethSpent = ethBefore - ethAfter;
        assertApproxEqRel(ethSpent, uint256(amountIn), 0.001e18, "ETH spent should be close to input amount");

        // Should receive ERC20 tokens matching quote (allow 0.1% variance)
        uint256 ercReceived = ercAfter - ercBefore;
        assertApproxEqRel(ercReceived, expectedOut, 0.001e18, "Received amount should be close to quote");
    }

    /// @notice Test exact input swap: ERC20 in -> Native ETH out (oneForZero)
    function test_nativeOut_exactIn() public {
        int256 amountIn = SWAP_AMOUNT;

        // Get quote before swap
        uint256 expectedOut = hook.quote(false, -(amountIn), poolId);
        assertGt(expectedOut, 0, "Quote should return non-zero");

        uint256 ethBefore = alice.balance;
        uint256 ercBefore = IERC20(erc20TokenAddress).balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -(amountIn), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 ethAfter = alice.balance;
        uint256 ercAfter = IERC20(erc20TokenAddress).balanceOf(alice);

        // ERC20 should decrease by exact input amount
        assertEq(ercBefore - ercAfter, uint256(amountIn), "ERC20 should decrease by exact input amount");

        // Should receive ETH close to quote (allow 0.1% variance for state changes between quote and swap)
        uint256 ethReceived = ethAfter - ethBefore;
        assertApproxEqRel(ethReceived, expectedOut, 0.001e18, "ETH received should be close to quote");
    }

    /// @notice Test exact output swap: Native ETH in -> ERC20 out (zeroForOne) - SHOULD REVERT
    /// @dev Native currency exact output is not supported because we can't know how much ETH to send upfront
    function test_nativeIn_exactOut_reverts() public {
        int256 amountOut = SWAP_AMOUNT;

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(FluidDexT1Aggregator.NativeCurrencyExactOut.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swapRouter.swap{value: uint256(amountOut) * 2}( // Send extra ETH that would be refunded
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: (amountOut), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @notice Test exact output swap: ERC20 in -> Native ETH out (oneForZero)
    function test_nativeOut_exactOut() public {
        int256 amountOut = SWAP_AMOUNT;

        // Get quote for expected input amount
        uint256 expectedIn = hook.quote(false, (amountOut), poolId);

        uint256 ethBefore = alice.balance;
        uint256 ercBefore = IERC20(erc20TokenAddress).balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: (amountOut), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 ethAfter = alice.balance;
        uint256 ercAfter = IERC20(erc20TokenAddress).balanceOf(alice);

        // ETH should increase by approximately the output amount (allow 0.1% variance)
        uint256 ethReceived = ethAfter - ethBefore;
        assertApproxEqRel(ethReceived, uint256(amountOut), 0.001e18, "ETH received should be close to output amount");

        // ERC20 should decrease
        uint256 ercSpent = ercBefore - ercAfter;

        assertApproxEqRel(ercSpent, expectedIn, 0.001e18, "ERC20 spent should be close to quote");
    }

    // ========== ADDITIONAL TESTS ==========

    /// @notice Test that multiple native swaps work correctly
    function test_multipleNativeSwaps() public {
        uint256 amount = 0.5 ether;

        // First swap: ETH -> ERC20 (exact input)
        vm.prank(alice);
        swapRouter.swap{value: amount}(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Second swap: ERC20 -> ETH (exact input)
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(amount), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Third swap: ERC20 -> ETH (exact output) - this direction works
        uint256 smallAmount = amount / 2;
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: int256(smallAmount), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @notice Verify quote function returns reasonable values for native pool
    function test_quote() public {
        int256 amountIn = SWAP_AMOUNT;

        uint256 expectedOut = hook.quote(true, -(amountIn), poolId);

        assertGt(expectedOut, 0, "Quote should return non-zero");
        assertGt(expectedOut, uint256(amountIn) * 70 / 100, "Quote should be within reasonable range");
    }

    /// @notice Test pseudoTotalValueLocked returns non-zero reserves
    /// @dev When resolver returns data, at least one reserve should be non-zero. (0,0) indicates resolver failure.
    function test_pseudoTotalValueLocked() public {
        (uint256 amount0, uint256 amount1) = hook.pseudoTotalValueLocked(poolId);
        assertTrue(amount0 > 0 || amount1 > 0, "At least one reserve should be non-zero");
    }

    receive() external payable {}
}
