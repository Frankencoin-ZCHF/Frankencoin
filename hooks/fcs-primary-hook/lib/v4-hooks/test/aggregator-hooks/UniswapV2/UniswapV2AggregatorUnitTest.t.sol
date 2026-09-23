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

/// @dev Canonical Uniswap V2 factory creation code from `lib/v2-core` (same pattern as UniswapV3AggregatorFuzz precompiles).
/// @dev Heavy external-integration suite; pinned low to keep CI fast (global default is raised in foundry.toml).
/// forge-config: default.fuzz.runs = 10
contract UniswapV2AggregatorUnitTest is Test {
    using PoolIdLibrary for PoolKey;

    /// @dev Hex file from `lib/v2-core` `UniswapV2Factory` creation bytecode (`bytecode.object` in Foundry artifact).
    ///      Regenerate after upgrading `lib/v2-core`: compile the factory, then write `bytecode.object` to this path (no trailing newline).
    string constant FACTORY_BYTECODE_PATH = "test/aggregator-hooks/UniswapV2/precompile/UniswapV2Factory.bin";

    IPoolManager public poolManager;
    SafePoolSwapTest public swapRouter;
    IUniswapV2Factory public factory;
    address public pair;
    UniswapV2Aggregator public hook;

    MockERC20 public token0;
    MockERC20 public token1;

    uint24 constant POOL_FEE = 3000;
    int24 constant TICK_SPACING_A = 1;
    int24 constant TICK_SPACING_B = 1;

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
            tickSpacing: TICK_SPACING_A,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();

        poolManager.initialize(poolKey, SQRT_PRICE_1_1);

        token0.mint(alice, 1000 ether);
        token1.mint(alice, 1000 ether);
        token0.mint(address(poolManager), 1000 ether);
        token1.mint(address(poolManager), 1000 ether);

        // Canonical V2 liquidity
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

    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert UniswapV2Aggregator.AmountInZero();
        if (reserveIn == 0 || reserveOut == 0) revert UniswapV2Aggregator.InsufficientLiquidity();
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    function _getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountIn)
    {
        if (amountOut == 0) revert UniswapV2Aggregator.AmountOutZero();
        if (reserveIn == 0 || reserveOut == 0) revert UniswapV2Aggregator.InsufficientLiquidity();
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;
        amountIn = numerator / denominator + 1;
    }

    /// @notice `readFile` + `parseBytes` + CREATE; appends `abi.encode(feeToSetter)` for `UniswapV2Factory(address)`.
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

    function _expectedQuote(bool zeroForOne, int256 amountSpecified) internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = IUniV2Pair(pair).getReserves();
        if (amountSpecified < 0) {
            uint256 amtIn = uint256(-amountSpecified);
            if (zeroForOne) return _getAmountOut(amtIn, uint256(r0), uint256(r1));
            return _getAmountOut(amtIn, uint256(r1), uint256(r0));
        } else {
            uint256 amtOut = uint256(amountSpecified);
            if (zeroForOne) return _getAmountIn(amtOut, uint256(r0), uint256(r1));
            return _getAmountIn(amtOut, uint256(r1), uint256(r0));
        }
    }

    function test_quote_exactIn_matches_math() public {
        uint256 expected = _expectedQuote(true, -int256(100 ether));
        uint256 q = hook.quote(true, -int256(100 ether), poolId);
        assertEq(q, expected);
    }

    function test_quote_exactOut_matches_math() public {
        uint256 amtOut = 95 ether;
        uint256 expected = _expectedQuote(true, int256(amtOut));
        uint256 q = hook.quote(true, int256(amtOut), poolId);
        assertEq(q, expected);
    }

    function test_quote_exactIn_matches_math_oneForZero() public {
        uint256 expected = _expectedQuote(false, -int256(100 ether));
        uint256 q = hook.quote(false, -int256(100 ether), poolId);
        assertEq(q, expected);
    }

    function test_quote_exactOut_matches_math_oneForZero() public {
        uint256 amtOut = 95 ether;
        uint256 expected = _expectedQuote(false, int256(amtOut));
        uint256 q = hook.quote(false, int256(amtOut), poolId);
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

    function test_swapExactOutput_zeroForOne() public {
        uint256 amountOut = 95 ether;
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

    function test_swapExactOutput_oneForZero() public {
        uint256 amountOut = 95 ether;
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

        // A second pair registers as a second entry
        factory.createPair(sorted0, sorted1);

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

    function test_secondInitialize_same_external_pair_reverts() public {
        PoolKey memory key2 = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING_B,
            hooks: IHooks(address(hook))
        });

        vm.expectRevert();
        poolManager.initialize(key2, SQRT_PRICE_1_1);
    }

    function test_pseudoTotalValueLocked_nonZero() public view {
        (uint256 a0, uint256 a1) = hook.pseudoTotalValueLocked(poolId);
        assertTrue(a0 > 0 || a1 > 0);
    }

    receive() external payable {}
}
