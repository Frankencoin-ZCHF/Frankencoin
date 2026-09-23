// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SafePoolSwapTest} from "./shared/SafePoolSwapTest.sol";
import {MockExternalLiqSource} from "./mocks/MockExternalLiqSource.sol";
import {MockAggregatorHook} from "./mocks/MockAggregatorHook.sol";
import {MockV4FeeAdapter} from "./mocks/MockV4FeeAdapter.sol";
import {HookMiner} from "../../src/utils/HookMiner.sol";
import {BaseAggregatorHook} from "../../src/aggregator-hooks/BaseAggregatorHook.sol";
import {IAggregatorHook} from "../../src/aggregator-hooks/interfaces/IAggregatorHook.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

contract BaseAggregatorHookUnitTest is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager public poolManager;
    SafePoolSwapTest public swapRouter;
    PoolModifyLiquidityTest public modifyLiquidityRouter;
    MockExternalLiqSource public externalSource;
    MockAggregatorHook public hook;
    MockV4FeeAdapter public feeAdapter;
    MockERC20 public token0;
    MockERC20 public token1;

    // Pool configuration
    uint24 constant FEE = 3000; // 0.3% fee
    int24 constant TICK_SPACING = 60; // Default tick spacing for a 0.3% fee pool
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 1:1 price

    uint160 constant MIN_PRICE = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE = TickMath.MAX_SQRT_PRICE - 1;
    uint256 public constant INITIAL_BALANCE = 1000 ether;

    address public alice = makeAddr("alice");
    address public tokenJar = makeAddr("tokenJar");
    PoolKey public poolKey;
    PoolId public poolId;

    function setUp() public {
        poolManager =
            IPoolManager(vm.deployCode("foundry-out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        swapRouter = new SafePoolSwapTest(poolManager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(poolManager);
        externalSource = new MockExternalLiqSource();
        feeAdapter = new MockV4FeeAdapter(poolManager, tokenJar);

        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        if (address(token0) > address(token1)) (token0, token1) = (token1, token0);

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );
        bytes memory constructorArgs = abi.encode(poolManager, externalSource);
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(MockAggregatorHook).creationCode, constructorArgs);
        hook = new MockAggregatorHook{salt: salt}(IPoolManager(address(poolManager)), externalSource);

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, SQRT_PRICE_1_1);
        poolManager.setProtocolFeeController(address(feeAdapter));

        token0.mint(alice, INITIAL_BALANCE);
        token1.mint(alice, INITIAL_BALANCE);
        token0.mint(address(poolManager), INITIAL_BALANCE);
        token1.mint(address(poolManager), INITIAL_BALANCE);
        vm.startPrank(alice);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
    }

    function test_revertAddLiquidity() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(IAggregatorHook.LiquidityNotAllowed.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1000e18, salt: bytes32(0)}),
            ""
        );
    }

    function test_getHookPermissions() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap);
        assertTrue(p.beforeSwapReturnDelta);
        assertTrue(p.beforeInitialize);
        assertTrue(p.beforeAddLiquidity);
    }

    function test_beforeInitialize_emitsAggregatorPoolRegistered() public {
        // Already initialized in setUp; event was emitted. Verify by initializing another pool.
        MockExternalLiqSource src2 = new MockExternalLiqSource();
        bytes memory args = abi.encode(IPoolManager(address(poolManager)), src2);
        (, bytes32 salt2) = HookMiner.find(
            address(this),
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                    | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            ),
            type(MockAggregatorHook).creationCode,
            args
        );
        MockAggregatorHook hook2 = new MockAggregatorHook{salt: salt2}(IPoolManager(address(poolManager)), src2);
        PoolKey memory key2 = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE + 1,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook2))
        });
        vm.expectEmit(true, true, true, true);
        emit IAggregatorHook.AggregatorPoolRegistered(key2.toId());
        poolManager.initialize(key2, SQRT_PRICE_1_1);
    }

    function test_beforeSwap_exactIn() public {
        uint256 amountIn = 100 ether;
        uint256 amountOut = 95 ether;
        externalSource.setReturns(amountOut, amountIn, false);
        token1.mint(address(hook), amountOut);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(token0.balanceOf(alice), INITIAL_BALANCE - amountIn);
        assertEq(token1.balanceOf(alice), INITIAL_BALANCE + amountOut);
    }

    /// @dev PoolManager passes `msg.sender` into the hook (the swap router), not the end user.
    function test_beforeSwap_emitsHookSwap_exactIn() public {
        uint256 amountIn = 100 ether;
        uint256 amountOut = 95 ether;
        externalSource.setReturns(amountOut, amountIn, false);
        token1.mint(address(hook), amountOut);

        vm.expectEmit(true, true, false, true, address(hook));
        emit IAggregatorHook.HookSwap(poolId, address(swapRouter), int256(amountIn), -int256(amountOut), 0);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_beforeSwap_emitsHookSwap_exactOut() public {
        uint256 amountOut = 50 ether;
        uint256 amountIn = 55 ether;
        externalSource.setReturns(amountOut, amountIn, false);
        token0.mint(address(hook), amountIn);

        vm.expectEmit(true, true, false, true, address(hook));
        emit IAggregatorHook.HookSwap(poolId, address(swapRouter), -int256(amountOut), int256(amountIn), 0);
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MAX_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_beforeSwap_exactOut() public {
        uint256 amountOut = 50 ether;
        uint256 amountIn = 55 ether;
        externalSource.setReturns(amountOut, amountIn, false);
        token0.mint(address(hook), amountIn);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MAX_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // oneForZero exact-out: alice pays token1 (amountIn), receives token0 (amountOut)
        assertEq(token0.balanceOf(alice), INITIAL_BALANCE + amountOut);
        assertEq(token1.balanceOf(alice), INITIAL_BALANCE - amountIn);
    }

    function test_pollTokenJar_unsetFeeController() public {
        poolManager.setProtocolFeeController(address(0));
        hook.pollTokenJar();
        assertEq(hook.tokenJar(), address(0));
    }

    function test_pollTokenJar_invalidFeeController() public {
        poolManager.setProtocolFeeController(makeAddr("invalidTokenJar"));
        hook.pollTokenJar();
        assertEq(hook.tokenJar(), address(0));
    }

    function test_receive_acceptsEth() public {
        uint256 sent = 1 ether;
        (bool ok,) = address(hook).call{value: sent}("");
        assertTrue(ok);
        assertEq(address(hook).balance, sent);
    }

    function test_quote_returnsMockValue() public {
        hook.setMockQuoteReturn(12345);
        uint256 q = hook.quote(true, -int256(100 ether), poolId);
        assertEq(q, 12345);
    }

    function test_pseudoTotalValueLocked_returnsMockValues() public {
        hook.setMockPseudoTVL(1000 ether, 2000 ether);
        (uint256 a0, uint256 a1) = hook.pseudoTotalValueLocked(poolId);
        assertEq(a0, 1000 ether);
        assertEq(a1, 2000 ether);
    }

    /// @dev Packs a single-direction fee into the V4 protocol fee format for both directions
    function _packFee(uint24 fee) internal pure returns (uint24) {
        return (fee << 12) | fee;
    }

    /// @dev Sets the protocol fee on the pool via poolManager.setProtocolFee
    function _setProtocolFee(uint24 fee) internal {
        vm.prank(address(feeAdapter));
        poolManager.setProtocolFee(poolKey, _packFee(fee));
    }

    function test_protocolFee_exactIn_zeroForOne() public {
        uint24 fee = 500; // 500 pips = 0.05%
        _setProtocolFee(fee);

        uint256 amountIn = 100 ether;
        uint256 amountOut = 95 ether;
        externalSource.setReturns(amountOut, amountIn, false);
        token1.mint(address(hook), amountOut);

        uint256 expectedFee = FullMath.mulDivRoundingUp(amountOut, fee * 25, ProtocolFeeLibrary.PIPS_DENOMINATOR);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Alice pays full amountIn, receives (amountOut - fee)
        assertEq(token0.balanceOf(alice), INITIAL_BALANCE - amountIn, "alice token0 balance");
        assertEq(token1.balanceOf(alice), INITIAL_BALANCE + amountOut - expectedFee, "alice token1 balance");
        // Token jar receives the protocol fee
        assertEq(token1.balanceOf(tokenJar), expectedFee, "tokenJar fee balance");
    }

    function test_protocolFee_exactIn_oneForZero() public {
        uint24 fee = 500;
        _setProtocolFee(fee);

        uint256 amountIn = 100 ether;
        uint256 amountOut = 95 ether;
        externalSource.setReturns(amountOut, amountIn, false);
        token0.mint(address(hook), amountOut);

        uint256 expectedFee = FullMath.mulDivRoundingUp(amountOut, fee * 25, ProtocolFeeLibrary.PIPS_DENOMINATOR);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MAX_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Alice pays full amountIn of token1, receives (amountOut - fee) of token0
        assertEq(token1.balanceOf(alice), INITIAL_BALANCE - amountIn, "alice token1 balance");
        assertEq(token0.balanceOf(alice), INITIAL_BALANCE + amountOut - expectedFee, "alice token0 balance");
        // Token jar receives the protocol fee in token0 (unspecified side)
        assertEq(token0.balanceOf(tokenJar), expectedFee, "tokenJar fee balance");
    }

    function test_protocolFee_exactOut_zeroForOne() public {
        uint24 fee = 500;
        _setProtocolFee(fee);

        uint256 amountOut = 50 ether;
        uint256 amountIn = 55 ether;
        externalSource.setReturns(amountOut, amountIn, false);
        token0.mint(address(hook), amountIn);

        // For exact-out, fee = amountIn * protocolFee / (PIPS_DENOMINATOR - protocolFee)
        uint256 expectedFee =
            FullMath.mulDivRoundingUp(amountIn, fee * 25, ProtocolFeeLibrary.PIPS_DENOMINATOR - fee * 25);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MAX_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Alice receives amountOut of token0, pays (amountIn + fee) of token1
        assertEq(token0.balanceOf(alice), INITIAL_BALANCE + amountOut, "alice token0 balance");
        assertEq(token1.balanceOf(alice), INITIAL_BALANCE - amountIn - expectedFee, "alice token1 balance");
        // Token jar receives the protocol fee in token1 (unspecified side)
        assertEq(token1.balanceOf(tokenJar), expectedFee, "tokenJar fee balance");
    }

    function test_protocolFee_exactOut_oneForZero() public {
        uint24 fee = 500;
        _setProtocolFee(fee);

        uint256 amountOut = 50 ether;
        uint256 amountIn = 55 ether;
        externalSource.setReturns(amountOut, amountIn, false);
        token1.mint(address(hook), amountIn);

        uint256 expectedFee =
            FullMath.mulDivRoundingUp(amountIn, fee * 25, ProtocolFeeLibrary.PIPS_DENOMINATOR - fee * 25);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MIN_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Alice receives amountOut of token1, pays (amountIn + fee) of token0
        assertEq(token1.balanceOf(alice), INITIAL_BALANCE + amountOut, "alice token1 balance");
        assertEq(token0.balanceOf(alice), INITIAL_BALANCE - amountIn - expectedFee, "alice token0 balance");
        // Token jar receives the protocol fee in token0 (unspecified side)
        assertEq(token0.balanceOf(tokenJar), expectedFee, "tokenJar fee balance");
    }

    function test_protocolFee_zeroFee_noFeeDeducted() public {
        // Protocol fee is 0 (default) — no fee should be taken
        uint256 amountIn = 100 ether;
        uint256 amountOut = 95 ether;
        externalSource.setReturns(amountOut, amountIn, false);
        token1.mint(address(hook), amountOut);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(token0.balanceOf(alice), INITIAL_BALANCE - amountIn);
        assertEq(token1.balanceOf(alice), INITIAL_BALANCE + amountOut);
        assertEq(token1.balanceOf(tokenJar), 0, "no fee should go to tokenJar");
    }

    // ────────────────────── Max Protocol Fee Test ───────────────────────────

    function test_protocolFee_maxFee_exactIn() public {
        uint24 maxFee = ProtocolFeeLibrary.MAX_PROTOCOL_FEE; // 1000 pips = 0.1%
        _setProtocolFee(maxFee);

        uint256 amountIn = 100 ether;
        uint256 amountOut = 95 ether;
        externalSource.setReturns(amountOut, amountIn, false);
        token1.mint(address(hook), amountOut);

        uint256 expectedFee = FullMath.mulDivRoundingUp(amountOut, maxFee * 25, ProtocolFeeLibrary.PIPS_DENOMINATOR);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(token0.balanceOf(alice), INITIAL_BALANCE - amountIn, "alice token0 balance");
        assertEq(token1.balanceOf(alice), INITIAL_BALANCE + amountOut - expectedFee, "alice token1 balance");
        assertEq(token1.balanceOf(tokenJar), expectedFee, "tokenJar fee balance at max");
    }

    function test_protocolFee_noFeeAdapter_swapSucceeds() public {
        // Clear the protocol fee controller so _getTokenJar() returns address(0)
        poolManager.setProtocolFeeController(address(0));

        uint256 amountIn = 100 ether;
        uint256 amountOut = 95 ether;
        externalSource.setReturns(amountOut, amountIn, false);
        token1.mint(address(hook), amountOut);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Full output, no fee deducted
        assertEq(token0.balanceOf(alice), INITIAL_BALANCE - amountIn, "alice token0 balance");
        assertEq(token1.balanceOf(alice), INITIAL_BALANCE + amountOut, "alice token1 balance");
        assertEq(token1.balanceOf(tokenJar), 0, "no fee should go to tokenJar");
    }

    function test_protocolFee_invalidFeeAdapter_swapSucceeds() public {
        // Set an invalid protocol fee controller so _getTokenJar() returns address(0)
        poolManager.setProtocolFeeController(makeAddr("invalid"));

        uint256 amountIn = 100 ether;
        uint256 amountOut = 95 ether;
        externalSource.setReturns(amountOut, amountIn, false);
        token1.mint(address(hook), amountOut);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Full output, no fee deducted
        assertEq(token0.balanceOf(alice), INITIAL_BALANCE - amountIn, "alice token0 balance");
        assertEq(token1.balanceOf(alice), INITIAL_BALANCE + amountOut, "alice token1 balance");
        assertEq(token1.balanceOf(tokenJar), 0, "no fee should go to tokenJar");
    }

    function test_protocolFee_asymmetricDirections() public {
        // Set different fees per direction: 500 for zeroForOne, 200 for oneForZero
        uint24 zeroForOneFee = 500;
        uint24 oneForZeroFee = 200;
        uint24 packed = (oneForZeroFee << 12) | zeroForOneFee;
        vm.prank(address(feeAdapter));
        poolManager.setProtocolFee(poolKey, packed);

        // --- zeroForOne swap ---
        {
            uint256 amountIn = 100 ether;
            uint256 amountOut = 95 ether;
            externalSource.setReturns(amountOut, amountIn, false);
            token1.mint(address(hook), amountOut);

            uint256 expectedFee =
                FullMath.mulDivRoundingUp(amountOut, zeroForOneFee * 25, ProtocolFeeLibrary.PIPS_DENOMINATOR);

            vm.prank(alice);
            swapRouter.swap(
                poolKey,
                SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_PRICE}),
                SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );

            assertEq(token1.balanceOf(tokenJar), expectedFee, "tokenJar zeroForOne fee");
        }

        // Reset token jar balance tracking by recording it
        uint256 tokenJarToken0Before = token0.balanceOf(tokenJar);

        // --- oneForZero swap ---
        {
            uint256 amountIn = 100 ether;
            uint256 amountOut = 95 ether;
            externalSource.setReturns(amountOut, amountIn, false);
            token0.mint(address(hook), amountOut);

            uint256 expectedFee =
                FullMath.mulDivRoundingUp(amountOut, oneForZeroFee * 25, ProtocolFeeLibrary.PIPS_DENOMINATOR);

            vm.prank(alice);
            swapRouter.swap(
                poolKey,
                SwapParams({zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MAX_PRICE}),
                SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );

            assertEq(token0.balanceOf(tokenJar) - tokenJarToken0Before, expectedFee, "tokenJar oneForZero fee");
        }
    }
}
