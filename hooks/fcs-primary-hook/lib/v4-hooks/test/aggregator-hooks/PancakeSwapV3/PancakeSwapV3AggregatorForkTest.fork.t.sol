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
import {
    PancakeSwapV3Aggregator
} from "../../../src/aggregator-hooks/implementations/PancakeSwapV3/PancakeSwapV3Aggregator.sol";
import {IUniswapV3Pool} from "../../../src/aggregator-hooks/implementations/UniswapV3/interfaces/IUniswapV3Pool.sol";

/// @notice Fork tests — Base mainnet (chain id 8453) PancakeSwap V3 external pools + Uniswap V4 PoolManager on Base.
/// @dev `FORK_RPC_URL_8453`, `POOL_MANAGER_8453`, `PANCAKE_V3_*`. Skips when RPC unset or any required address env is missing.
contract PancakeSwapV3AggregatorForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    /// @dev Bridged USDT on Base (verify on BaseScan for your fork block).
    address constant USDT_BASE = 0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2;

    IPoolManager public manager;
    SafePoolSwapTest public swapRouter;
    PancakeSwapV3Aggregator public hook;

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
        try vm.envString("FORK_RPC_URL_8453") returns (string memory r) {
            rpcUrl = r;
        } catch {
            vm.skip(true);
            return;
        }
        uint256 forkBlockNumber = vm.envOr("FORK_BLOCK_NUMBER_8453", uint256(0));
        if (forkBlockNumber > 0) {
            vm.createSelectFork(rpcUrl, forkBlockNumber);
        } else {
            vm.createSelectFork(rpcUrl);
        }
        address poolManagerAddress = vm.envOr("POOL_MANAGER_8453", address(0));
        address pancakeFactory = vm.envOr("PANCAKE_V3_FACTORY", address(0));
        address externalPoolAddr = vm.envOr("PANCAKE_V3_EXTERNAL_POOL", address(0));

        bool missingPancake =
            poolManagerAddress == address(0) || pancakeFactory == address(0) || externalPoolAddr == address(0);
        if (missingPancake) {
            vm.skip(true);
            return;
        }

        alice = address(uint160(uint256(keccak256("pancakeswap_v3_agg_fork_alice_v1"))));

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

        _deployHook(pancakeFactory);

        poolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: feeTier, tickSpacing: ts, hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();

        manager.initialize(poolKey, SQRT_PRICE_1_1);

        uint256 bal0 = 1_000_000 * (10 ** token0Decimals);
        uint256 bal1 = 1_000_000 * (10 ** token1Decimals);
        deal(token0Address, alice, bal0);
        deal(token1Address, alice, bal1);

        vm.startPrank(alice);
        IERC20(token0Address).forceApprove(address(swapRouter), type(uint256).max);
        IERC20(token1Address).forceApprove(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _deployHook(address factory_) internal {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );
        bytes memory constructorArgs = abi.encode(address(manager), factory_, "PancakeSwapV3Aggregator v1.0");
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(PancakeSwapV3Aggregator).creationCode, constructorArgs);
        hook = new PancakeSwapV3Aggregator{salt: salt}(manager, factory_, "PancakeSwapV3Aggregator v1.0");
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
        bool hasUsdt = token0Address == USDT_BASE || token1Address == USDT_BASE;
        assertTrue(hasUsdt, "Point PANCAKE_V3_EXTERNAL_POOL at a USDT pool (README fork requirement)");

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
        bool hasUsdt = token0Address == USDT_BASE || token1Address == USDT_BASE;
        assertTrue(hasUsdt, "Point PANCAKE_V3_EXTERNAL_POOL at a USDT pool (README fork requirement)");

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

    receive() external payable {}
}
