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
import {WETH} from "solmate/src/tokens/WETH.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";
import {SafePoolSwapTest} from "../shared/SafePoolSwapTest.sol";
import {UniswapXAggregator} from "../../../src/aggregator-hooks/implementations/UniswapX/UniswapXAggregator.sol";
import {IReactor} from "@uniswapx/interfaces/IReactor.sol";
import {ResolvedOrder, SignedOrder} from "@uniswapx/base/ReactorStructs.sol";
import {MockUniswapXReactor} from "./mocks/MockUniswapXReactor.sol";
import {MockMaliciousUniswapXReactor} from "./mocks/MockMaliciousUniswapXReactor.sol";
import {MockV4FeeAdapter} from "../mocks/MockV4FeeAdapter.sol";
import {BaseHookDataAggregator} from "../../../src/aggregator-hooks/BaseHookDataAggregator.sol";

contract UniswapXAggregatorUnitTest is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager public poolManager;
    SafePoolSwapTest public swapRouter;
    MockUniswapXReactor public reactor;
    WETH public weth;
    UniswapXAggregator public hook;

    MockERC20 public tokenA; // order input token
    MockERC20 public tokenB; // order output token
    MockERC20 public usdc;

    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant MIN_PRICE = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE = TickMath.MAX_SQRT_PRICE - 1;

    Currency constant NATIVE = Currency.wrap(address(0));

    address public maker = makeAddr("maker"); // UniswapX order swapper
    address public alice = makeAddr("alice"); // V4 swapper
    address public tokenJar = makeAddr("tokenJar"); // receives swap-vs-order surplus

    function setUp() public {
        poolManager =
            IPoolManager(vm.deployCode("foundry-out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        swapRouter = new SafePoolSwapTest(poolManager);
        reactor = new MockUniswapXReactor();
        weth = new WETH();
        poolManager.setProtocolFeeController(address(new MockV4FeeAdapter(poolManager, tokenJar)));

        hook = _deployHook(address(reactor));

        tokenA = new MockERC20("TokenA", "TKA", 18);
        tokenB = new MockERC20("TokenB", "TKB", 18);
        usdc = new MockERC20("USDC", "USDC", 6);
    }

    function _deployHook(address reactorAddr) internal returns (UniswapXAggregator) {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );
        bytes memory constructorArgs = abi.encode(poolManager, IReactor(reactorAddr), address(weth));
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(UniswapXAggregator).creationCode, constructorArgs);
        return new UniswapXAggregator{salt: salt}(poolManager, IReactor(reactorAddr), address(weth));
    }

    function _initPool(Currency c0, Currency c1) internal returns (PoolKey memory key) {
        return _initPoolWithHook(c0, c1, hook);
    }

    function _initPoolWithHook(Currency c0, Currency c1, UniswapXAggregator hook_)
        internal
        returns (PoolKey memory key)
    {
        (Currency currency0, Currency currency1) = Currency.unwrap(c0) < Currency.unwrap(c1) ? (c0, c1) : (c1, c0);
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook_))
        });
        poolManager.initialize(key, SQRT_PRICE_1_1);
    }

    /// @dev Build the SignedOrder hookData for an order: maker gives `inAmt` of `inTok`, wants `outAmt` of `outTok`.
    function _order(address inTok, uint256 inAmt, address outTok, uint256 outAmt) internal view returns (bytes memory) {
        MockUniswapXReactor.MockOrder memory o = MockUniswapXReactor.MockOrder({
            swapper: maker,
            inputToken: inTok,
            inputAmount: inAmt,
            outputToken: outTok,
            outputAmount: outAmt,
            outputRecipient: maker
        });
        return abi.encode(SignedOrder({order: abi.encode(o), sig: ""}));
    }

    /// @dev Compute the swap direction so that `take` (alice's input) is the order output and `settle` is the input.
    function _zeroForOne(PoolKey memory key, Currency takeCurrency) internal pure returns (bool) {
        return Currency.unwrap(takeCurrency) == Currency.unwrap(key.currency0);
    }

    // ─────────────────────────── ERC20 / ERC20 ───────────────────────────

    function test_fillOrder_exactIn_erc20() public {
        uint256 inAmt = 100 ether; // maker gives tokenA
        uint256 outAmt = 99 ether; // maker wants tokenB

        PoolKey memory key = _initPool(Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)));

        // maker funds + approves the reactor for the order input
        tokenA.mint(maker, inAmt);
        vm.prank(maker);
        tokenA.approve(address(reactor), type(uint256).max);

        // PoolManager float so the hook can take tokenB before alice settles
        tokenB.mint(address(poolManager), 1000 ether);

        // alice (v4 swapper) provides tokenB
        tokenB.mint(alice, outAmt);
        vm.prank(alice);
        tokenB.approve(address(swapRouter), type(uint256).max);

        Currency takeCurrency = Currency.wrap(address(tokenB));
        bytes memory hookData = _order(address(tokenA), inAmt, address(tokenB), outAmt);

        vm.prank(alice);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: _zeroForOne(key, takeCurrency),
                amountSpecified: -int256(outAmt),
                sqrtPriceLimitX96: _zeroForOne(key, takeCurrency) ? MIN_PRICE : MAX_PRICE
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );

        assertEq(tokenA.balanceOf(maker), 0, "maker spent input");
        assertEq(tokenB.balanceOf(maker), outAmt, "maker received output");
        assertEq(tokenB.balanceOf(alice), 0, "alice spent tokenB");
        assertEq(tokenA.balanceOf(alice), inAmt, "alice received tokenA");
        assertEq(tokenA.balanceOf(address(hook)), 0, "hook holds no tokenA");
        assertEq(tokenB.balanceOf(address(hook)), 0, "hook holds no tokenB");
    }

    function test_fillOrder_exactOut_erc20() public {
        uint256 inAmt = 100 ether;
        uint256 outAmt = 99 ether;

        PoolKey memory key = _initPool(Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)));

        tokenA.mint(maker, inAmt);
        vm.prank(maker);
        tokenA.approve(address(reactor), type(uint256).max);

        tokenB.mint(address(poolManager), 1000 ether);
        tokenB.mint(alice, outAmt);
        vm.prank(alice);
        tokenB.approve(address(swapRouter), type(uint256).max);

        Currency takeCurrency = Currency.wrap(address(tokenB));
        bytes memory hookData = _order(address(tokenA), inAmt, address(tokenB), outAmt);

        // Exact-out: alice specifies the desired output amount (the order's input amount)
        vm.prank(alice);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: _zeroForOne(key, takeCurrency),
                amountSpecified: int256(inAmt),
                sqrtPriceLimitX96: _zeroForOne(key, takeCurrency) ? MIN_PRICE : MAX_PRICE
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );

        assertEq(tokenB.balanceOf(maker), outAmt, "maker received output");
        assertEq(tokenA.balanceOf(alice), inAmt, "alice received exact tokenA");
        assertEq(tokenB.balanceOf(alice), 0, "alice spent tokenB");
    }

    function test_fillOrder_amountMismatch_reverts() public {
        uint256 inAmt = 100 ether;
        uint256 outAmt = 99 ether;

        PoolKey memory key = _initPool(Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)));

        tokenA.mint(maker, inAmt);
        vm.prank(maker);
        tokenA.approve(address(reactor), type(uint256).max);
        tokenB.mint(address(poolManager), 1000 ether);
        tokenB.mint(alice, outAmt);
        vm.prank(alice);
        tokenB.approve(address(swapRouter), type(uint256).max);

        Currency takeCurrency = Currency.wrap(address(tokenB));
        bytes memory hookData = _order(address(tokenA), inAmt, address(tokenB), outAmt);

        // Ask for an exact-in amount below the order's required output → the input cannot cover the fill.
        vm.prank(alice);
        vm.expectRevert();
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: _zeroForOne(key, takeCurrency),
                amountSpecified: -int256(50 ether),
                sqrtPriceLimitX96: _zeroForOne(key, takeCurrency) ? MIN_PRICE : MAX_PRICE
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    /// @dev Exact-in may over-provide input: the swapper pays the full specified amount, the order fills at its
    ///      resolved amounts, and the surplus input is forwarded to the token jar.
    function test_fillOrder_exactIn_surplusInput() public {
        uint256 inAmt = 100 ether; // maker gives tokenA
        uint256 outAmt = 99 ether; // maker wants tokenB
        uint256 specified = 110 ether; // alice provides more than the order requires

        PoolKey memory key = _initPool(Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)));

        tokenA.mint(maker, inAmt);
        vm.prank(maker);
        tokenA.approve(address(reactor), type(uint256).max);
        tokenB.mint(address(poolManager), 1000 ether);
        tokenB.mint(alice, specified);
        vm.prank(alice);
        tokenB.approve(address(swapRouter), type(uint256).max);

        Currency takeCurrency = Currency.wrap(address(tokenB));
        bytes memory hookData = _order(address(tokenA), inAmt, address(tokenB), outAmt);

        vm.prank(alice);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: _zeroForOne(key, takeCurrency),
                amountSpecified: -int256(specified),
                sqrtPriceLimitX96: _zeroForOne(key, takeCurrency) ? MIN_PRICE : MAX_PRICE
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );

        assertEq(tokenB.balanceOf(maker), outAmt, "maker received the order output");
        assertEq(tokenB.balanceOf(alice), 0, "alice paid her full specified input");
        assertEq(tokenA.balanceOf(alice), inAmt, "alice received the order input");
        assertEq(tokenB.balanceOf(tokenJar), specified - outAmt, "surplus input went to the token jar");
        assertEq(tokenB.balanceOf(address(hook)), 0, "hook holds no surplus");
        assertEq(tokenA.balanceOf(address(hook)), 0, "hook holds no order input");
    }

    /// @dev Exact-out may under-request: the swapper receives exactly the requested amount, pays the order's
    ///      full output, and the order's surplus input is forwarded to the token jar.
    function test_fillOrder_exactOut_underRequest() public {
        uint256 inAmt = 100 ether; // maker gives tokenA
        uint256 outAmt = 99 ether; // maker wants tokenB
        uint256 requested = 90 ether; // alice requests less than the order supplies

        PoolKey memory key = _initPool(Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)));

        tokenA.mint(maker, inAmt);
        vm.prank(maker);
        tokenA.approve(address(reactor), type(uint256).max);
        tokenB.mint(address(poolManager), 1000 ether);
        tokenB.mint(alice, outAmt);
        vm.prank(alice);
        tokenB.approve(address(swapRouter), type(uint256).max);

        Currency takeCurrency = Currency.wrap(address(tokenB));
        bytes memory hookData = _order(address(tokenA), inAmt, address(tokenB), outAmt);

        vm.prank(alice);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: _zeroForOne(key, takeCurrency),
                amountSpecified: int256(requested),
                sqrtPriceLimitX96: _zeroForOne(key, takeCurrency) ? MIN_PRICE : MAX_PRICE
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );

        assertEq(tokenB.balanceOf(maker), outAmt, "maker received the order output");
        assertEq(tokenB.balanceOf(alice), 0, "alice paid the order's full output");
        assertEq(tokenA.balanceOf(alice), requested, "alice received exactly the requested amount");
        assertEq(tokenA.balanceOf(tokenJar), inAmt - requested, "surplus order input went to the token jar");
        assertEq(tokenA.balanceOf(address(hook)), 0, "hook holds no surplus");
        assertEq(tokenB.balanceOf(address(hook)), 0, "hook holds no swapper input");
    }

    function test_swap_withoutOrderData_reverts() public {
        PoolKey memory key = _initPool(Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)));
        tokenB.mint(alice, 99 ether);
        vm.prank(alice);
        tokenB.approve(address(swapRouter), type(uint256).max);

        Currency takeCurrency = Currency.wrap(address(tokenB));
        vm.prank(alice);
        vm.expectRevert();
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: _zeroForOne(key, takeCurrency),
                amountSpecified: -int256(99 ether),
                sqrtPriceLimitX96: _zeroForOne(key, takeCurrency) ? MIN_PRICE : MAX_PRICE
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            "" // no order
        );
    }

    /// @dev A single deployed hook instance must be usable as the hook for many independent V4 pools at once —
    ///      there is no per-hook, single-pool restriction (and thus no need for a one-hook-per-pool factory).
    function test_singleHookInstance_servesMultiplePoolsConcurrently() public {
        PoolKey memory poolAB = _initPool(Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)));
        PoolKey memory poolAC = _initPool(Currency.wrap(address(tokenA)), Currency.wrap(address(usdc)));

        // Both pools share one hook instance; the test proves concurrent use by filling an order through each.

        // Fill an order through poolAB.
        uint256 inAmtAB = 100 ether;
        uint256 outAmtAB = 99 ether;
        tokenA.mint(maker, inAmtAB);
        vm.prank(maker);
        tokenA.approve(address(reactor), type(uint256).max);
        tokenB.mint(address(poolManager), 1000 ether);
        tokenB.mint(alice, outAmtAB);
        vm.prank(alice);
        tokenB.approve(address(swapRouter), type(uint256).max);

        Currency takeAB = Currency.wrap(address(tokenB));
        vm.prank(alice);
        swapRouter.swap(
            poolAB,
            SwapParams({
                zeroForOne: _zeroForOne(poolAB, takeAB),
                amountSpecified: -int256(outAmtAB),
                sqrtPriceLimitX96: _zeroForOne(poolAB, takeAB) ? MIN_PRICE : MAX_PRICE
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            _order(address(tokenA), inAmtAB, address(tokenB), outAmtAB)
        );
        assertEq(tokenB.balanceOf(maker), outAmtAB, "maker filled via pool A/B");

        // Fill a different order, for a different token pair, through poolAC on the very same hook instance.
        uint256 inAmtAC = 50 ether;
        uint256 outAmtAC = 200e6;
        tokenA.mint(maker, inAmtAC);
        vm.prank(maker);
        tokenA.approve(address(reactor), type(uint256).max);
        usdc.mint(address(poolManager), 10_000e6);
        usdc.mint(alice, outAmtAC);
        vm.prank(alice);
        usdc.approve(address(swapRouter), type(uint256).max);

        Currency takeAC = Currency.wrap(address(usdc));
        vm.prank(alice);
        swapRouter.swap(
            poolAC,
            SwapParams({
                zeroForOne: _zeroForOne(poolAC, takeAC),
                amountSpecified: -int256(outAmtAC),
                sqrtPriceLimitX96: _zeroForOne(poolAC, takeAC) ? MIN_PRICE : MAX_PRICE
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            _order(address(tokenA), inAmtAC, address(usdc), outAmtAC)
        );
        assertEq(usdc.balanceOf(maker), outAmtAC, "maker filled via pool A/C on the same hook instance");
    }

    // ─────────────────────────── ETH / WETH ───────────────────────────

    function test_fillOrder_orderOutputsWeth_wrapsNative() public {
        uint256 inAmt = 100e6; // maker gives USDC
        uint256 outAmt = 1 ether; // maker wants WETH

        PoolKey memory key = _initPool(NATIVE, Currency.wrap(address(usdc)));

        usdc.mint(maker, inAmt);
        vm.prank(maker);
        usdc.approve(address(reactor), type(uint256).max);

        // PoolManager native float so the hook can take ETH before alice settles
        vm.deal(address(poolManager), 100 ether);

        // alice provides native ETH
        vm.deal(alice, outAmt);

        Currency takeCurrency = NATIVE;
        bytes memory hookData = _order(address(usdc), inAmt, address(weth), outAmt);

        vm.prank(alice);
        swapRouter.swap{value: outAmt}(
            key,
            SwapParams({
                zeroForOne: _zeroForOne(key, takeCurrency),
                amountSpecified: -int256(outAmt),
                sqrtPriceLimitX96: _zeroForOne(key, takeCurrency) ? MIN_PRICE : MAX_PRICE
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );

        assertEq(usdc.balanceOf(maker), 0, "maker spent usdc");
        assertEq(weth.balanceOf(maker), outAmt, "maker received WETH");
        assertEq(alice.balance, 0, "alice spent ETH");
        assertEq(usdc.balanceOf(alice), inAmt, "alice received usdc");
        assertEq(address(hook).balance, 0, "hook holds no ETH");
        assertEq(weth.balanceOf(address(hook)), 0, "hook holds no WETH");
    }

    function test_fillOrder_orderOutputsNativeEth() public {
        uint256 inAmt = 100e6; // maker gives USDC
        uint256 outAmt = 1 ether; // maker wants native ETH

        PoolKey memory key = _initPool(NATIVE, Currency.wrap(address(usdc)));

        usdc.mint(maker, inAmt);
        vm.prank(maker);
        usdc.approve(address(reactor), type(uint256).max);

        vm.deal(address(poolManager), 100 ether);
        vm.deal(alice, outAmt);

        Currency takeCurrency = NATIVE;
        bytes memory hookData = _order(address(usdc), inAmt, address(0), outAmt);

        vm.prank(alice);
        swapRouter.swap{value: outAmt}(
            key,
            SwapParams({
                zeroForOne: _zeroForOne(key, takeCurrency),
                amountSpecified: -int256(outAmt),
                sqrtPriceLimitX96: _zeroForOne(key, takeCurrency) ? MIN_PRICE : MAX_PRICE
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );

        assertEq(usdc.balanceOf(maker), 0, "maker spent usdc");
        assertEq(maker.balance, outAmt, "maker received ETH");
        assertEq(usdc.balanceOf(alice), inAmt, "alice received usdc");
        assertEq(address(hook).balance, 0, "hook holds no ETH");
    }

    function test_fillOrder_orderInputsWeth_unwrapsToNative() public {
        uint256 inAmt = 1 ether; // maker gives WETH
        uint256 outAmt = 100e6; // maker wants USDC

        PoolKey memory key = _initPool(NATIVE, Currency.wrap(address(usdc)));

        // maker funds WETH and approves the reactor
        vm.deal(maker, inAmt);
        vm.prank(maker);
        weth.deposit{value: inAmt}();
        vm.prank(maker);
        weth.approve(address(reactor), type(uint256).max);

        // PoolManager USDC float so the hook can take it before alice settles
        usdc.mint(address(poolManager), 1000e6);

        // alice provides USDC
        usdc.mint(alice, outAmt);
        vm.prank(alice);
        usdc.approve(address(swapRouter), type(uint256).max);

        Currency takeCurrency = Currency.wrap(address(usdc));
        bytes memory hookData = _order(address(weth), inAmt, address(usdc), outAmt);

        uint256 aliceEthBefore = alice.balance;

        vm.prank(alice);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: _zeroForOne(key, takeCurrency),
                amountSpecified: -int256(outAmt),
                sqrtPriceLimitX96: _zeroForOne(key, takeCurrency) ? MIN_PRICE : MAX_PRICE
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );

        assertEq(weth.balanceOf(maker), 0, "maker spent WETH");
        assertEq(usdc.balanceOf(maker), outAmt, "maker received usdc");
        assertEq(usdc.balanceOf(alice), 0, "alice spent usdc");
        assertEq(alice.balance - aliceEthBefore, inAmt, "alice received native ETH");
        assertEq(weth.balanceOf(address(hook)), 0, "hook holds no WETH");
        assertEq(address(hook).balance, 0, "hook holds no ETH");
    }

    function test_fillOrder_wethPool_orderOutputsNativeEth_unwrapsWeth() public {
        uint256 inAmt = 100e6; // maker gives USDC
        uint256 outAmt = 1 ether; // maker wants native ETH

        // The pool holds WETH as an ordinary ERC20 currency (not native), so the hook must unwrap the
        // taken WETH via IWETH9.withdraw before forwarding native ETH to the reactor.
        PoolKey memory key = _initPool(Currency.wrap(address(weth)), Currency.wrap(address(usdc)));

        usdc.mint(maker, inAmt);
        vm.prank(maker);
        usdc.approve(address(reactor), type(uint256).max);

        // PoolManager WETH float so the hook can take WETH before alice settles
        vm.deal(address(this), 100 ether);
        weth.deposit{value: 100 ether}();
        weth.transfer(address(poolManager), 100 ether);

        // alice provides WETH (as an ERC20)
        vm.deal(alice, outAmt);
        vm.prank(alice);
        weth.deposit{value: outAmt}();
        vm.prank(alice);
        weth.approve(address(swapRouter), type(uint256).max);

        Currency takeCurrency = Currency.wrap(address(weth));
        bytes memory hookData = _order(address(usdc), inAmt, address(0), outAmt);

        vm.prank(alice);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: _zeroForOne(key, takeCurrency),
                amountSpecified: -int256(outAmt),
                sqrtPriceLimitX96: _zeroForOne(key, takeCurrency) ? MIN_PRICE : MAX_PRICE
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );

        assertEq(usdc.balanceOf(maker), 0, "maker spent usdc");
        assertEq(maker.balance, outAmt, "maker received native ETH");
        assertEq(weth.balanceOf(alice), 0, "alice spent WETH");
        assertEq(usdc.balanceOf(alice), inAmt, "alice received usdc");
        assertEq(weth.balanceOf(address(hook)), 0, "hook holds no WETH");
        assertEq(address(hook).balance, 0, "hook holds no ETH");
    }

    // ─────────────────────────── order/pool mismatches ───────────────────────────

    function test_fillOrder_orderInputMismatch_reverts() public {
        uint256 inAmt = 100 ether;
        uint256 outAmt = 99 ether;

        // Pool over (tokenB, usdc) but the order's input token is tokenA: the settle currency (usdc)
        // cannot deliver the order input -> reactorCallback must reject with OrderInputMismatch.
        PoolKey memory key = _initPool(Currency.wrap(address(tokenB)), Currency.wrap(address(usdc)));

        tokenA.mint(maker, inAmt);
        vm.prank(maker);
        tokenA.approve(address(reactor), type(uint256).max);
        tokenB.mint(address(poolManager), 1000 ether);
        tokenB.mint(alice, outAmt);
        vm.prank(alice);
        tokenB.approve(address(swapRouter), type(uint256).max);

        Currency takeCurrency = Currency.wrap(address(tokenB));
        bytes memory hookData = _order(address(tokenA), inAmt, address(tokenB), outAmt);

        vm.prank(alice);
        vm.expectRevert();
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: _zeroForOne(key, takeCurrency),
                amountSpecified: -int256(outAmt),
                sqrtPriceLimitX96: _zeroForOne(key, takeCurrency) ? MIN_PRICE : MAX_PRICE
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    function test_fillOrder_orderOutputMismatch_reverts() public {
        uint256 inAmt = 100 ether;
        uint256 outAmt = 99 ether;

        // Pool over (tokenA, usdc) but the order's output token is tokenB: the take currency (usdc)
        // does not match the order output -> reactorCallback must reject with OrderOutputMismatch.
        PoolKey memory key = _initPool(Currency.wrap(address(tokenA)), Currency.wrap(address(usdc)));

        tokenA.mint(maker, inAmt);
        vm.prank(maker);
        tokenA.approve(address(reactor), type(uint256).max);
        usdc.mint(address(poolManager), 1000e6);
        usdc.mint(alice, 99e6);
        vm.prank(alice);
        usdc.approve(address(swapRouter), type(uint256).max);

        Currency takeCurrency = Currency.wrap(address(usdc));
        bytes memory hookData = _order(address(tokenA), inAmt, address(tokenB), outAmt);

        vm.prank(alice);
        vm.expectRevert();
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: _zeroForOne(key, takeCurrency),
                amountSpecified: -int256(99e6),
                sqrtPriceLimitX96: _zeroForOne(key, takeCurrency) ? MIN_PRICE : MAX_PRICE
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    // ─────────────────────────── access control / quoting ───────────────────────────

    function test_reactorCallback_unauthorized_reverts() public {
        ResolvedOrder[] memory resolved = new ResolvedOrder[](1);
        vm.expectRevert(UniswapXAggregator.ProhibitedEntry.selector);
        hook.reactorCallback(resolved, abi.encode(NATIVE, NATIVE));
    }

    function test_quote_reverts() public {
        PoolKey memory key = _initPool(Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)));
        vm.expectRevert(BaseHookDataAggregator.QuoteNotSupported.selector);
        hook.quote(true, -int256(1 ether), key.toId());
    }

    function test_pseudoTotalValueLocked_reverts() public {
        PoolKey memory key = _initPool(Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)));
        vm.expectRevert(UniswapXAggregator.TVLNotSupported.selector);
        hook.pseudoTotalValueLocked(key.toId());
    }

    /// @dev A reactor that re-enters `PoolManager.swap` mid-fill must hit the hook's `Reentrancy` guard
    ///      in `_conductSwap` (the inflight flag is set for the whole `executeWithCallback`).
    function test_conductSwap_reentrancy_reverts() public {
        MockMaliciousUniswapXReactor malReactor = new MockMaliciousUniswapXReactor();
        UniswapXAggregator malHook = _deployHook(address(malReactor));

        uint256 inAmt = 100 ether;
        uint256 outAmt = 99 ether;

        PoolKey memory key = _initPoolWithHook(Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)), malHook);

        tokenA.mint(maker, inAmt);
        vm.prank(maker);
        tokenA.approve(address(malReactor), type(uint256).max);
        tokenB.mint(address(poolManager), 1000 ether);
        tokenB.mint(alice, outAmt);
        vm.prank(alice);
        tokenB.approve(address(swapRouter), type(uint256).max);

        Currency takeCurrency = Currency.wrap(address(tokenB));
        bytes memory hookData = _order(address(tokenA), inAmt, address(tokenB), outAmt);
        SwapParams memory params = SwapParams({
            zeroForOne: _zeroForOne(key, takeCurrency),
            amountSpecified: -int256(outAmt),
            sqrtPriceLimitX96: _zeroForOne(key, takeCurrency) ? MIN_PRICE : MAX_PRICE
        });

        // Arm the reactor to re-enter the same swap mid-fill; the inner swap must revert with Reentrancy
        // (recorded by the reactor), while the outer fill still completes.
        malReactor.setReenterSwap(poolManager, key, params, hookData);

        vm.prank(alice);
        swapRouter.swap(
            key, params, SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), hookData
        );

        assertTrue(
            _containsSelector(malReactor.lastRevertData(), UniswapXAggregator.Reentrancy.selector),
            "inner swap reverted with Reentrancy"
        );
        assertEq(tokenB.balanceOf(maker), outAmt, "outer fill completed");
    }

    /// @dev While the hook is inflight, `reactorCallback` from any address other than the configured
    ///      reactor must revert with `UnauthorizedCaller`.
    function test_reactorCallback_wrongCallerWhileInflight_reverts() public {
        MockMaliciousUniswapXReactor malReactor = new MockMaliciousUniswapXReactor();
        UniswapXAggregator malHook = _deployHook(address(malReactor));

        uint256 inAmt = 100 ether;
        uint256 outAmt = 99 ether;

        PoolKey memory key = _initPoolWithHook(Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)), malHook);

        tokenA.mint(maker, inAmt);
        vm.prank(maker);
        tokenA.approve(address(malReactor), type(uint256).max);
        tokenB.mint(address(poolManager), 1000 ether);
        tokenB.mint(alice, outAmt);
        vm.prank(alice);
        tokenB.approve(address(swapRouter), type(uint256).max);

        Currency takeCurrency = Currency.wrap(address(tokenB));
        bytes memory hookData = _order(address(tokenA), inAmt, address(tokenB), outAmt);

        // Arm the reactor to have a foreign address call reactorCallback mid-fill: inflight is set, but the
        // caller is not the reactor, so the hook must revert with UnauthorizedCaller (recorded by the prober).
        malReactor.setForeignCallback();

        vm.prank(alice);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: _zeroForOne(key, takeCurrency),
                amountSpecified: -int256(outAmt),
                sqrtPriceLimitX96: _zeroForOne(key, takeCurrency) ? MIN_PRICE : MAX_PRICE
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );

        assertTrue(
            _containsSelector(malReactor.prober().lastRevertData(), UniswapXAggregator.UnauthorizedCaller.selector),
            "foreign callback reverted with UnauthorizedCaller"
        );
        assertEq(tokenB.balanceOf(maker), outAmt, "outer fill completed");
    }

    /// @dev Returns true if `data` contains the 4-byte selector `sel` (hook reverts bubble up wrapped by
    ///      the PoolManager, so the selector may be embedded rather than at offset 0).
    function _containsSelector(bytes memory data, bytes4 sel) internal pure returns (bool) {
        if (data.length < 4) return false;
        for (uint256 i = 0; i + 4 <= data.length; i++) {
            if (data[i] == sel[0] && data[i + 1] == sel[1] && data[i + 2] == sel[2] && data[i + 3] == sel[3]) {
                return true;
            }
        }
        return false;
    }

    receive() external payable {}
}
