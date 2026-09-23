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
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";
import {SafePoolSwapTest} from "../shared/SafePoolSwapTest.sol";
import {SlipstreamAggregator} from "../../../src/aggregator-hooks/implementations/Slipstream/SlipstreamAggregator.sol";
import {IUniswapV3Pool} from "../../../src/aggregator-hooks/implementations/UniswapV3/interfaces/IUniswapV3Pool.sol";
import {
    ISlipstreamFactory
} from "../../../src/aggregator-hooks/implementations/Slipstream/interfaces/ISlipstreamFactory.sol";

/// @notice Fork tests — Base mainnet (chain id 8453) Slipstream.
/// @dev `FORK_RPC_URL_8453` and optional `FORK_BLOCK_NUMBER_8453`. Skips when RPC unset.
contract SlipstreamAggregatorForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;

    IPoolManager public manager;
    SafePoolSwapTest public swapRouter;
    SlipstreamAggregator public hook;

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

        address poolManagerAddress = vm.envAddress("POOL_MANAGER_8453");
        address slipFactory = vm.envAddress("SLIPSTREAM_FACTORY");
        address externalPoolAddr = vm.envAddress("SLIPSTREAM_EXTERNAL_POOL");

        alice = address(uint160(uint256(keccak256("slipstream_agg_fork_alice_v1"))));

        IUniswapV3Pool extPool = IUniswapV3Pool(externalPoolAddr);
        token0Address = extPool.token0();
        token1Address = extPool.token1();
        token0Decimals = IERC20Metadata(token0Address).decimals();
        token1Decimals = IERC20Metadata(token1Address).decimals();

        ISlipstreamFactory sf = ISlipstreamFactory(slipFactory);
        int24 ts = extPool.tickSpacing();
        require(
            sf.getPool(token0Address, token1Address, ts) == externalPoolAddr,
            "fork: SLIPSTREAM_FACTORY does not register SLIPSTREAM_EXTERNAL_POOL at pool.tickSpacing()"
        );

        currency0 = Currency.wrap(token0Address);
        currency1 = Currency.wrap(token1Address);

        manager = IPoolManager(poolManagerAddress);
        swapRouter = new SafePoolSwapTest(manager);

        _deployHook(slipFactory);

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: ts,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();

        manager.initialize(poolKey, SQRT_PRICE_1_1);

        deal(token0Address, alice, 1_000_000 * (10 ** token0Decimals));
        deal(token1Address, alice, 1_000_000 * (10 ** token1Decimals));

        vm.startPrank(alice);
        IERC20(token0Address).forceApprove(address(swapRouter), type(uint256).max);
        IERC20(token1Address).forceApprove(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _deployHook(address slipFactory) internal {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );
        bytes memory constructorArgs = abi.encode(address(manager), slipFactory);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(SlipstreamAggregator).creationCode, constructorArgs);
        hook = new SlipstreamAggregator{salt: salt}(manager, slipFactory);
        require(address(hook) == hookAddress, "hook addr");
    }

    function test_fork_swapExactIn_quoteMatches() public {
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

    receive() external payable {}
}
