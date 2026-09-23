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
import {HookMiner} from "../../../src/utils/HookMiner.sol";
import {SafePoolSwapTest} from "../shared/SafePoolSwapTest.sol";
import {UniswapV3Aggregator} from "../../../src/aggregator-hooks/implementations/UniswapV3/UniswapV3Aggregator.sol";
import {MockUniV3Pool} from "./mocks/MockUniV3Pool.sol";
import {MockUniV3Factory} from "./mocks/MockUniV3Factory.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {Deploy} from "@uniswap/v4-periphery/test/shared/Deploy.sol";

/// @dev Heavy external-integration suite; pinned low to keep CI fast (global default is raised in foundry.toml).
/// forge-config: default.fuzz.runs = 10
contract UniswapV3AggregatorUnitTest is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager public poolManager;
    SafePoolSwapTest public swapRouter;
    MockUniV3Factory public factory;
    MockUniV3Pool public extPool;
    UniswapV3Aggregator public hook;
    IV4Quoter public quoter;

    MockERC20 public token0;
    MockERC20 public token1;

    uint24 constant POOL_FEE = 3000;
    int24 constant TICK_SPACING_A = 60;
    int24 constant TICK_SPACING_B = 200;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant MIN_PRICE = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE = TickMath.MAX_SQRT_PRICE - 1;

    address public alice = makeAddr("alice");
    PoolKey public poolKey;
    PoolId public poolId;

    function setUp() public {
        poolManager =
            IPoolManager(vm.deployCode("foundry-out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        swapRouter = new SafePoolSwapTest(poolManager);

        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        if (address(token0) > address(token1)) (token0, token1) = (token1, token0);

        factory = new MockUniV3Factory();
        extPool = new MockUniV3Pool(address(token0), address(token1), POOL_FEE, TICK_SPACING_A);
        factory.setPool(address(token0), address(token1), POOL_FEE, address(extPool));

        hook = _deployHook();

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING_A,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();

        poolManager.initialize(poolKey, SQRT_PRICE_1_1);

        quoter = Deploy.v4Quoter(address(poolManager), hex"00");

        token0.mint(alice, 1000 ether);
        token1.mint(alice, 1000 ether);
        token0.mint(address(poolManager), 1000 ether);
        token1.mint(address(poolManager), 1000 ether);

        token0.mint(address(extPool), 1_000_000 ether);
        token1.mint(address(extPool), 1_000_000 ether);

        vm.startPrank(alice);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _deployHook() internal returns (UniswapV3Aggregator) {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );
        bytes memory constructorArgs = abi.encode(poolManager, address(factory), "UniswapV3Aggregator v1.0");
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(UniswapV3Aggregator).creationCode, constructorArgs);
        return new UniswapV3Aggregator{salt: salt}(poolManager, address(factory), "UniswapV3Aggregator v1.0");
    }

    function test_quote_exactIn_matches_math() public {
        uint256 q = hook.quote(true, -int256(100 ether), poolId);
        assertEq(q, 99 ether);
    }

    function test_quote_exactIn_matches_math_oneForZero() public {
        uint256 q = hook.quote(false, -int256(100 ether), poolId);
        assertEq(q, 99 ether);
    }

    function test_quote_exactOut_matches_math() public {
        uint256 q = hook.quote(true, int256(99 ether), poolId);
        uint256 expected = (uint256(99 ether) * 100 + 98) / 99;
        assertEq(q, expected);
    }

    function test_quote_exactOut_matches_math_oneForZero() public {
        uint256 q = hook.quote(false, int256(99 ether), poolId);
        uint256 expected = (uint256(99 ether) * 100 + 98) / 99;
        assertEq(q, expected);
    }

    function test_swapExactInput_zeroForOne() public {
        uint256 amountIn = 100 ether;
        uint256 expectedOut = hook.quote(true, -int256(amountIn), poolId);

        uint256 t0Before = token0.balanceOf(alice);
        uint256 t1Before = token1.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(t0Before - token0.balanceOf(alice), amountIn);
        assertEq(token1.balanceOf(alice) - t1Before, expectedOut);
    }

    function test_swapExactInput_oneForZero() public {
        uint256 amountIn = 100 ether;
        uint256 expectedOut = hook.quote(false, -int256(amountIn), poolId);

        uint256 t0Before = token0.balanceOf(alice);
        uint256 t1Before = token1.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MAX_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(t1Before - token1.balanceOf(alice), amountIn);
        assertEq(token0.balanceOf(alice) - t0Before, expectedOut);
    }

    function test_swapExactOutput_zeroForOne() public {
        uint256 amountOut = 99 ether;
        uint256 expectedIn = hook.quote(true, int256(amountOut), poolId);

        uint256 t0Before = token0.balanceOf(alice);
        uint256 t1Before = token1.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MIN_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(token1.balanceOf(alice) - t1Before, amountOut);
        assertEq(t0Before - token0.balanceOf(alice), expectedIn);
    }

    function test_swapExactOutput_oneForZero() public {
        uint256 amountOut = 99 ether;
        uint256 expectedIn = hook.quote(false, int256(amountOut), poolId);

        uint256 t0Before = token0.balanceOf(alice);
        uint256 t1Before = token1.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MAX_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(token0.balanceOf(alice) - t0Before, amountOut);
        assertEq(t1Before - token1.balanceOf(alice), expectedIn);
    }

    function test_swapExactOutput_underfill_reverts() public {
        uint256 amountOut = 99 ether;
        extPool.setIsUnderfill(true);

        vm.prank(alice);
        vm.expectRevert();
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MAX_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function testFuzz_initializedRegistry(address rawTokenA, address rawTokenB) public {
        vm.assume(rawTokenA != rawTokenB);
        vm.assume(rawTokenA != address(0) && rawTokenB != address(0));
        vm.assume(rawTokenA != address(token0) && rawTokenA != address(token1));
        vm.assume(rawTokenB != address(token0) && rawTokenB != address(token1));

        (address sorted0, address sorted1) = rawTokenA < rawTokenB ? (rawTokenA, rawTokenB) : (rawTokenB, rawTokenA);

        // setUp initialized one pool
        assertEq(hook.initializedLength(), 1);
        PoolKey memory stored = hook.initialized(0);
        assertEq(Currency.unwrap(stored.currency0), address(token0));
        assertEq(Currency.unwrap(stored.currency1), address(token1));
        assertEq(stored.fee, POOL_FEE);
        assertEq(stored.tickSpacing, TICK_SPACING_A);
        assertEq(address(stored.hooks), address(hook));

        // A second external pool registers as a second entry
        MockUniV3Pool extPool2 = new MockUniV3Pool(sorted0, sorted1, POOL_FEE, TICK_SPACING_A);
        factory.setPool(sorted0, sorted1, POOL_FEE, address(extPool2));

        PoolKey memory key2 = PoolKey({
            currency0: Currency.wrap(sorted0),
            currency1: Currency.wrap(sorted1),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING_A,
            hooks: IHooks(address(hook))
        });
        poolManager.initialize(key2, SQRT_PRICE_1_1);

        assertEq(hook.initializedLength(), 2);
        stored = hook.initialized(1);
        assertEq(Currency.unwrap(stored.currency0), sorted0);
        assertEq(Currency.unwrap(stored.currency1), sorted1);
        assertEq(stored.fee, POOL_FEE);
        assertEq(stored.tickSpacing, TICK_SPACING_A);
        assertEq(address(stored.hooks), address(hook));
    }

    function test_secondInitialize_same_external_pool_reverts() public {
        PoolKey memory key2 = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING_B,
            hooks: IHooks(address(hook))
        });

        // PoolManager wraps hook revert as WrappedError
        vm.expectRevert();
        poolManager.initialize(key2, SQRT_PRICE_1_1);
    }

    function test_pseudoTotalValueLocked_nonZero() public view {
        (uint256 a0, uint256 a1) = hook.pseudoTotalValueLocked(poolId);
        assertTrue(a0 > 0 || a1 > 0);
    }

    // ── V4Quoter tests ────────────────────────────────────────────────────────

    function test_v4Quoter_exactInput_zeroForOne() public {
        uint128 amtIn = 100 ether;
        uint256 hookQuote = hook.quote(true, -int256(uint256(amtIn)), poolId);

        (uint256 quotedOut,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({poolKey: poolKey, zeroForOne: true, exactAmount: amtIn, hookData: ""})
        );

        assertEq(quotedOut, hookQuote);
    }

    function test_v4Quoter_exactInput_oneForZero() public {
        uint128 amtIn = 100 ether;
        uint256 hookQuote = hook.quote(false, -int256(uint256(amtIn)), poolId);

        (uint256 quotedOut,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({poolKey: poolKey, zeroForOne: false, exactAmount: amtIn, hookData: ""})
        );

        assertEq(quotedOut, hookQuote);
    }

    function test_v4Quoter_exactOutput_zeroForOne() public {
        uint128 amtOut = 99 ether;
        uint256 hookQuote = hook.quote(true, int256(uint256(amtOut)), poolId);

        (uint256 quotedIn,) = quoter.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams({poolKey: poolKey, zeroForOne: true, exactAmount: amtOut, hookData: ""})
        );

        assertEq(quotedIn, hookQuote);
    }

    function test_v4Quoter_exactOutput_oneForZero() public {
        uint128 amtOut = 99 ether;
        uint256 hookQuote = hook.quote(false, int256(uint256(amtOut)), poolId);

        (uint256 quotedIn,) = quoter.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams({poolKey: poolKey, zeroForOne: false, exactAmount: amtOut, hookData: ""})
        );

        assertEq(quotedIn, hookQuote);
    }

    receive() external payable {}
}
