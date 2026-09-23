// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";
import {SafePoolSwapTest} from "../shared/SafePoolSwapTest.sol";
import {UniswapV3Aggregator} from "../../../src/aggregator-hooks/implementations/UniswapV3/UniswapV3Aggregator.sol";
import {IUniswapV3Pool} from "../../../src/aggregator-hooks/implementations/UniswapV3/interfaces/IUniswapV3Pool.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {Deploy} from "@uniswap/v4-periphery/test/shared/Deploy.sol";

/// @notice Fork tests — Ethereum mainnet (chain id 1).
/// @dev `FORK_RPC_URL_1` and optional `FORK_BLOCK_NUMBER_1`. Skips when RPC unset.
contract UniswapV3AggregatorForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    address constant USDT_MAINNET = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    IPoolManager public manager;
    SafePoolSwapTest public swapRouter;
    UniswapV3Aggregator public hook;
    IV4Quoter public quoter;

    address public token0Address;
    address public token1Address;
    uint8 public token0Decimals;
    uint8 public token1Decimals;

    PoolKey public poolKey;
    PoolId public poolId;

    Currency public currency0;
    Currency public currency1;

    address public alice;

    function setUp() public {
        string memory rpcUrl;
        try vm.envString("FORK_RPC_URL_1") returns (string memory r) {
            rpcUrl = r;
        } catch {
            vm.skip(true);
            return;
        }
        uint256 forkBlockNumber = vm.envOr("FORK_BLOCK_NUMBER_1", uint256(0));
        if (forkBlockNumber > 0) {
            vm.createSelectFork(rpcUrl, forkBlockNumber);
        } else {
            vm.createSelectFork(rpcUrl);
        }
        address poolManagerAddress = vm.envAddress("POOL_MANAGER_1");
        address uniFactory = vm.envAddress("UNISWAP_V3_FACTORY");
        address externalPoolAddr = vm.envAddress("UNISWAP_V3_EXTERNAL_POOL");

        alice = address(uint160(uint256(keccak256("univ3_agg_fork_alice_v1"))));

        IUniswapV3Pool extPool = IUniswapV3Pool(externalPoolAddr);
        token0Address = extPool.token0();
        token1Address = extPool.token1();
        uint24 feeTier = extPool.fee();
        int24 ts = extPool.tickSpacing();

        currency0 = Currency.wrap(token0Address);
        currency1 = Currency.wrap(token1Address);

        token0Decimals = IERC20Metadata(token0Address).decimals();
        token1Decimals = IERC20Metadata(token1Address).decimals();

        manager = IPoolManager(poolManagerAddress);
        swapRouter = new SafePoolSwapTest(manager);

        _deployHook(uniFactory);

        poolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: feeTier, tickSpacing: ts, hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();

        manager.initialize(poolKey, SQRT_PRICE_1_1);

        quoter = Deploy.v4Quoter(address(manager), hex"00");

        uint256 bal0 = 1_000_000 * (10 ** token0Decimals);
        uint256 bal1 = 1_000_000 * (10 ** token1Decimals);
        deal(token0Address, alice, bal0);
        deal(token1Address, alice, bal1);

        vm.startPrank(alice);
        IERC20(token0Address).forceApprove(address(swapRouter), type(uint256).max);
        IERC20(token1Address).forceApprove(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _deployHook(address uniFactory) internal {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );
        bytes memory constructorArgs = abi.encode(address(manager), uniFactory, "UniswapV3Aggregator v1.0");
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(UniswapV3Aggregator).creationCode, constructorArgs);
        hook = new UniswapV3Aggregator{salt: salt}(manager, uniFactory, "UniswapV3Aggregator v1.0");
        require(address(hook) == hookAddress, "hook addr");
    }

    function test_fork_swapExactIn_quoteMatches_zeroForOne() public {
        uint256 amtIn = 100 * (10 ** token0Decimals);
        uint256 expectedOut = hook.quote(true, -int256(amtIn), poolId);

        uint256 t1Before = IERC20(token1Address).balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amtIn), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(IERC20(token1Address).balanceOf(alice) - t1Before, expectedOut);
    }

    function test_fork_swapExactIn_quoteMatches_oneForZero() public {
        uint256 amtIn = 100 * (10 ** token1Decimals);
        uint256 expectedOut = hook.quote(false, -int256(amtIn), poolId);

        uint256 t0Before = IERC20(token0Address).balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(amtIn), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(IERC20(token0Address).balanceOf(alice) - t0Before, expectedOut);
    }

    function test_fork_swapExactIn_quoteMatches_whenPoolIncludesUSDT_zeroForOne() public {
        bool hasUsdt = token0Address == USDT_MAINNET || token1Address == USDT_MAINNET;
        assertTrue(hasUsdt, "Point UNISWAP_V3_EXTERNAL_POOL at a USDT pool (README fork requirement)");

        uint256 amtIn = 100 * (10 ** token0Decimals);
        uint256 expectedOut = hook.quote(true, -int256(amtIn), poolId);

        uint256 t1Before = IERC20(token1Address).balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amtIn), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(IERC20(token1Address).balanceOf(alice) - t1Before, expectedOut);
    }

    function test_fork_swapExactIn_quoteMatches_whenPoolIncludesUSDT_oneForZero() public {
        bool hasUsdt = token0Address == USDT_MAINNET || token1Address == USDT_MAINNET;
        assertTrue(hasUsdt, "Point UNISWAP_V3_EXTERNAL_POOL at a USDT pool (README fork requirement)");

        uint256 amtIn = 100 * (10 ** token1Decimals);
        uint256 expectedOut = hook.quote(false, -int256(amtIn), poolId);

        uint256 t0Before = IERC20(token0Address).balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(amtIn), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(IERC20(token0Address).balanceOf(alice) - t0Before, expectedOut);
    }

    function test_fork_quote_nonZero_zeroForOne() public {
        uint256 amtIn = 1000 * (10 ** token0Decimals);
        uint256 out = hook.quote(true, -int256(amtIn), poolId);
        assertGt(out, 0);
    }

    function test_fork_quote_nonZero_oneForZero() public {
        uint256 amtIn = 1000 * (10 ** token1Decimals);
        uint256 out = hook.quote(false, -int256(amtIn), poolId);
        assertGt(out, 0);
    }

    // ── V4Quoter tests ────────────────────────────────────────────────────────

    function test_fork_v4Quoter_exactInput_matchesSwap_zeroForOne() public {
        uint128 amtIn = uint128(100 * (10 ** token0Decimals));

        uint256 hookQuote = hook.quote(true, -int256(uint256(amtIn)), poolId);
        (uint256 quotedOut,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({poolKey: poolKey, zeroForOne: true, exactAmount: amtIn, hookData: ""})
        );
        assertEq(quotedOut, hookQuote, "V4Quoter should match hook.quote");

        uint256 t1Before = IERC20(token1Address).balanceOf(alice);
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(uint256(amtIn)), sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertEq(IERC20(token1Address).balanceOf(alice) - t1Before, quotedOut, "actual output should match V4Quoter");
    }

    function test_fork_v4Quoter_exactInput_matchesSwap_oneForZero() public {
        uint128 amtIn = uint128(100 * (10 ** token1Decimals));

        uint256 hookQuote = hook.quote(false, -int256(uint256(amtIn)), poolId);
        (uint256 quotedOut,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({poolKey: poolKey, zeroForOne: false, exactAmount: amtIn, hookData: ""})
        );
        assertEq(quotedOut, hookQuote, "V4Quoter should match hook.quote");

        uint256 t0Before = IERC20(token0Address).balanceOf(alice);
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(uint256(amtIn)), sqrtPriceLimitX96: MAX_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertEq(IERC20(token0Address).balanceOf(alice) - t0Before, quotedOut, "actual output should match V4Quoter");
    }

    function test_fork_v4Quoter_exactOutput_matchesSwap_zeroForOne() public {
        uint128 amtOut = uint128(50 * (10 ** token1Decimals));

        uint256 hookQuote = hook.quote(true, int256(uint256(amtOut)), poolId);
        (uint256 quotedIn,) = quoter.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams({poolKey: poolKey, zeroForOne: true, exactAmount: amtOut, hookData: ""})
        );
        assertEq(quotedIn, hookQuote, "V4Quoter should match hook.quote");

        uint256 t0Before = IERC20(token0Address).balanceOf(alice);
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true, amountSpecified: int256(uint256(amtOut)), sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertEq(t0Before - IERC20(token0Address).balanceOf(alice), quotedIn, "actual input should match V4Quoter");
    }

    function test_fork_v4Quoter_exactOutput_matchesSwap_oneForZero() public {
        uint128 amtOut = uint128(50 * (10 ** token0Decimals));

        uint256 hookQuote = hook.quote(false, int256(uint256(amtOut)), poolId);
        (uint256 quotedIn,) = quoter.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams({poolKey: poolKey, zeroForOne: false, exactAmount: amtOut, hookData: ""})
        );
        assertEq(quotedIn, hookQuote, "V4Quoter should match hook.quote");

        uint256 t1Before = IERC20(token1Address).balanceOf(alice);
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: false, amountSpecified: int256(uint256(amtOut)), sqrtPriceLimitX96: MAX_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertEq(t1Before - IERC20(token1Address).balanceOf(alice), quotedIn, "actual input should match V4Quoter");
    }

    receive() external payable {}
}
