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
import {SafePoolSwapTest} from "../shared/SafePoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";
import {MockTIP20} from "./mocks/MockTIP20.sol";
import {
    TempoExchangeAggregator
} from "../../../src/aggregator-hooks/implementations/TempoExchange/TempoExchangeAggregator.sol";
import {
    ITempoExchange
} from "../../../src/aggregator-hooks/implementations/TempoExchange/interfaces/ITempoExchange.sol";
import {MockTempoExchangeWithDiscrepancy} from "./mocks/MockTempoExchangeWithDiscrepancy.sol";

/// @title TempoExchangeExactOutBufferTest
/// @notice Tests for the exact-out buffer logic that handles per-tick vs per-order rounding discrepancies
/// @dev Heavy external-integration suite; pinned low to keep CI fast (global default is raised in foundry.toml).
/// forge-config: default.fuzz.runs = 10
contract TempoExchangeExactOutBufferTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    uint24 constant POOL_FEE = 500;
    int24 constant TICK_SPACING = 10;
    uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
    uint8 constant DECIMALS = 6;
    uint256 constant SWAP_AMOUNT = 1000 * 10 ** DECIMALS;
    uint256 constant INITIAL_BALANCE = 1_000_000 * 10 ** DECIMALS;

    IPoolManager public manager;
    SafePoolSwapTest public swapRouter;
    TempoExchangeAggregator public hook;
    MockTempoExchangeWithDiscrepancy public tempoExchange;

    MockTIP20 public alphaUSD;
    MockTIP20 public betaUSD;

    PoolKey public poolKey;
    PoolId public poolId;
    Currency public currency0;
    Currency public currency1;

    address public alice = makeAddr("alice");

    function setUp() public {
        alphaUSD = new MockTIP20("AlphaUSD", "aUSD", DECIMALS, address(0));
        betaUSD = new MockTIP20("BetaUSD", "bUSD", DECIMALS, address(alphaUSD));

        if (address(alphaUSD) > address(betaUSD)) {
            (alphaUSD, betaUSD) = (betaUSD, alphaUSD);
            alphaUSD.setQuoteToken(address(betaUSD));
            betaUSD.setQuoteToken(address(0));
        }

        currency0 = Currency.wrap(address(alphaUSD));
        currency1 = Currency.wrap(address(betaUSD));

        // Deploy mock with zero discrepancy initially
        tempoExchange = new MockTempoExchangeWithDiscrepancy(0);
        tempoExchange.addSupportedPair(address(alphaUSD), address(betaUSD));

        alphaUSD.mint(address(tempoExchange), INITIAL_BALANCE * 10);
        betaUSD.mint(address(tempoExchange), INITIAL_BALANCE * 10);

        manager = IPoolManager(deployCode("foundry-out/PoolManager.sol/PoolManager.json", abi.encode(address(0))));

        alphaUSD.mint(address(manager), INITIAL_BALANCE * 10);
        betaUSD.mint(address(manager), INITIAL_BALANCE * 10);

        swapRouter = new SafePoolSwapTest(manager);

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

        alphaUSD.mint(alice, INITIAL_BALANCE);
        betaUSD.mint(alice, INITIAL_BALANCE);

        vm.startPrank(alice);
        alphaUSD.approve(address(swapRouter), type(uint256).max);
        betaUSD.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _deployHook() internal {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );

        bytes memory constructorArgs = abi.encode(address(manager), address(tempoExchange));
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(TempoExchangeAggregator).creationCode, constructorArgs);

        hook = new TempoExchangeAggregator{salt: salt}(manager, ITempoExchange(address(tempoExchange)));
        require(address(hook) == hookAddress, "Hook address mismatch");
    }

    // ========== BUFFER LOGIC TESTS ==========

    /// @notice Exact-out swap succeeds with small discrepancy (within buffer)
    function test_exactOutWithSmallDiscrepancy_zeroForOne() public {
        // Set a small discrepancy: execution charges 5 more units than quote
        tempoExchange.setDiscrepancy(5);

        uint256 amountOut = SWAP_AMOUNT;
        uint256 token0Before = alphaUSD.balanceOf(alice);
        uint256 token1Before = betaUSD.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 token1Received = betaUSD.balanceOf(alice) - token1Before;
        assertEq(token1Received, amountOut, "Should receive exact output amount");

        uint256 token0Spent = token0Before - alphaUSD.balanceOf(alice);
        // Spent should reflect the actual execution cost (quoted + discrepancy), not just the quote
        assertGt(token0Spent, 0, "Should spend some input tokens");
    }

    /// @notice Exact-out swap succeeds with small discrepancy (one to zero direction)
    function test_exactOutWithSmallDiscrepancy_oneForZero() public {
        tempoExchange.setDiscrepancy(5);

        uint256 amountOut = SWAP_AMOUNT;
        uint256 token0Before = alphaUSD.balanceOf(alice);
        uint256 token1Before = betaUSD.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 token0Received = alphaUSD.balanceOf(alice) - token0Before;
        assertEq(token0Received, amountOut, "Should receive exact output amount");

        uint256 token1Spent = token1Before - betaUSD.balanceOf(alice);
        assertGt(token1Spent, 0, "Should spend some input tokens");
    }

    /// @notice Exact-out swap succeeds when discrepancy equals INACCURACY_BUFFER
    function test_exactOutWithDiscrepancyAtBufferLimit() public {
        // INACCURACY_BUFFER = 20, so set discrepancy to exactly 20
        tempoExchange.setDiscrepancy(20);

        uint256 amountOut = SWAP_AMOUNT;

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // The fact we got here without revert means the buffer absorbed the discrepancy
    }

    /// @notice Exact-out swap reverts when discrepancy exceeds the buffer
    function test_exactOutRevertsWhenDiscrepancyExceedsBuffer() public {
        uint256 amountOut = SWAP_AMOUNT;

        // Calculate the buffer for this swap's quoted input
        uint128 quotedIn =
            tempoExchange.quoteSwapExactAmountOut(address(alphaUSD), address(betaUSD), uint128(amountOut));
        uint256 buffer = _getBuffer(uint256(quotedIn));

        // Set discrepancy to exceed the buffer by 1
        tempoExchange.setDiscrepancy(uint128(buffer) + 1);

        vm.prank(alice);
        vm.expectRevert();
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @notice Exact-out swap with zero discrepancy still works (baseline)
    function test_exactOutWithZeroDiscrepancy() public {
        // discrepancy is already 0 from setUp
        uint256 amountOut = SWAP_AMOUNT;

        uint256 token0Before = alphaUSD.balanceOf(alice);
        uint256 token1Before = betaUSD.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 token1Received = betaUSD.balanceOf(alice) - token1Before;
        assertEq(token1Received, amountOut, "Should receive exact output amount");

        uint256 token0Spent = token0Before - alphaUSD.balanceOf(alice);
        assertGt(token0Spent, 0, "Should spend some input tokens");
    }

    /// @notice Exact-in swaps are unaffected by the discrepancy mock (only exact-out matters)
    function test_exactInUnaffectedByDiscrepancy() public {
        tempoExchange.setDiscrepancy(15);

        uint256 amountIn = SWAP_AMOUNT;
        uint256 token0Before = alphaUSD.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 token0After = alphaUSD.balanceOf(alice);
        assertEq(token0Before - token0After, amountIn, "Exact-in should spend exact input amount");
    }

    // ========== QUOTE BUFFER TESTS ==========

    /// @notice Quote for exact-out includes buffer
    function test_quoteExactOutIncludesBuffer() public {
        uint256 amountOut = SWAP_AMOUNT;

        // Get the raw quote from the exchange directly (no buffer)
        uint128 rawQuote =
            tempoExchange.quoteSwapExactAmountOut(address(alphaUSD), address(betaUSD), uint128(amountOut));

        // Get the quote from the hook (should include buffer)
        uint256 hookQuote = hook.quote(true, int256(amountOut), poolId);

        // Hook quote should be greater than raw quote due to buffer
        assertGt(hookQuote, uint256(rawQuote), "Hook quote should include buffer on top of raw quote");
    }

    /// @notice Quote for exact-in does NOT include buffer
    function test_quoteExactInNoBuffer() public {
        uint256 amountIn = SWAP_AMOUNT;

        // Get the raw quote from the exchange directly
        uint128 rawQuote = tempoExchange.quoteSwapExactAmountIn(address(alphaUSD), address(betaUSD), uint128(amountIn));

        // Get the quote from the hook
        uint256 hookQuote = hook.quote(true, -int256(amountIn), poolId);

        // Exact-in quote should match raw quote (no buffer)
        assertEq(hookQuote, uint256(rawQuote), "Exact-in quote should not include buffer");
    }

    // ========== EXCESS RETURN TESTS ==========

    /// @notice When discrepancy is 0, the buffer tokens are returned to PoolManager (hook retains nothing)
    function test_excessTokensReturnedWhenNoDiscrepancy() public {
        uint256 amountOut = SWAP_AMOUNT;

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // The hook should NOT hold any leftover input tokens after returning excess
        assertEq(alphaUSD.balanceOf(address(hook)), 0, "Hook should not hold leftover input tokens (token0)");
        assertEq(betaUSD.balanceOf(address(hook)), 0, "Hook should not hold leftover output tokens (token1)");
    }

    /// @notice With discrepancy, hook still retains no tokens (all excess returned)
    function test_excessTokensReturnedWithDiscrepancy() public {
        tempoExchange.setDiscrepancy(10);
        uint256 amountOut = SWAP_AMOUNT;

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(alphaUSD.balanceOf(address(hook)), 0, "Hook should not hold leftover input tokens");
        assertEq(betaUSD.balanceOf(address(hook)), 0, "Hook should not hold leftover output tokens");
    }

    // ========== SCALED BUFFER TESTS ==========

    /// @notice For large amounts, the scaled buffer (amount / 1_000_000) kicks in
    function test_exactOutWithLargeAmountScaledBuffer() public {
        // For a large swap, buffer = amount / 1_000_000 which is > 20
        // At 10M tokens (10_000_000 * 1e6 = 1e13), quoted input ~ 1e13
        // buffer ~ 1e13 / 1e6 = 1e7, much larger than flat 20
        uint256 largeAmount = 10_000_000 * 10 ** DECIMALS;

        // Set discrepancy to something larger than flat buffer (20) but within scaled buffer (~1e7)
        tempoExchange.setDiscrepancy(1000);

        // Ensure enough liquidity everywhere
        alphaUSD.mint(alice, largeAmount * 2);
        alphaUSD.mint(address(manager), largeAmount * 2);
        betaUSD.mint(address(manager), largeAmount * 2);
        alphaUSD.mint(address(tempoExchange), largeAmount * 2);
        betaUSD.mint(address(tempoExchange), largeAmount * 2);

        vm.prank(alice);
        alphaUSD.approve(address(swapRouter), type(uint256).max);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(largeAmount), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        // Success means the scaled buffer absorbed the discrepancy
    }

    // ========== FUZZ TESTS ==========

    /// @notice Fuzz: exact-out succeeds with discrepancy within buffer range
    function testFuzz_exactOutWithDiscrepancy(uint128 amountOut, uint128 disc) public {
        amountOut = uint128(bound(amountOut, 1 * 10 ** DECIMALS, 100_000 * 10 ** DECIMALS));

        // Calculate what the buffer would be for this amount's quoted input
        uint128 quotedIn = tempoExchange.quoteSwapExactAmountOut(address(alphaUSD), address(betaUSD), amountOut);
        uint256 buffer = _getBuffer(uint256(quotedIn));

        // Bound discrepancy to be within the buffer
        disc = uint128(bound(disc, 0, buffer));
        tempoExchange.setDiscrepancy(disc);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true, amountSpecified: int256(uint256(amountOut)), sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        // Success means buffer absorbed the discrepancy
    }

    /// @notice Fuzz: exact-out with zero discrepancy always works
    function testFuzz_exactOutZeroDiscrepancy(uint128 amountOut) public {
        amountOut = uint128(bound(amountOut, 1 * 10 ** DECIMALS, 100_000 * 10 ** DECIMALS));

        uint256 token0Before = alphaUSD.balanceOf(alice);
        uint256 token1Before = betaUSD.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true, amountSpecified: int256(uint256(amountOut)), sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(betaUSD.balanceOf(alice) - token1Before, amountOut, "Should receive exact output");
        assertGt(token0Before - alphaUSD.balanceOf(alice), 0, "Should spend some input");
    }

    // ========== HELPER ==========

    /// @notice Mirror of the contract's _getBuffer for test assertions
    function _getBuffer(uint256 amount) internal pure returns (uint256) {
        uint256 scaled = amount / 1_000_000;
        return scaled > 20 ? scaled : 20;
    }

    receive() external payable {}
}
