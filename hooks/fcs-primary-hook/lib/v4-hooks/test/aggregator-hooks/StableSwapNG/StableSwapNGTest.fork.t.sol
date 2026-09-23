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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {MockV4FeeAdapter} from "../mocks/MockV4FeeAdapter.sol";
import {SafePoolSwapTest} from "../shared/SafePoolSwapTest.sol";
import {
    StableSwapNGAggregator
} from "../../../src/aggregator-hooks/implementations/StableSwapNG/StableSwapNGAggregator.sol";
import {
    StableSwapNGAggregatorFactory
} from "../../../src/aggregator-hooks/implementations/StableSwapNG/StableSwapNGAggregatorFactory.sol";
import {
    ICurveStableSwapNG
} from "../../../src/aggregator-hooks/implementations/StableSwapNG/interfaces/ICurveStableSwapNG.sol";
import {
    ICurveStableSwapFactoryNG
} from "../../../src/aggregator-hooks/implementations/StableSwapNG/interfaces/ICurveStableSwapFactoryNG.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";

contract StableSwapNGForkedTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // Pool configuration
    uint24 constant POOL_FEE = 500; // 0.05%
    int24 constant TICK_SPACING = 10; // Default tick spacing for a 0.05% fee pool
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 1:1 price

    // Price limits for swaps
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    // Loaded from .env
    address curvePoolAddress;
    address curveFactoryNg;

    // Dynamic token storage for multi-token pools
    Currency[] public poolTokens; // All tokens in the Curve pool (sorted by address)
    uint256 public numTokens;

    IPoolManager public manager;
    MockV4FeeAdapter public feeAdapter;
    SafePoolSwapTest public swapRouter;
    StableSwapNGAggregator public hook;
    StableSwapNGAggregatorFactory public factory;
    ICurveStableSwapNG public curvePool;

    // Storage for all token pairs and their pools
    struct TokenPair {
        address token0;
        address token1;
        PoolKey poolKey;
        PoolId poolId;
    }

    TokenPair[] public tokenPairs;

    address public alice = makeAddr("alice");

    function setUp() public {
        string memory rpcUrl;
        // Forking requires an RPC URL env var and an optional block number
        try vm.envString("FORK_RPC_URL_1") returns (string memory _rpcUrl) {
            rpcUrl = _rpcUrl;
        } catch {
            console.log("Not forking. Skipping tests");
            vm.skip(true);
            return;
        }

        uint256 forkBlockNumber = vm.envOr("FORK_BLOCK_NUMBER_1", uint256(0));
        // Load Curve pool address from env vars
        curvePoolAddress = vm.envAddress("STABLE_SWAP_NG_POOL");
        // Load Curve factory address from env vars
        curveFactoryNg = vm.envAddress("CURVE_FACTORY_NG");
        // Load V4 infrastructure address from env vars
        address poolManagerAddress = vm.envAddress("POOL_MANAGER_1");

        if (forkBlockNumber > 0) {
            vm.createSelectFork(rpcUrl, forkBlockNumber);
        } else {
            vm.createSelectFork(rpcUrl);
        }

        // Load pool address from .env
        curvePool = ICurveStableSwapNG(curvePoolAddress);

        // Use deployed PoolManager
        manager = IPoolManager(poolManagerAddress);

        // Deploy swap router
        swapRouter = new SafePoolSwapTest(manager);
        feeAdapter = new MockV4FeeAdapter(manager, address(this));

        // Deploy factory with real Curve NG factory
        factory = new StableSwapNGAggregatorFactory(manager, ICurveStableSwapFactoryNG(curveFactoryNg));

        // Dynamically fetch all tokens from the Curve pool
        numTokens = curvePool.N_COINS();
        require(numTokens >= 2, "Pool must have at least 2 tokens");

        // Collect tokens and sort them
        address[] memory unsortedTokens = new address[](numTokens);
        for (uint256 i = 0; i < numTokens; i++) {
            unsortedTokens[i] = curvePool.coins(i);
        }

        // Sort tokens by address (simple bubble sort for small arrays)
        for (uint256 i = 0; i < numTokens; i++) {
            for (uint256 j = i + 1; j < numTokens; j++) {
                if (unsortedTokens[i] > unsortedTokens[j]) {
                    (unsortedTokens[i], unsortedTokens[j]) = (unsortedTokens[j], unsortedTokens[i]);
                }
            }
            poolTokens.push(Currency.wrap(unsortedTokens[i]));
        }

        // Deploy hook via factory (which initializes all pools)
        _deployHookViaFactory();

        // Build token pairs array from the initialized pools
        _buildTokenPairs();

        // Deal tokens to alice and approve for all tokens
        _setupAlice();
    }

    function _deployHookViaFactory() internal {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );

        bytes memory constructorArgs = abi.encode(address(manager), address(curvePool), curveFactoryNg);
        (address expectedHookAddress, bytes32 salt) =
            HookMiner.find(address(factory), flags, type(StableSwapNGAggregator).creationCode, constructorArgs);

        // Deploy and initialize all pools via factory
        address hookAddress = factory.createPool(salt, curvePool, poolTokens, POOL_FEE, TICK_SPACING, SQRT_PRICE_1_1);

        require(hookAddress == expectedHookAddress, "Hook address mismatch");
        hook = StableSwapNGAggregator(payable(hookAddress));
    }

    function _buildTokenPairs() internal {
        // Build token pairs for all combinations (factory already initialized them)
        for (uint256 i = 0; i < numTokens; i++) {
            for (uint256 j = i + 1; j < numTokens; j++) {
                address token0 = Currency.unwrap(poolTokens[i]);
                address token1 = Currency.unwrap(poolTokens[j]);

                PoolKey memory poolKey = PoolKey({
                    currency0: poolTokens[i],
                    currency1: poolTokens[j],
                    fee: POOL_FEE,
                    tickSpacing: TICK_SPACING,
                    hooks: IHooks(address(hook))
                });

                tokenPairs.push(TokenPair({token0: token0, token1: token1, poolKey: poolKey, poolId: poolKey.toId()}));
            }
        }
    }

    function _setupAlice() internal {
        // Deal and approve all tokens for alice
        for (uint256 i = 0; i < numTokens; i++) {
            address token = Currency.unwrap(poolTokens[i]);
            uint8 decimals = IERC20Metadata(token).decimals();
            uint256 balance = 1_000_000 * (10 ** decimals);
            deal(token, alice, balance);

            vm.prank(alice);
            IERC20(token).approve(address(swapRouter), type(uint256).max);
        }

        // Seed the PoolManager with tokens for swaps
        for (uint256 i = 0; i < numTokens; i++) {
            address token = Currency.unwrap(poolTokens[i]);
            uint8 decimals = IERC20Metadata(token).decimals();
            uint256 seedAmount = 100_000 * (10 ** decimals);
            deal(token, address(manager), seedAmount);
        }
    }

    /// @notice Get a safe swap amount based on token decimals
    function _getSwapAmount(address token) internal view returns (uint256) {
        uint8 decimals = IERC20Metadata(token).decimals();
        // Use 0.1 tokens to be safe with low-liquidity pools
        return (10 ** decimals) / 10;
    }

    /// @notice Get safe swap amount based on PoolManager balance
    function _getSafeAmount(address token, uint256 desiredAmount) internal view returns (uint256) {
        uint256 poolManagerBalance = IERC20(token).balanceOf(address(manager));
        uint256 maxSafe = poolManagerBalance * 90 / 100;
        return desiredAmount < maxSafe ? desiredAmount : maxSafe;
    }

    // ========== ALL POOLS SWAP TESTS ==========

    /// @notice Test exact input swaps (zeroForOne) for all token pairs
    function test_swapExactInput_ZeroForOne_AllPools() public {
        for (uint256 i = 0; i < tokenPairs.length; i++) {
            _testExactInputSwap(tokenPairs[i], true);
        }
    }

    /// @notice Test exact input swaps (oneForZero) for all token pairs
    function test_swapExactInput_OneForZero_AllPools() public {
        for (uint256 i = 0; i < tokenPairs.length; i++) {
            _testExactInputSwap(tokenPairs[i], false);
        }
    }

    /// @notice Test exact output swaps (zeroForOne) for all token pairs
    function test_swapExactOutput_ZeroForOne_AllPools() public {
        for (uint256 i = 0; i < tokenPairs.length; i++) {
            _testExactOutputSwap(tokenPairs[i], true);
        }
    }

    /// @notice Test exact output swaps (oneForZero) for all token pairs
    function test_swapExactOutput_OneForZero_AllPools() public {
        for (uint256 i = 0; i < tokenPairs.length; i++) {
            _testExactOutputSwap(tokenPairs[i], false);
        }
    }

    function _testExactInputSwap(TokenPair memory pair, bool zeroForOne) internal {
        address tokenIn = zeroForOne ? pair.token0 : pair.token1;
        address tokenOut = zeroForOne ? pair.token1 : pair.token0;
        uint256 amountIn = _getSwapAmount(tokenIn);

        // Get quote before swap
        uint256 expectedOut = hook.quote(zeroForOne, -int256(amountIn), pair.poolId);
        assertGt(expectedOut, 0, "Quote should return non-zero");

        uint256 tokenInBefore = IERC20(tokenIn).balanceOf(alice);
        uint256 tokenOutBefore = IERC20(tokenOut).balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            pair.poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 tokenInAfter = IERC20(tokenIn).balanceOf(alice);
        uint256 tokenOutAfter = IERC20(tokenOut).balanceOf(alice);

        // Verify tokenIn decreased by exact input amount
        assertEq(tokenInBefore - tokenInAfter, amountIn, "TokenIn should decrease by exact input amount");

        // Verify tokenOut increased and matches quote
        uint256 tokenOutReceived = tokenOutAfter - tokenOutBefore;
        assertEq(tokenOutReceived, expectedOut, "Received amount should match quote");
    }

    function _testExactOutputSwap(TokenPair memory pair, bool zeroForOne) internal {
        address tokenIn = zeroForOne ? pair.token0 : pair.token1;
        address tokenOut = zeroForOne ? pair.token1 : pair.token0;

        // Use safe amount based on PoolManager balance of input token
        uint256 desiredAmountOut = _getSwapAmount(tokenOut);
        uint256 amountOut = _getSafeAmount(tokenOut, desiredAmountOut);
        if (amountOut == 0) return; // Skip if PoolManager has no balance

        // Get quote for expected input amount
        uint256 expectedIn = hook.quote(zeroForOne, int256(amountOut), pair.poolId);
        assertGt(expectedIn, 0, "Quote should return non-zero");

        uint256 tokenInBefore = IERC20(tokenIn).balanceOf(alice);
        uint256 tokenOutBefore = IERC20(tokenOut).balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            pair.poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(amountOut),
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 tokenInAfter = IERC20(tokenIn).balanceOf(alice);
        uint256 tokenOutAfter = IERC20(tokenOut).balanceOf(alice);

        // Verify tokenOut increased by the exact output amount
        assertEq(tokenOutAfter - tokenOutBefore, amountOut, "TokenOut should increase by ~exact output amount");

        // Verify tokenIn spent matches quote
        uint256 tokenInSpent = tokenInBefore - tokenInAfter;
        assertEq(tokenInSpent, expectedIn, "TokenIn spent should match quote");
    }

    // ========== ADDITIONAL TESTS ==========

    /// @notice Test that multiple swaps work correctly across different pairs
    function test_multipleSwaps() public {
        require(tokenPairs.length > 0, "No token pairs available");

        TokenPair memory pair = tokenPairs[0];
        uint256 amount0 = _getSwapAmount(pair.token0) / 10;
        uint256 amount1 = _getSwapAmount(pair.token1) / 10;
        // First swap: Token0 -> Token1
        vm.prank(alice);
        swapRouter.swap(
            pair.poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amount0), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Second swap: Token1 -> Token0
        vm.prank(alice);
        swapRouter.swap(
            pair.poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(amount1), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Third swap: exact output
        vm.prank(alice);
        swapRouter.swap(
            pair.poolKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(amount1 / 2), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @notice Verify quote function returns reasonable values for all pairs
    function test_quote_AllPairs() public {
        for (uint256 i = 0; i < tokenPairs.length; i++) {
            TokenPair memory pair = tokenPairs[i];
            uint256 amountIn = _getSwapAmount(pair.token0);

            // Quote for exact input (negative amountSpecified) - zeroForOne
            uint256 expectedOut = hook.quote(true, -int256(amountIn), pair.poolId);
            assertGt(expectedOut, 0, "Quote should return non-zero");

            // Quote for exact input - oneForZero
            amountIn = _getSwapAmount(pair.token1);
            expectedOut = hook.quote(false, -int256(amountIn), pair.poolId);
            assertGt(expectedOut, 0, "Quote should return non-zero for oneForZero");
        }
    }

    /// @notice Test pseudoTotalValueLocked returns values matching Curve pool balances for all pairs
    function test_pseudoTotalValueLocked_AllPairs() public view {
        for (uint256 i = 0; i < tokenPairs.length; i++) {
            TokenPair memory pair = tokenPairs[i];

            (uint256 amount0, uint256 amount1) = hook.pseudoTotalValueLocked(pair.poolId);

            (int128 token0Index, int128 token1Index) = hook.poolIdToTokenInfo(pair.poolId);
            uint256 expectedBalance0 = curvePool.balances(uint256(uint128(token0Index)));
            uint256 expectedBalance1 = curvePool.balances(uint256(uint128(token1Index)));

            assertEq(amount0, expectedBalance0, "amount0 should match Curve pool balance");
            assertEq(amount1, expectedBalance1, "amount1 should match Curve pool balance");
            assertGt(amount0, 0, "amount0 should be non-zero");
            assertGt(amount1, 0, "amount1 should be non-zero");
        }
    }

    // ========== COMPREHENSIVE ALL-DIRECTIONS TESTS ==========

    /// @notice Single test that performs exactIn swaps in all directions on all pools
    function test_swapAllPools_ExactIn_AllDirections() public {
        for (uint256 i = 0; i < tokenPairs.length; i++) {
            TokenPair memory pair = tokenPairs[i];

            // ZeroForOne
            uint256 amountIn = _getSwapAmount(pair.token0);
            vm.prank(alice);
            swapRouter.swap(
                pair.poolKey,
                SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
                SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );

            // OneForZero
            amountIn = _getSwapAmount(pair.token1);
            vm.prank(alice);
            swapRouter.swap(
                pair.poolKey,
                SwapParams({zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
                SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
        }
    }

    /// @notice Single test that performs exactOut swaps in all directions on all pools
    function test_swapAllPools_ExactOut_AllDirections() public {
        for (uint256 i = 0; i < tokenPairs.length; i++) {
            TokenPair memory pair = tokenPairs[i];

            // ZeroForOne - output is token1
            uint256 amountOut = _getSafeAmount(pair.token1, _getSwapAmount(pair.token1));
            if (amountOut > 0) {
                vm.prank(alice);
                swapRouter.swap(
                    pair.poolKey,
                    SwapParams({
                        zeroForOne: true, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MIN_PRICE_LIMIT
                    }),
                    SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                    ""
                );
            }

            // OneForZero - output is token0
            amountOut = _getSafeAmount(pair.token0, _getSwapAmount(pair.token0));
            if (amountOut > 0) {
                vm.prank(alice);
                swapRouter.swap(
                    pair.poolKey,
                    SwapParams({
                        zeroForOne: false, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MAX_PRICE_LIMIT
                    }),
                    SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                    ""
                );
            }
        }
    }

    /// @notice Returns the number of token pairs created
    function getTokenPairsCount() external view returns (uint256) {
        return tokenPairs.length;
    }

    receive() external payable {}
}
