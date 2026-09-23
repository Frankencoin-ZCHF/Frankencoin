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
import {IAggregatorHook} from "../../../src/aggregator-hooks/interfaces/IAggregatorHook.sol";
import {
    TempoExchangeAggregator
} from "../../../src/aggregator-hooks/implementations/TempoExchange/TempoExchangeAggregator.sol";
import {
    ITempoExchange
} from "../../../src/aggregator-hooks/implementations/TempoExchange/interfaces/ITempoExchange.sol";
import {MockTempoExchange} from "./mocks/MockTempoExchange.sol";
import {RevertingMockTempoExchange} from "./mocks/RevertingMockTempoExchange.sol";

/// @title TempoExchangeTest
/// @notice Unit tests for Tempo Exchange aggregator hook
/// @dev Uses mock contracts since Tempo is a separate chain
/// @dev Heavy external-integration suite; pinned low to keep CI fast (global default is raised in foundry.toml).
/// forge-config: default.fuzz.runs = 10
contract TempoExchangeTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // Pool configuration
    uint24 constant POOL_FEE = 500; // 0.05%
    int24 constant TICK_SPACING = 10;
    uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336; // 1:1 price

    // Price limits for swaps
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    // Stablecoin decimals (Tempo uses 6 decimals)
    uint8 constant DECIMALS = 6;

    // Test amounts
    uint256 constant SWAP_AMOUNT = 1000 * 10 ** DECIMALS; // 1000 tokens
    uint256 constant INITIAL_BALANCE = 1_000_000 * 10 ** DECIMALS; // 1M tokens

    IPoolManager public manager;
    SafePoolSwapTest public swapRouter;
    TempoExchangeAggregator public hook;
    MockTempoExchange public tempoExchange;

    MockTIP20 public alphaUSD;
    MockTIP20 public betaUSD;

    PoolKey public poolKey;
    PoolId public poolId;

    Currency public currency0;
    Currency public currency1;

    address public alice = makeAddr("alice");

    function setUp() public {
        // Deploy mock tokens (simulating Tempo stablecoins)
        // alphaUSD is the "root" (quoteToken = address(0)), betaUSD quotes against alphaUSD
        alphaUSD = new MockTIP20("AlphaUSD", "aUSD", DECIMALS, address(0));
        betaUSD = new MockTIP20("BetaUSD", "bUSD", DECIMALS, address(alphaUSD));

        // Ensure tokens are ordered correctly for v4 (lower address = currency0)
        if (address(alphaUSD) > address(betaUSD)) {
            (alphaUSD, betaUSD) = (betaUSD, alphaUSD);
            // After swap, update quoteToken relationship to maintain direct connection
            alphaUSD.setQuoteToken(address(betaUSD));
            betaUSD.setQuoteToken(address(0));
        }

        currency0 = Currency.wrap(address(alphaUSD));
        currency1 = Currency.wrap(address(betaUSD));

        // Deploy mock Tempo exchange
        tempoExchange = new MockTempoExchange();

        // Register the token pair as supported by the exchange
        tempoExchange.addSupportedPair(address(alphaUSD), address(betaUSD));

        // Fund the mock exchange with liquidity
        alphaUSD.mint(address(tempoExchange), INITIAL_BALANCE * 10);
        betaUSD.mint(address(tempoExchange), INITIAL_BALANCE * 10);

        // Deploy PoolManager
        manager = IPoolManager(deployCode("foundry-out/PoolManager.sol/PoolManager.json", abi.encode(address(0))));

        // Mint tokens to PoolManager so it has liquidity for swaps
        alphaUSD.mint(address(manager), INITIAL_BALANCE * 10);
        betaUSD.mint(address(manager), INITIAL_BALANCE * 10);

        // Deploy swap router
        swapRouter = new SafePoolSwapTest(manager);

        // Deploy hook with correct address flags
        _deployHook();

        // Initialize the pool
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();

        manager.initialize(poolKey, SQRT_PRICE_1_1);

        // Mint tokens to alice for testing
        alphaUSD.mint(alice, INITIAL_BALANCE);
        betaUSD.mint(alice, INITIAL_BALANCE);

        // Approve swap router for alice
        vm.startPrank(alice);
        alphaUSD.approve(address(swapRouter), type(uint256).max);
        betaUSD.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _deployHook() internal {
        // Hook flags required by BaseAggregatorHook
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

    // ========== SWAP TESTS ==========

    /// @notice Test exact input swap: Token0 -> Token1 (zero to one)
    function test_swapExactInput_ZeroForOne() public {
        uint256 amountIn = SWAP_AMOUNT;

        // Get quote before swap
        uint256 expectedOut = hook.quote(true, -int256(amountIn), poolId);
        assertGt(expectedOut, 0, "Quote should return non-zero");

        uint256 token0Before = alphaUSD.balanceOf(alice);
        uint256 token1Before = betaUSD.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 token0After = alphaUSD.balanceOf(alice);
        uint256 token1After = betaUSD.balanceOf(alice);

        assertEq(token0Before - token0After, amountIn, "Token0 should decrease by exact input amount");

        uint256 received = token1After - token1Before;
        assertEq(received, expectedOut, "Received amount should match quote");
    }

    /// @notice Test exact input swap: Token1 -> Token0 (one to zero)
    function test_swapExactInput_OneForZero() public {
        uint256 amountIn = SWAP_AMOUNT;

        // Get quote before swap
        uint256 expectedOut = hook.quote(false, -int256(amountIn), poolId);
        assertGt(expectedOut, 0, "Quote should return non-zero");

        uint256 token0Before = alphaUSD.balanceOf(alice);
        uint256 token1Before = betaUSD.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 token0After = alphaUSD.balanceOf(alice);
        uint256 token1After = betaUSD.balanceOf(alice);

        assertEq(token1Before - token1After, amountIn, "Token1 should decrease by exact input amount");

        uint256 received = token0After - token0Before;
        assertEq(received, expectedOut, "Received amount should match quote");
    }

    /// @notice Test exact output swap: Token0 -> Token1 (zero to one)
    function test_swapExactOutput_ZeroForOne() public {
        uint256 amountOut = SWAP_AMOUNT;

        // Get quote for expected input amount
        uint256 expectedIn = hook.quote(true, int256(amountOut), poolId);
        assertGt(expectedIn, 0, "Quote should return non-zero");

        uint256 token0Before = alphaUSD.balanceOf(alice);
        uint256 token1Before = betaUSD.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 token0After = alphaUSD.balanceOf(alice);
        uint256 token1After = betaUSD.balanceOf(alice);

        uint256 token1Received = token1After - token1Before;
        assertEq(token1Received, amountOut, "Token1 received should match exact output amount");

        uint256 token0Spent = token0Before - token0After;
        // Quote includes a safety buffer for per-tick vs per-order rounding; actual spend may be less
        assertLe(token0Spent, expectedIn, "Token0 spent should not exceed quote");
        assertGt(token0Spent, 0, "Token0 spent should be non-zero");
    }

    /// @notice Test exact output swap: Token1 -> Token0 (one to zero)
    function test_swapExactOutput_OneForZero() public {
        uint256 amountOut = SWAP_AMOUNT;

        // Get quote for expected input amount
        uint256 expectedIn = hook.quote(false, int256(amountOut), poolId);
        assertGt(expectedIn, 0, "Quote should return non-zero");

        uint256 token0Before = alphaUSD.balanceOf(alice);
        uint256 token1Before = betaUSD.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 token0After = alphaUSD.balanceOf(alice);
        uint256 token1After = betaUSD.balanceOf(alice);

        uint256 token0Received = token0After - token0Before;
        assertEq(token0Received, amountOut, "Token0 received should match exact output amount");

        uint256 token1Spent = token1Before - token1After;
        // Quote includes a safety buffer for per-tick vs per-order rounding; actual spend may be less
        assertLe(token1Spent, expectedIn, "Token1 spent should not exceed quote");
        assertGt(token1Spent, 0, "Token1 spent should be non-zero");
    }

    // ========== ERROR PATH TESTS ==========

    /// @notice Test quote reverts for unregistered pool
    function test_quote_PoolDoesNotExist_reverts() public {
        // Create a fake pool ID that hasn't been registered
        PoolKey memory fakePoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 1000, // Different fee to get different pool ID
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        PoolId fakePoolId = fakePoolKey.toId();

        vm.expectRevert(IAggregatorHook.PoolDoesNotExist.selector);
        hook.quote(true, -int256(SWAP_AMOUNT), fakePoolId);
    }

    /// @notice Test pseudoTotalValueLocked reverts for unregistered pool
    function test_pseudoTotalValueLocked_PoolDoesNotExist_reverts() public {
        // Create a fake pool ID that hasn't been registered
        PoolKey memory fakePoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 1000, // Different fee to get different pool ID
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        PoolId fakePoolId = fakePoolKey.toId();

        vm.expectRevert(IAggregatorHook.PoolDoesNotExist.selector);
        hook.pseudoTotalValueLocked(fakePoolId);
    }

    /// @notice Test that amounts exceeding uint128 revert
    function test_amountExceedsUint128_reverts() public {
        // Try to quote with an amount that exceeds uint128
        uint256 hugeAmount = uint256(type(uint128).max) + 1;

        vm.expectRevert(TempoExchangeAggregator.AmountExceedsUint128.selector);
        hook.quote(true, -int256(hugeAmount), poolId);
    }

    /// @notice Test that exact output with amount exceeding uint128 reverts
    function test_amountExceedsUint128_exactOutput_reverts() public {
        uint256 hugeAmount = uint256(type(uint128).max) + 1;

        vm.expectRevert(TempoExchangeAggregator.AmountExceedsUint128.selector);
        hook.quote(true, int256(hugeAmount), poolId);
    }

    /// @notice Test initialization with tokens not directly connected in DEX tree reverts
    function test_initializeUnsupportedTokens_reverts() public {
        // Deploy tokens that are NOT directly connected (neither is quoteToken of the other)
        // gammaUSD quotes against alphaUSD, deltaUSD quotes against betaUSD
        // So gammaUSD and deltaUSD are siblings, not directly connected
        MockTIP20 gammaUSD = new MockTIP20("GammaUSD", "gUSD", DECIMALS, address(alphaUSD));
        MockTIP20 deltaUSD = new MockTIP20("DeltaUSD", "dUSD", DECIMALS, address(betaUSD));

        // Order tokens correctly
        if (address(gammaUSD) > address(deltaUSD)) {
            (gammaUSD, deltaUSD) = (deltaUSD, gammaUSD);
        }

        Currency currencyGamma = Currency.wrap(address(gammaUSD));
        Currency currencyDelta = Currency.wrap(address(deltaUSD));

        // Fund the mock exchange with new tokens
        gammaUSD.mint(address(tempoExchange), INITIAL_BALANCE);
        deltaUSD.mint(address(tempoExchange), INITIAL_BALANCE);

        // Try to initialize a pool with non-directly-connected tokens
        PoolKey memory unsupportedPoolKey = PoolKey({
            currency0: currencyGamma,
            currency1: currencyDelta,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        // PoolManager wraps hook errors in WrappedError, so we just verify it reverts
        vm.expectRevert();
        manager.initialize(unsupportedPoolKey, SQRT_PRICE_1_1);
    }

    /// @notice Test that a fake token spoofing quoteToken() is rejected by exchange validation
    function test_initializeFakeToken_reverts() public {
        // Deploy a fake token that claims to be connected to alphaUSD via quoteToken()
        // but is NOT registered as a supported pair on the exchange
        MockTIP20 fakeToken = new MockTIP20("FakeUSD", "fUSD", DECIMALS, address(alphaUSD));

        // Order tokens correctly
        address token0Addr;
        address token1Addr;
        if (address(fakeToken) < address(alphaUSD)) {
            token0Addr = address(fakeToken);
            token1Addr = address(alphaUSD);
        } else {
            token0Addr = address(alphaUSD);
            token1Addr = address(fakeToken);
        }

        // Fund the mock exchange (but do NOT register the pair as supported)
        fakeToken.mint(address(tempoExchange), INITIAL_BALANCE);

        PoolKey memory fakePoolKey = PoolKey({
            currency0: Currency.wrap(token0Addr),
            currency1: Currency.wrap(token1Addr),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        // Should revert because the exchange doesn't support this pair,
        // even though fakeToken.quoteToken() returns alphaUSD
        vm.expectRevert();
        manager.initialize(fakePoolKey, SQRT_PRICE_1_1);
    }

    /// @notice Test that a second pool for the same token pair (different fee/tickSpacing) reverts
    function test_initializeDuplicatePair_reverts() public {
        PoolKey memory duplicatePoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000, // Different fee
            tickSpacing: 60, // Different tickSpacing
            hooks: IHooks(address(hook))
        });

        // PoolManager wraps hook errors in WrappedError; we only assert that initialization reverts
        vm.expectRevert();
        manager.initialize(duplicatePoolKey, SQRT_PRICE_1_1);
    }

    // ========== SINGLETON PATTERN TESTS ==========

    /// @notice Test that the same hook can support multiple pools (singleton pattern)
    function test_singletonMultiplePools() public {
        (PoolId poolId2, address token0Addr, address token1Addr) = _deployAndInitSecondPool();

        _assertBothPoolsQuotable(poolId, poolId2);
        _assertBothPoolsTVL(poolId, poolId2);
        _assertPoolTokens(poolId, address(alphaUSD), address(betaUSD));
        _assertPoolTokens(poolId2, token0Addr, token1Addr);
    }

    function _deployAndInitSecondPool() internal returns (PoolId poolId2, address token0Addr, address token1Addr) {
        MockTIP20 gammaUSD = new MockTIP20("GammaUSD", "gUSD", DECIMALS, address(0));
        MockTIP20 deltaUSD = new MockTIP20("DeltaUSD", "dUSD", DECIMALS, address(gammaUSD));

        if (address(gammaUSD) > address(deltaUSD)) {
            (gammaUSD, deltaUSD) = (deltaUSD, gammaUSD);
            gammaUSD.setQuoteToken(address(deltaUSD));
            deltaUSD.setQuoteToken(address(0));
        }

        token0Addr = address(gammaUSD);
        token1Addr = address(deltaUSD);

        tempoExchange.addSupportedPair(token0Addr, token1Addr);
        gammaUSD.mint(address(tempoExchange), INITIAL_BALANCE * 10);
        deltaUSD.mint(address(tempoExchange), INITIAL_BALANCE * 10);
        gammaUSD.mint(address(manager), INITIAL_BALANCE * 10);
        deltaUSD.mint(address(manager), INITIAL_BALANCE * 10);

        PoolKey memory poolKey2 = PoolKey({
            currency0: Currency.wrap(token0Addr),
            currency1: Currency.wrap(token1Addr),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        poolId2 = poolKey2.toId();
        manager.initialize(poolKey2, SQRT_PRICE_1_1);
    }

    // ========== ADDITIONAL TESTS ==========

    /// @notice Test that multiple swaps work correctly
    function test_multipleSwaps() public {
        uint256 amount = SWAP_AMOUNT / 2;

        // First swap: Token0 -> Token1 (exact input)
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Second swap: Token1 -> Token0 (exact input)
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(amount), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Third swap: Token0 -> Token1 (exact output)
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(amount / 2), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @notice Verify quote function returns reasonable values
    function test_quote() public {
        uint256 amountIn = SWAP_AMOUNT;
        uint256 amountOut = SWAP_AMOUNT;

        // --- Exact-in (negative amountSpecified) ---
        // Token0 -> Token1 (zeroForOne = true)
        uint256 expectedOut0to1 = hook.quote(true, -int256(amountIn), poolId);
        assertGt(expectedOut0to1, 0, "Quote 0->1 exact-in should return non-zero");
        assertGt(expectedOut0to1, amountIn * 99 / 100, "Quote 0->1 exact-in should be close to input for stablecoins");

        // Token1 -> Token0 (zeroForOne = false)
        uint256 expectedOut1to0 = hook.quote(false, -int256(amountIn), poolId);
        assertGt(expectedOut1to0, 0, "Quote 1->0 exact-in should return non-zero");
        assertGt(expectedOut1to0, amountIn * 99 / 100, "Quote 1->0 exact-in should be close to input for stablecoins");

        // --- Exact-out (positive amountSpecified) ---
        // Token0 -> Token1: want amountOut of token1, quote returns required token0 in
        uint256 requiredIn0to1 = hook.quote(true, int256(amountOut), poolId);
        assertGt(requiredIn0to1, 0, "Quote 0->1 exact-out should return non-zero");
        assertGe(requiredIn0to1, amountOut, "Quote 0->1 exact-out: required in should be >= desired out");

        // Token1 -> Token0: want amountOut of token0, quote returns required token1 in
        uint256 requiredIn1to0 = hook.quote(false, int256(amountOut), poolId);
        assertGt(requiredIn1to0, 0, "Quote 1->0 exact-out should return non-zero");
        assertGe(requiredIn1to0, amountOut, "Quote 1->0 exact-out: required in should be >= desired out");
    }

    /// @notice Test pseudoTotalValueLocked returns non-zero values
    function test_pseudoTotalValueLocked() public view {
        (uint256 amount0, uint256 amount1) = hook.pseudoTotalValueLocked(poolId);

        assertGt(amount0, 0, "amount0 should be non-zero");
        assertGt(amount1, 0, "amount1 should be non-zero");
    }

    /// @notice Test swap with large amount
    function test_swapLargeAmount() public {
        uint256 largeAmount = 100_000 * 10 ** DECIMALS;

        // Mint extra tokens for large swap
        alphaUSD.mint(alice, largeAmount);

        uint256 expectedOut = hook.quote(true, -int256(largeAmount), poolId);
        assertGt(expectedOut, 0, "Quote should return non-zero");

        uint256 token0Before = alphaUSD.balanceOf(alice);
        uint256 token1Before = betaUSD.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(largeAmount), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 token0After = alphaUSD.balanceOf(alice);
        uint256 token1After = betaUSD.balanceOf(alice);

        assertEq(token0Before - token0After, largeAmount, "Large swap input mismatch");
        assertEq(token1After - token1Before, expectedOut, "Large swap output mismatch");
    }

    /// @notice Test swap with minimum amount (1 wei)
    function test_swapMinimumAmount() public {
        uint256 minAmount = 1;

        uint256 expectedOut = hook.quote(true, -int256(minAmount), poolId);
        // With 0.1% fee on 1 wei, output will be 0
        assertEq(expectedOut, 0, "Minimum amount output should be 0 due to fee");
    }

    // ========== FUZZ TESTS ==========

    /// @notice Fuzz test for exact input swaps (zero to one)
    function testFuzz_swapExactInput_ZeroForOne(uint128 amountIn) public {
        // Bound to reasonable amounts (1 to 100k tokens)
        amountIn = uint128(bound(amountIn, 1 * 10 ** DECIMALS, 100_000 * 10 ** DECIMALS));

        uint256 expectedOut = hook.quote(true, -int256(uint256(amountIn)), poolId);
        assertGt(expectedOut, 0, "Quote should return non-zero");

        uint256 token0Before = alphaUSD.balanceOf(alice);
        uint256 token1Before = betaUSD.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(uint256(amountIn)), sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 token0After = alphaUSD.balanceOf(alice);
        uint256 token1After = betaUSD.balanceOf(alice);

        assertEq(token0Before - token0After, amountIn, "Input amount mismatch");
        assertEq(token1After - token1Before, expectedOut, "Output amount mismatch");
    }

    /// @notice Fuzz test for exact input swaps (one to zero)
    function testFuzz_swapExactInput_OneForZero(uint128 amountIn) public {
        // Bound to reasonable amounts (1 to 100k tokens)
        amountIn = uint128(bound(amountIn, 1 * 10 ** DECIMALS, 100_000 * 10 ** DECIMALS));

        uint256 expectedOut = hook.quote(false, -int256(uint256(amountIn)), poolId);
        assertGt(expectedOut, 0, "Quote should return non-zero");

        uint256 token0Before = alphaUSD.balanceOf(alice);
        uint256 token1Before = betaUSD.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(uint256(amountIn)), sqrtPriceLimitX96: MAX_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 token0After = alphaUSD.balanceOf(alice);
        uint256 token1After = betaUSD.balanceOf(alice);

        assertEq(token1Before - token1After, amountIn, "Input amount mismatch");
        assertEq(token0After - token0Before, expectedOut, "Output amount mismatch");
    }

    /// @notice Fuzz test for exact output swaps (zero to one)
    function testFuzz_swapExactOutput_ZeroForOne(uint128 amountOut) public {
        // Bound to reasonable amounts (1 to 100k tokens)
        amountOut = uint128(bound(amountOut, 1 * 10 ** DECIMALS, 100_000 * 10 ** DECIMALS));

        uint256 expectedIn = hook.quote(true, int256(uint256(amountOut)), poolId);
        assertGt(expectedIn, 0, "Quote should return non-zero");

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

        uint256 token0After = alphaUSD.balanceOf(alice);
        uint256 token1After = betaUSD.balanceOf(alice);

        assertEq(token1After - token1Before, amountOut, "Output amount mismatch");
        // Quote includes buffer; actual spend may be less
        assertLe(token0Before - token0After, expectedIn, "Input should not exceed quote");
    }

    /// @notice Fuzz test for exact output swaps (one to zero)
    function testFuzz_swapExactOutput_OneForZero(uint128 amountOut) public {
        // Bound to reasonable amounts (1 to 100k tokens)
        amountOut = uint128(bound(amountOut, 1 * 10 ** DECIMALS, 100_000 * 10 ** DECIMALS));

        uint256 expectedIn = hook.quote(false, int256(uint256(amountOut)), poolId);
        assertGt(expectedIn, 0, "Quote should return non-zero");

        uint256 token0Before = alphaUSD.balanceOf(alice);
        uint256 token1Before = betaUSD.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: false, amountSpecified: int256(uint256(amountOut)), sqrtPriceLimitX96: MAX_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 token0After = alphaUSD.balanceOf(alice);
        uint256 token1After = betaUSD.balanceOf(alice);

        assertEq(token0After - token0Before, amountOut, "Output amount mismatch");
        // Quote includes buffer; actual spend may be less
        assertLe(token1Before - token1After, expectedIn, "Input should not exceed quote");
    }

    // ========== GAS COMPARISON TESTS ==========

    /// @notice Measure gas for a swap when the hook has zero token balance (cold storage)
    function test_gasBaseline_noPreSeed() public {
        uint256 amountIn = SWAP_AMOUNT;

        vm.prank(alice);
        uint256 gasBefore = gasleft();
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("Gas used (no pre-seed)", gasUsed);
    }

    /// @notice Measure gas for a swap after pre-seeding hook with 0.000001 tokens (warm storage)
    function test_gasWithPreSeed() public {
        uint256 amountIn = SWAP_AMOUNT;

        // Transfer 0.000001 alphaUSD (1 unit with 6 decimals) to the hook ahead of the swap
        alphaUSD.mint(address(hook), 1);

        vm.prank(alice);
        uint256 gasBefore = gasleft();
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("Gas used (with 0.000001 pre-seed)", gasUsed);
    }

    /// @notice Measure gas when only the output token (betaUSD) is pre-seeded
    function test_gasWithPreSeed_outputTokenOnly() public {
        uint256 amountIn = SWAP_AMOUNT;

        // Transfer 0.000001 betaUSD (output token for zeroForOne) to the hook
        betaUSD.mint(address(hook), 1);

        vm.prank(alice);
        uint256 gasBefore = gasleft();
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("Gas used (output token pre-seed only)", gasUsed);
    }

    /// @notice Measure gas when both tokens are pre-seeded
    function test_gasWithPreSeed_bothTokens() public {
        uint256 amountIn = SWAP_AMOUNT;

        // Transfer 0.000001 of each token to the hook
        alphaUSD.mint(address(hook), 1);
        betaUSD.mint(address(hook), 1);

        vm.prank(alice);
        uint256 gasBefore = gasleft();
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("Gas used (both tokens pre-seed)", gasUsed);
    }

    /// @notice Measure gas with cold PoolManager (0 output token balance) and cold hook
    function test_gasColdPoolManager_coldHook() public {
        uint256 amountIn = SWAP_AMOUNT;

        // Zero out PM's betaUSD (output token for zeroForOne swap)
        deal(address(betaUSD), address(manager), 0);

        vm.prank(alice);
        uint256 gasBefore = gasleft();
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("Gas used (cold PM, cold hook)", gasUsed);
    }

    /// @notice Measure gas with seeded PoolManager (1 unit output token) and cold hook
    function test_gasSeededPoolManager_coldHook() public {
        uint256 amountIn = SWAP_AMOUNT;

        // Set PM's betaUSD to just 1 unit (warm but minimal)
        deal(address(betaUSD), address(manager), 1);

        vm.prank(alice);
        uint256 gasBefore = gasleft();
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("Gas used (seeded PM, cold hook)", gasUsed);
    }

    /// @notice Fuzz test for quote consistency (exact in vs exact out)
    function testFuzz_quoteConsistency(uint128 amount) public {
        // Bound to reasonable amounts
        amount = uint128(bound(amount, 100 * 10 ** DECIMALS, 10_000 * 10 ** DECIMALS));

        // Get output for exact input
        uint256 outputFromExactIn = hook.quote(true, -int256(uint256(amount)), poolId);

        // Get input required for that output (includes safety buffer)
        uint256 inputForExactOut = hook.quote(true, int256(outputFromExactIn), poolId);

        // The exact-out quote includes a buffer for rounding safety, so the round-trip
        // may slightly exceed the original. Allow up to buffer tolerance.
        uint256 bufferTolerance = _getBuffer(uint256(amount));
        assertLe(inputForExactOut, uint256(amount) + bufferTolerance, "Round-trip should not exceed original + buffer");
    }

    function _getBuffer(uint256 amount) internal pure returns (uint256) {
        uint256 scaled = amount / 1_000_000;
        return scaled > 20 ? scaled : 20;
    }

    /// ========== Avoid Stack-Too-Deep Errors ==========
    function _assertBothPoolsQuotable(PoolId id1, PoolId id2) internal {
        assertGt(hook.quote(true, -int256(SWAP_AMOUNT), id1), 0, "First pool quote should work");
        assertGt(hook.quote(true, -int256(SWAP_AMOUNT), id2), 0, "Second pool quote should work");
    }

    function _assertBothPoolsTVL(PoolId id1, PoolId id2) internal view {
        (uint256 tvl1_0, uint256 tvl1_1) = hook.pseudoTotalValueLocked(id1);
        (uint256 tvl2_0, uint256 tvl2_1) = hook.pseudoTotalValueLocked(id2);
        assertGt(tvl1_0, 0, "First pool TVL token0");
        assertGt(tvl1_1, 0, "First pool TVL token1");
        assertGt(tvl2_0, 0, "Second pool TVL token0");
        assertGt(tvl2_1, 0, "Second pool TVL token1");
    }

    function _assertPoolTokens(PoolId id, address expected0, address expected1) internal view {
        (address stored0, address stored1) = hook.poolIdToTokens(id);
        assertEq(stored0, expected0, "token0 mismatch");
        assertEq(stored1, expected1, "token1 mismatch");
    }

    receive() external payable {}
}
