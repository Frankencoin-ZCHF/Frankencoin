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
import {UniswapV2Aggregator} from "../../../src/aggregator-hooks/implementations/UniswapV2/UniswapV2Aggregator.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair as IUniV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

/// @notice Fuzz against canonical Uniswap V2 factory bytecode from `precompile/` (same pattern as UniswapV3AggregatorFuzz).
contract UniswapV2AggregatorFuzz is Test {
    using PoolIdLibrary for PoolKey;

    string constant FACTORY_BYTECODE_PATH = "test/aggregator-hooks/UniswapV2/precompile/UniswapV2Factory.bin";

    uint24 constant POOL_FEE = 3000;
    int24 constant TICK_SPACING = 1;

    IPoolManager public poolManager;
    SafePoolSwapTest public swapRouter;
    IUniswapV2Factory public factory;
    address public pair;
    UniswapV2Aggregator public hook;

    MockERC20 public token0;
    MockERC20 public token1;

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

        factory = IUniswapV2Factory(_deployV2FactoryFromPrecompile());

        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        if (address(token0) > address(token1)) (token0, token1) = (token1, token0);

        pair = factory.createPair(address(token0), address(token1));

        hook = _deployHook();

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();

        poolManager.initialize(poolKey, SQRT_PRICE_1_1);

        token0.mint(alice, type(uint128).max);
        token1.mint(alice, type(uint128).max);
        token0.mint(address(poolManager), type(uint128).max);
        token1.mint(address(poolManager), type(uint128).max);

        uint256 liq0 = 500_000 ether;
        uint256 liq1 = 500_000 ether;
        token0.mint(address(this), liq0);
        token1.mint(address(this), liq1);
        token0.transfer(pair, liq0);
        token1.transfer(pair, liq1);
        IUniV2Pair(pair).mint(alice);

        vm.startPrank(alice);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _deployV2FactoryFromPrecompile() internal returns (address deployed) {
        bytes memory code = vm.parseBytes(vm.readFile(FACTORY_BYTECODE_PATH));
        require(code.length > 0, "Empty UniswapV2Factory bytecode");
        bytes memory creation = abi.encodePacked(code, abi.encode(address(this)));
        assembly {
            deployed := create(0, add(creation, 0x20), mload(creation))
        }
        require(deployed != address(0) && deployed.code.length > 0, "UniswapV2Factory CREATE failed");
    }

    function _deployHook() internal returns (UniswapV2Aggregator) {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );
        bytes memory constructorArgs =
            abi.encode(poolManager, address(factory), uint256(3000), "UniswapV2Aggregator v1.0");
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(UniswapV2Aggregator).creationCode, constructorArgs);
        return new UniswapV2Aggregator{salt: salt}(poolManager, address(factory), 3000, "UniswapV2Aggregator v1.0");
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
