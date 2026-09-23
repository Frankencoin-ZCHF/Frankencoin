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
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {UniV3MintHelper} from "../UniswapV3/mocks/UniV3MintHelper.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";
import {SafePoolSwapTest} from "../shared/SafePoolSwapTest.sol";
import {SlipstreamAggregator} from "../../../src/aggregator-hooks/implementations/Slipstream/SlipstreamAggregator.sol";

/// @dev CL factory: `getPool` (hook routing) + `createPool` (local pool on fork).
interface ISlipstreamCLFactory {
    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address pool);
    function createPool(address tokenA, address tokenB, int24 tickSpacing, uint160 sqrtPriceX96)
        external
        returns (address pool);
}

/// @title SlipstreamAggregatorFuzz
/// @notice Fuzz on a Base fork using canonical Slipstream CL factory; creates a fresh CL pool from mock ERC-20s.
/// @dev Skips when RPC unset.
/// @dev Fork-bound; pinned low to keep CI fast (global default is raised in foundry.toml).
/// forge-config: default.fuzz.runs = 10
contract SlipstreamAggregatorFuzz is Test {
    using PoolIdLibrary for PoolKey;

    int24 constant TICK_SPACING = 100;
    int24 constant TICK_LOWER = -600;
    int24 constant TICK_UPPER = 600;
    uint128 constant LIQUIDITY_AMOUNT = 1e24;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant MIN_PRICE = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE = TickMath.MAX_SQRT_PRICE - 1;

    IPoolManager public poolManager;
    SafePoolSwapTest public swapRouter;
    SlipstreamAggregator public hook;

    ISlipstreamCLFactory public clFactory;
    address public extPool;

    MockERC20 public token0;
    MockERC20 public token1;

    address public alice = makeAddr("alice");
    PoolKey public poolKey;
    PoolId public poolId;

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

        address slipFactory = vm.envAddress("SLIPSTREAM_FACTORY");
        clFactory = ISlipstreamCLFactory(slipFactory);

        poolManager =
            IPoolManager(vm.deployCode("foundry-out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        swapRouter = new SafePoolSwapTest(poolManager);

        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        if (address(token0) > address(token1)) (token0, token1) = (token1, token0);

        extPool = clFactory.createPool(address(token0), address(token1), TICK_SPACING, SQRT_PRICE_1_1);
        require(clFactory.getPool(address(token0), address(token1), TICK_SPACING) == extPool, "getPool");

        UniV3MintHelper mintHelper = new UniV3MintHelper();
        token0.mint(address(this), type(uint128).max);
        token1.mint(address(this), type(uint128).max);
        token0.approve(address(mintHelper), type(uint256).max);
        token1.approve(address(mintHelper), type(uint256).max);
        mintHelper.mint(extPool, address(this), TICK_LOWER, TICK_UPPER, LIQUIDITY_AMOUNT);

        hook = _deployHook(slipFactory);

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: IUniswapV3Pool(extPool).tickSpacing(),
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();

        poolManager.initialize(poolKey, SQRT_PRICE_1_1);

        token0.mint(alice, type(uint128).max);
        token1.mint(alice, type(uint128).max);
        token0.mint(address(poolManager), type(uint128).max);
        token1.mint(address(poolManager), type(uint128).max);
        token0.mint(extPool, type(uint128).max);
        token1.mint(extPool, type(uint128).max);

        vm.startPrank(alice);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _deployHook(address slipFactory) internal returns (SlipstreamAggregator) {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );
        bytes memory constructorArgs = abi.encode(poolManager, slipFactory);
        (, bytes32 salt) =
            HookMiner.find(address(this), flags, type(SlipstreamAggregator).creationCode, constructorArgs);
        return new SlipstreamAggregator{salt: salt}(poolManager, slipFactory);
    }

    function testFuzz_swapExactIn_zeroForOne(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e12, 1e17);
        uint256 expectedOut = hook.quote(true, -int256(amountIn), poolId);

        uint256 t1Before = token1.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(token1.balanceOf(alice) - t1Before, expectedOut);
    }

    function testFuzz_swapExactOut_zeroForOne(uint256 amountOut) public {
        amountOut = bound(amountOut, 1e12, 1e17);
        uint256 expectedIn = hook.quote(true, int256(amountOut), poolId);

        uint256 t0Before = token0.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MIN_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(t0Before - token0.balanceOf(alice), expectedIn);
    }

    function testFuzz_swapExactIn_oneForZero(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e12, 1e17);
        uint256 expectedOut = hook.quote(false, -int256(amountIn), poolId);

        uint256 t0Before = token0.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MAX_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(token0.balanceOf(alice) - t0Before, expectedOut);
    }

    function testFuzz_swapExactOut_oneForZero(uint256 amountOut) public {
        amountOut = bound(amountOut, 1e12, 1e17);
        uint256 expectedIn = hook.quote(false, int256(amountOut), poolId);

        uint256 t1Before = token1.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MAX_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(t1Before - token1.balanceOf(alice), expectedIn);
    }

    receive() external payable {}
}
