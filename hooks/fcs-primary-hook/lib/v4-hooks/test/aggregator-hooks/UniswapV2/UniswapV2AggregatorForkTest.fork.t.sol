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
import {UniswapV2Aggregator} from "../../../src/aggregator-hooks/implementations/UniswapV2/UniswapV2Aggregator.sol";
import {IUniswapV2Pair as IUniV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

/// @notice Fork tests — Ethereum mainnet (chain id 1).
/// @dev `FORK_RPC_URL_1` and optional `FORK_BLOCK_NUMBER_1`. Skips when RPC unset.
contract UniswapV2AggregatorForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    address constant USDT_MAINNET = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    IPoolManager public manager;
    SafePoolSwapTest public swapRouter;
    UniswapV2Aggregator public hook;

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

        address externalPairAddr = vm.envAddress("UNISWAP_V2_EXTERNAL_PAIR");

        uint256 forkBlockNumber = vm.envOr("FORK_BLOCK_NUMBER_1", uint256(0));
        if (forkBlockNumber > 0) {
            vm.createSelectFork(rpcUrl, forkBlockNumber);
        } else {
            vm.createSelectFork(rpcUrl);
        }

        address poolManagerAddress = vm.envAddress("POOL_MANAGER_1");

        alice = address(uint160(uint256(keccak256("univ2_agg_fork_alice_v1"))));

        IUniV2Pair extPair = IUniV2Pair(externalPairAddr);
        address uniFactory = extPair.factory();
        token0Address = extPair.token0();
        token1Address = extPair.token1();

        currency0 = Currency.wrap(token0Address);
        currency1 = Currency.wrap(token1Address);

        token0Decimals = IERC20Metadata(token0Address).decimals();
        token1Decimals = IERC20Metadata(token1Address).decimals();

        manager = IPoolManager(poolManagerAddress);
        swapRouter = new SafePoolSwapTest(manager);

        _deployHook(uniFactory);

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: uint24(hook.fee()),
            tickSpacing: 1,
            hooks: IHooks(address(hook))
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

    function _deployHook(address uniFactory) internal {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );
        bytes memory constructorArgs =
            abi.encode(address(manager), uniFactory, uint256(3000), "UniswapV2Aggregator v1.0");
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(UniswapV2Aggregator).creationCode, constructorArgs);
        hook = new UniswapV2Aggregator{salt: salt}(manager, uniFactory, 3000, "UniswapV2Aggregator v1.0");
        require(address(hook) == hookAddress, "hook addr");
    }

    function test_fork_swapExactIn_quoteMatches_whenPoolIncludesUSDT() public {
        bool hasUsdt = token0Address == USDT_MAINNET || token1Address == USDT_MAINNET;
        assertTrue(hasUsdt, "Point UNISWAP_V2_EXTERNAL_PAIR at a USDT pool (README fork requirement)");

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

    function test_fork_quote_nonZero() public {
        uint256 amtIn = 1000 * (10 ** token0Decimals);
        uint256 out = hook.quote(true, -int256(amtIn), poolId);
        assertGt(out, 0);
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

    receive() external payable {}
}
