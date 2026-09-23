// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ALFMultiplexer} from "../../src/alf/ALFMultiplexer.sol";
import {SimpleSpreadQuoterHook} from "../../src/alf/SimpleSpreadQuoterHook.sol";
import {SpreadQuoterBase} from "../../src/alf/base/SpreadQuoterBase.sol";
import {MultiplexerHookData, TargetedQuoter} from "../../src/alf/types/MultiplexerTypes.sol";
import {MockQuoterHook} from "./mocks/MockQuoterHook.sol";

contract ALFMultiplexerTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    ALFMultiplexer public multiplexer;

    SimpleSpreadQuoterHook public quoterA;
    SimpleSpreadQuoterHook public quoterB;

    // Tier-1 (IALFHook) quoter used to exercise the reserve-bounded strict-tolerance baseline:
    // it can over-report its indicative while honestly reporting tiny effective liquidity.
    MockQuoterHook public mockQuoter;

    address ownerA = makeAddr("ownerA");
    address ownerB = makeAddr("ownerB");

    PoolKey multiplexerPoolKey;
    PoolKey quoterAPoolKey;
    PoolKey quoterBPoolKey;
    PoolKey mockQuoterPoolKey;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // ── Deploy multiplexer ──
        uint160 multiplexerFlags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_DONATE_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        multiplexer = ALFMultiplexer(
            address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | multiplexerFlags))
        );
        deployCodeTo("ALFMultiplexer", abi.encode(manager), address(multiplexer));

        // ── Deploy quoters (native LP model with LP gating) ──
        uint160 quoterFlags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG
        );
        quoterA = SimpleSpreadQuoterHook(
            address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | quoterFlags))
        );
        deployCodeTo("SimpleSpreadQuoterHook", abi.encode(manager, uint32(750_000), ownerA), address(quoterA));

        quoterB = SimpleSpreadQuoterHook(
            address(uint160((uint256(type(uint160).max) - (1 << 14)) & clearAllHookPermissionsMask | quoterFlags))
        );
        deployCodeTo("SimpleSpreadQuoterHook", abi.encode(manager, uint32(150_000), ownerB), address(quoterB));

        // ── Create pool keys with static fees: A expensive (5%), B cheap (1%) ──
        quoterAPoolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 50_000, tickSpacing: 60, hooks: IHooks(address(quoterA))
        });

        quoterBPoolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 10_000, tickSpacing: 60, hooks: IHooks(address(quoterB))
        });

        multiplexerPoolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 1, hooks: IHooks(address(multiplexer))
        });

        // ── Initialize pools (quoters at tick 30 → inside LP range [0,60)) ──
        // SpreadQuoter pools must be initialized via the owner-only `initializePool` entry
        // (direct `manager.initialize` is now blocked by `_beforeInitialize`).
        vm.prank(ownerA);
        quoterA.initializePool(quoterAPoolKey, TickMath.getSqrtPriceAtTick(30));
        vm.prank(ownerB);
        quoterB.initializePool(quoterBPoolKey, TickMath.getSqrtPriceAtTick(30));
        manager.initialize(multiplexerPoolKey, Constants.SQRT_PRICE_1_1);

        // ── Authorize LP router and seed at active tick ──
        vm.prank(ownerA);
        quoterA.setAuthorizedLP(address(modifyLiquidityRouter), true);
        vm.prank(ownerB);
        quoterB.setAuthorizedLP(address(modifyLiquidityRouter), true);

        _seedAtActiveTick(quoterAPoolKey, quoterA, 10_000e18, 10_000e18);
        _seedAtActiveTick(quoterBPoolKey, quoterB, 10_000e18, 10_000e18);

        // ── Activate both pools ──
        vm.prank(ownerA);
        quoterA.setPoolLive(quoterAPoolKey, true);
        vm.prank(ownerB);
        quoterB.setPoolLive(quoterBPoolKey, true);

        // ── Deploy a tier-1 mock quoter (its pool is left UNINITIALIZED on purpose: it quotes
        //    but fills nothing, soft-skipped during execution — the "wins quoting, delivers
        //    nothing" case the reserve-bounded baseline must tolerate). ──
        uint160 mockFlags =
            uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        mockQuoter = MockQuoterHook(
            address(uint160((uint256(type(uint160).max) - (1 << 20)) & clearAllHookPermissionsMask | mockFlags))
        );
        deployCodeTo("MockQuoterHook", abi.encode(manager, uint32(500_000)), address(mockQuoter));
        mockQuoterPoolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(mockQuoter))
        });
    }

    // ──── Helpers ────

    function _seedAtActiveTick(PoolKey memory key_, SpreadQuoterBase quoter, uint256 amount0, uint256 amount1)
        internal
    {
        int24 activeTick = quoter.activeLowerTick(key_.toId());
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key_.toId());
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(activeTick),
            TickMath.getSqrtPriceAtTick(activeTick + key_.tickSpacing),
            amount0,
            amount1
        );
        modifyLiquidityRouter.modifyLiquidity(
            key_,
            ModifyLiquidityParams({
                tickLower: activeTick, tickUpper: activeTick + key_.tickSpacing, liquidityDelta: int128(liq), salt: 0
            }),
            ""
        );
    }

    function _buildBothTargets() internal view returns (bytes memory) {
        TargetedQuoter[] memory targets = new TargetedQuoter[](2);
        targets[0] = TargetedQuoter({poolKey: quoterAPoolKey, amountSpecified: 0});
        targets[1] = TargetedQuoter({poolKey: quoterBPoolKey, amountSpecified: 0});
        return _buildTargetedHookData(targets);
    }

    function _buildTargetedHookData(TargetedQuoter[] memory targets) internal pure returns (bytes memory) {
        return abi.encode(MultiplexerHookData({attestationData: "", targets: targets, strictTolerancePips: 0}));
    }

    // ──── Multiplexer selects best quoter ────

    function test_selectsBetterQuoter_zeroForOne() public {
        // B has the lower fee (1% vs 5%) → B wins selection
        BalanceDelta delta = swap(multiplexerPoolKey, true, -1e18, _buildBothTargets());

        assertEq(delta.amount0(), -1e18);
        int128 output = delta.amount1();
        assertTrue(output > 0);
        // B's 1% fee → ~0.99e18 output
        assertApproxEqRel(uint256(int256(output)), 0.99e18, 0.01e18);
    }

    function test_selectsBetterQuoter_oneForZero() public {
        // B has the lower fee (1% vs 5%) → B wins selection (symmetric)
        BalanceDelta delta = swap(multiplexerPoolKey, false, -1e18, _buildBothTargets());

        int128 output = delta.amount0();
        assertTrue(output > 0);
        assertEq(delta.amount1(), -1e18);
        // B's 1% fee → ~0.99e18 output
        assertApproxEqRel(uint256(int256(output)), 0.99e18, 0.01e18);
    }

    // ──── Skips failed quoters ────

    function test_skipsUnliveQuoter_routesToLiveOne() public {
        // Turn off B (the cheaper quoter)
        vm.prank(ownerB);
        quoterB.setPoolLive(quoterBPoolKey, false);

        BalanceDelta delta = swap(multiplexerPoolKey, true, -1e18, _buildBothTargets());

        assertEq(delta.amount0(), -1e18);
        int128 output = delta.amount1();
        assertTrue(output > 0);
        // Falls back to A with 5% fee → ~0.95e18
        assertApproxEqRel(uint256(int256(output)), 0.95e18, 0.01e18);
    }

    // ──── No valid quotes ────

    function test_revertsWhenNoLiveQuoters() public {
        vm.prank(ownerA);
        quoterA.setPoolLive(quoterAPoolKey, false);
        vm.prank(ownerB);
        quoterB.setPoolLive(quoterBPoolKey, false);

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(multiplexer),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(ALFMultiplexer.NoValidQuotes.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(multiplexerPoolKey, true, -1e18, _buildBothTargets());
    }

    // ──── Empty hookData reverts with TargetsRequired ────

    function test_revertsWithEmptyHookData() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(multiplexer),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(ALFMultiplexer.TargetsRequired.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(multiplexerPoolKey, true, -1e18, "");
    }

    // ──── Delta forwarding correctness ────

    function test_deltaForwarding_exactInput() public {
        MockERC20 token0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 token1 = MockERC20(Currency.unwrap(currency1));

        uint256 userBal0Before = token0.balanceOf(address(this));
        uint256 userBal1Before = token1.balanceOf(address(this));

        BalanceDelta delta = swap(multiplexerPoolKey, true, -1e18, _buildBothTargets());

        // User paid exactly 1e18 token0
        assertEq(token0.balanceOf(address(this)), userBal0Before - 1e18);

        // User received output token1 (B wins with 1% bidFee)
        uint256 received = token1.balanceOf(address(this)) - userBal1Before;
        assertApproxEqRel(received, 0.99e18, 0.01e18);

        assertEq(delta.amount0(), -1e18);
        assertApproxEqRel(uint256(int256(delta.amount1())), 0.99e18, 0.01e18);
    }

    function test_deltaForwarding_exactOutput() public {
        // Exact output: user wants 0.5e18 token1 via zeroForOne
        BalanceDelta delta = swap(multiplexerPoolKey, true, 0.5e18, _buildBothTargets());

        int128 output = delta.amount1();
        assertTrue(output > 0);
        // Should get approximately 0.5e18 token1
        assertApproxEqRel(uint256(int256(output)), 0.5e18, 0.02e18);
    }

    // ──── Blocks liquidity on virtual pool ────

    function test_blocksLiquidity() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(multiplexer),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(ALFMultiplexer.LiquidityNotAllowed.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        modifyLiquidityRouter.modifyLiquidity(
            multiplexerPoolKey,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: 0}),
            ""
        );
    }

    // ──── Event emission ────

    function test_emitsMultiplexerExecuted_autonomous() public {
        // B wins with lower fee (1%)
        vm.expectEmit(true, false, false, false); // only check winner address
        emit ALFMultiplexer.MultiplexerExecuted(address(quoterB), true, -1e18, 0);
        swap(multiplexerPoolKey, true, -1e18, _buildBothTargets());
    }

    // ════════════════════════════════════════════
    //  Targeted Mode
    // ════════════════════════════════════════════

    function test_targeted_selectsBetterQuoter() public {
        // Target both quoters — B should win for zeroForOne (1% vs 5% bid fee)
        TargetedQuoter[] memory targets = new TargetedQuoter[](2);
        targets[0] = TargetedQuoter({poolKey: quoterAPoolKey, amountSpecified: 0});
        targets[1] = TargetedQuoter({poolKey: quoterBPoolKey, amountSpecified: 0});

        BalanceDelta delta = swap(multiplexerPoolKey, true, -1e18, _buildTargetedHookData(targets));

        assertEq(delta.amount0(), -1e18);
        int128 output = delta.amount1();
        assertTrue(output > 0);
        // B's 1% fee → ~0.99e18 output
        assertApproxEqRel(uint256(int256(output)), 0.99e18, 0.01e18);
    }

    function test_targeted_singleQuoter() public {
        // Target only A for zeroForOne — A executes with its 5% bidFee
        TargetedQuoter[] memory targets = new TargetedQuoter[](1);
        targets[0] = TargetedQuoter({poolKey: quoterAPoolKey, amountSpecified: 0});

        BalanceDelta delta = swap(multiplexerPoolKey, true, -1e18, _buildTargetedHookData(targets));

        assertEq(delta.amount0(), -1e18);
        int128 output = delta.amount1();
        assertTrue(output > 0);
        // A's 5% bidFee → ~0.95e18
        assertApproxEqRel(uint256(int256(output)), 0.95e18, 0.01e18);
    }

    function test_targeted_skipsUnliveQuoter() public {
        // Set B to unlive, target both — A should win
        vm.prank(ownerB);
        quoterB.setPoolLive(quoterBPoolKey, false);

        TargetedQuoter[] memory targets = new TargetedQuoter[](2);
        targets[0] = TargetedQuoter({poolKey: quoterAPoolKey, amountSpecified: 0});
        targets[1] = TargetedQuoter({poolKey: quoterBPoolKey, amountSpecified: 0});

        BalanceDelta delta = swap(multiplexerPoolKey, true, -1e18, _buildTargetedHookData(targets));

        assertEq(delta.amount0(), -1e18);
        int128 output = delta.amount1();
        assertTrue(output > 0);
        // Falls back to A with 5% bidFee → ~0.95e18
        assertApproxEqRel(uint256(int256(output)), 0.95e18, 0.01e18);
    }

    function test_targeted_revertsWhenAllTargetsInvalid() public {
        vm.prank(ownerA);
        quoterA.setPoolLive(quoterAPoolKey, false);
        vm.prank(ownerB);
        quoterB.setPoolLive(quoterBPoolKey, false);

        TargetedQuoter[] memory targets = new TargetedQuoter[](2);
        targets[0] = TargetedQuoter({poolKey: quoterAPoolKey, amountSpecified: 0});
        targets[1] = TargetedQuoter({poolKey: quoterBPoolKey, amountSpecified: 0});

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(multiplexer),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(ALFMultiplexer.NoValidQuotes.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(multiplexerPoolKey, true, -1e18, _buildTargetedHookData(targets));
    }

    function test_targeted_emitsMultiplexerExecuted() public {
        TargetedQuoter[] memory targets = new TargetedQuoter[](2);
        targets[0] = TargetedQuoter({poolKey: quoterAPoolKey, amountSpecified: 0});
        targets[1] = TargetedQuoter({poolKey: quoterBPoolKey, amountSpecified: 0});

        // B wins with lower fee (1%)
        vm.expectEmit(true, false, false, false);
        emit ALFMultiplexer.MultiplexerExecuted(address(quoterB), true, -1e18, 0);
        swap(multiplexerPoolKey, true, -1e18, _buildTargetedHookData(targets));
    }

    // ════════════════════════════════════════════
    //  Strict Mode
    // ════════════════════════════════════════════

    function _buildStrictHookData(TargetedQuoter[] memory targets) internal pure returns (bytes memory) {
        return _buildStrictHookDataWithTolerance(targets, 1);
    }

    function _buildStrictHookDataWithTolerance(TargetedQuoter[] memory targets, uint24 tolerancePips)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            MultiplexerHookData({attestationData: "", targets: targets, strictTolerancePips: tolerancePips})
        );
    }

    function test_strict_passesWhenQuoteMatchesExecution() public {
        TargetedQuoter[] memory targets = new TargetedQuoter[](2);
        targets[0] = TargetedQuoter({poolKey: quoterAPoolKey, amountSpecified: 0});
        targets[1] = TargetedQuoter({poolKey: quoterBPoolKey, amountSpecified: 0});

        // Strict mode should pass — spread quoter's indicative matches execution exactly
        BalanceDelta delta = swap(multiplexerPoolKey, true, -1e18, _buildStrictHookData(targets));
        assertEq(delta.amount0(), -1e18);
        assertTrue(delta.amount1() > 0);
    }

    function test_strict_exactOutput() public {
        TargetedQuoter[] memory targets = new TargetedQuoter[](1);
        targets[0] = TargetedQuoter({poolKey: quoterBPoolKey, amountSpecified: 0});

        // Exact output with strict mode
        BalanceDelta delta = swap(multiplexerPoolKey, true, 0.5e18, _buildStrictHookData(targets));
        assertEq(delta.amount1(), int128(0.5e18));
        assertTrue(delta.amount0() < 0);
    }

    function test_strict_toleranceAllowsSmallDeviation() public {
        // SpreadQuoter is deterministic (indicative == executed), so any tolerance > 0 passes.
        // Use a large tolerance (10%) to demonstrate the feature.
        TargetedQuoter[] memory targets = new TargetedQuoter[](1);
        targets[0] = TargetedQuoter({poolKey: quoterBPoolKey, amountSpecified: 0});

        BalanceDelta delta = swap(multiplexerPoolKey, true, -1e18, _buildStrictHookDataWithTolerance(targets, 100_000)); // 10%
        assertEq(delta.amount0(), -1e18);
        assertTrue(delta.amount1() > 0);
    }

    function test_strict_zeroToleranceDisablesCheck() public {
        // strictTolerancePips = 0 → no strict check at all
        TargetedQuoter[] memory targets = new TargetedQuoter[](1);
        targets[0] = TargetedQuoter({poolKey: quoterBPoolKey, amountSpecified: 0});

        BalanceDelta delta = swap(multiplexerPoolKey, true, -1e18, _buildStrictHookDataWithTolerance(targets, 0));
        assertEq(delta.amount0(), -1e18);
        assertTrue(delta.amount1() > 0);
    }

    /// @dev Reserve-bounded baseline (fix 1). A tier-1 quoter reports a wildly inflated indicative
    ///      (1000e18) but honest, tiny effective liquidity and delivers nothing on execution (its
    ///      pool is uninitialized → soft-skipped). Without bounding the baseline by the quoter's
    ///      declared `getEffectiveLiquidity`, the inflated quote would set an unreachable threshold
    ///      and trip the strict check on quoterB's perfectly fair fill. With the bound, a tight 1%
    ///      tolerance still passes.
    function test_strict_reserveBoundedBaseline_inflatedQuoterDoesNotTrip() public {
        mockQuoter.setPrice(1000e18, 0); // absurd indicative, dwarfs any real fill
        mockQuoter.setEffectiveLiquidity(1e15, 1e15); // honest: it can deliver almost nothing

        TargetedQuoter[] memory targets = new TargetedQuoter[](2);
        targets[0] = TargetedQuoter({poolKey: mockQuoterPoolKey, amountSpecified: 0});
        targets[1] = TargetedQuoter({poolKey: quoterBPoolKey, amountSpecified: 0});

        // 1% tolerance: only satisfiable if the baseline is bounded to deliverable reserves.
        BalanceDelta delta = swap(multiplexerPoolKey, true, -1e18, _buildStrictHookDataWithTolerance(targets, 10_000));
        assertEq(delta.amount0(), -1e18, "full input consumed");
        assertGt(delta.amount1(), 0, "received output from quoterB");
    }

    /// @dev Control for {test_strict_reserveBoundedBaseline_inflatedQuoterDoesNotTrip}: a quoter
    ///      with a high indicative but NO declared reserves (effective liquidity 0,0) cannot be
    ///      bounded, so the unreachable threshold survives and strict tolerance trips. Confirms the
    ///      bound is what saves the swap, and documents the trusted-targets residual.
    function test_strict_unboundableQuoterStillTrips() public {
        mockQuoter.setPrice(1000e18, 0);
        mockQuoter.setEffectiveLiquidity(0, 0); // reports no reserves → nothing to bound against

        TargetedQuoter[] memory targets = new TargetedQuoter[](2);
        targets[0] = TargetedQuoter({poolKey: mockQuoterPoolKey, amountSpecified: 0});
        targets[1] = TargetedQuoter({poolKey: quoterBPoolKey, amountSpecified: 0});

        vm.expectRevert();
        swap(multiplexerPoolKey, true, -1e18, _buildStrictHookDataWithTolerance(targets, 10_000));
    }

    /// @dev Ranking is unaffected by the baseline bound: the offchain `quote()` view still elects
    ///      the highest RAW indicative and returns it verbatim. The reserve bound shapes only the
    ///      on-chain strict-tolerance baseline, not candidate selection.
    function test_quote_rankingUsesRawIndicative_notReserveBounded() public {
        mockQuoter.setPrice(1000e18, 0);
        mockQuoter.setEffectiveLiquidity(1e15, 1e15);

        TargetedQuoter[] memory targets = new TargetedQuoter[](2);
        targets[0] = TargetedQuoter({poolKey: mockQuoterPoolKey, amountSpecified: 0});
        targets[1] = TargetedQuoter({poolKey: quoterBPoolKey, amountSpecified: 0});

        (, address winner, uint256 bestQuote,) = multiplexer.quote(true, -1e18, _buildTargetedHookData(targets));
        assertEq(winner, address(mockQuoter), "ranking selects the highest raw indicative");
        assertEq(bestQuote, 1000e18, "quote() returns the raw indicative, not reserve-bounded");
    }

    // ════════════════════════════════════════════
    //  Offchain Quote View
    // ════════════════════════════════════════════

    function test_quote_targeted_selectsBestQuoter_zeroForOne() public view {
        // B has the lower fee (1% vs 5%) → B wins
        (, address winner, uint256 bestQuote,) = multiplexer.quote(true, -1e18, _buildBothTargets());

        assertEq(winner, address(quoterB));
        assertTrue(bestQuote > 0);
    }

    function test_quote_targeted_selectsBestQuoter_oneForZero() public view {
        // B has the lower fee (1% vs 5%) → B wins (symmetric)
        (, address winner, uint256 bestQuote,) = multiplexer.quote(false, -1e18, _buildBothTargets());

        assertEq(winner, address(quoterB));
        assertTrue(bestQuote > 0);
    }

    function test_quote_targeted_selectsBestQuoter() public view {
        TargetedQuoter[] memory targets = new TargetedQuoter[](2);
        targets[0] = TargetedQuoter({poolKey: quoterAPoolKey, amountSpecified: 0});
        targets[1] = TargetedQuoter({poolKey: quoterBPoolKey, amountSpecified: 0});

        (, address winner, uint256 bestQuote,) = multiplexer.quote(true, -1e18, _buildTargetedHookData(targets));

        assertEq(winner, address(quoterB));
        assertTrue(bestQuote > 0);
    }

    function test_quote_matchesSwapExecution() public {
        // Get the quote first
        (, address winner, uint256 bestQuote,) = multiplexer.quote(true, -1e18, _buildBothTargets());

        // Execute the actual swap
        BalanceDelta delta = swap(multiplexerPoolKey, true, -1e18, _buildBothTargets());

        // Quote winner should match the quoter that executed
        assertEq(winner, address(quoterB));
        // Quote amount should match actual output
        uint256 actualOutput = uint256(int256(delta.amount1()));
        assertEq(bestQuote, actualOutput);
    }

    function test_quote_revertsWhenNoLiveQuoters() public {
        vm.prank(ownerA);
        quoterA.setPoolLive(quoterAPoolKey, false);
        vm.prank(ownerB);
        quoterB.setPoolLive(quoterBPoolKey, false);

        vm.expectRevert(ALFMultiplexer.NoValidQuotes.selector);
        multiplexer.quote(true, -1e18, _buildBothTargets());
    }

    function test_quote_skipsUnliveQuoter() public {
        vm.prank(ownerB);
        quoterB.setPoolLive(quoterBPoolKey, false);

        (, address winner,,) = multiplexer.quote(true, -1e18, _buildBothTargets());
        assertEq(winner, address(quoterA));
    }

    function test_quote_exactOutput() public view {
        // Exact output: picks quoter requiring least input
        (, address winner, uint256 bestQuote,) = multiplexer.quote(true, 0.5e18, _buildBothTargets());

        // B has lower bidFee → requires less input → wins
        assertEq(winner, address(quoterB));
        assertTrue(bestQuote > 0);
    }

    // ════════════════════════════════════════════
    //  Protocol Fee Tests
    // ════════════════════════════════════════════
    // Protocol fees are now read from the pool's slot0 (set by the v4 fee adapter)
    // and taken directly to the token jar during _beforeSwap via _applyProtocolFee.
    // Full protocol fee testing requires a fee adapter mock — covered in fork tests.

    function test_multiplexerFee_zeroFee() public {
        // Default pool has no protocol fee set in slot0 — verify no fee taken
        swap(multiplexerPoolKey, true, -1e18, _buildBothTargets());
        assertEq(manager.balanceOf(address(multiplexer), currency0.toId()), 0);
    }

    /// @dev A pre-planned target whose `amountSpecified` sign mismatches the outer swap is rejected.
    function test_prePlanned_directionMismatch_reverts() public {
        // Outer swap: exact-input (negative). Target leg uses exact-output (positive) — mismatch.
        MultiplexerHookData memory ahd =
            MultiplexerHookData({attestationData: "", targets: new TargetedQuoter[](2), strictTolerancePips: 0});
        ahd.targets[0] = TargetedQuoter({poolKey: quoterAPoolKey, amountSpecified: int256(0.5e18)}); // wrong sign!
        ahd.targets[1] = TargetedQuoter({poolKey: quoterBPoolKey, amountSpecified: int256(0)}); // catch-all

        // The PoolManager wraps hook reverts in `WrappedError`, so we just verify it reverts.
        vm.expectRevert();
        swap(multiplexerPoolKey, true, -1e18, abi.encode(ahd));
    }

    /// @dev Pre-planned targets summing to more than `|swapAmount|` are rejected.
    function test_prePlanned_overAllocated_reverts() public {
        MultiplexerHookData memory ahd =
            MultiplexerHookData({attestationData: "", targets: new TargetedQuoter[](2), strictTolerancePips: 0});
        ahd.targets[0] = TargetedQuoter({poolKey: quoterAPoolKey, amountSpecified: int256(-0.6e18)});
        ahd.targets[1] = TargetedQuoter({poolKey: quoterBPoolKey, amountSpecified: int256(-0.6e18)});
        // Sum = -1.2e18, outer swap is -1e18 → over-allocated.

        vm.expectRevert();
        swap(multiplexerPoolKey, true, -1e18, abi.encode(ahd));
    }

    /// @dev Regression: an under-allocated pre-planned EXACT-INPUT set (sized legs summing to
    ///      less than the swap, no catch-all) must revert, not silently leave the unfilled
    ///      residual to be swapped against the multiplexer's own zero-liquidity pool. Previously
    ///      only exact-output reverted on under-fill; exact-input leaked the residual, which
    ///      tick-walked to the price limit and pinned the virtual pool's price.
    function test_prePlanned_exactInputUnderAllocated_reverts() public {
        MultiplexerHookData memory ahd =
            MultiplexerHookData({attestationData: "", targets: new TargetedQuoter[](1), strictTolerancePips: 0});
        // One sized leg covering only 0.4 of a 1.0 exact-input swap, and NO catch-all leg.
        ahd.targets[0] = TargetedQuoter({poolKey: quoterBPoolKey, amountSpecified: int256(-0.4e18)});

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(multiplexer),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(ALFMultiplexer.InsufficientLiquidity.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(multiplexerPoolKey, true, -1e18, abi.encode(ahd));
    }

    /// @dev Control: a pre-planned exact-input whose catch-all leg covers the remainder still
    ///      fills completely — the under-fill guard does not reject well-allocated splits.
    function test_prePlanned_exactInputFullyAllocated_succeeds() public {
        MultiplexerHookData memory ahd =
            MultiplexerHookData({attestationData: "", targets: new TargetedQuoter[](2), strictTolerancePips: 0});
        ahd.targets[0] = TargetedQuoter({poolKey: quoterBPoolKey, amountSpecified: int256(-0.4e18)});
        ahd.targets[1] = TargetedQuoter({poolKey: quoterAPoolKey, amountSpecified: int256(0)}); // catch-all fills 0.6

        BalanceDelta delta = swap(multiplexerPoolKey, true, -1e18, abi.encode(ahd));
        assertEq(delta.amount0(), -1e18, "full exact-input should be consumed");
        assertGt(delta.amount1(), 0, "should receive output");
    }

    /// @dev A target trading a different currency pair than the virtual pool is rejected up front
    ///      with `TargetCurrencyMismatch` (attributing the bad index), rather than producing
    ///      non-netting deltas that revert the unlock with the opaque `CurrencyNotSettled`. The
    ///      check fails fast before any nested swap, so the mismatched target pool need not exist.
    function test_targets_currencyMismatch_reverts() public {
        TargetedQuoter[] memory targets = new TargetedQuoter[](2);
        targets[0] = TargetedQuoter({poolKey: quoterAPoolKey, amountSpecified: 0}); // correct pair
        // Second target keeps currency0 but swaps currency1 for an unrelated token.
        PoolKey memory mismatched = PoolKey({
            currency0: currency0,
            currency1: Currency.wrap(address(0xBEEF)),
            fee: 10_000,
            tickSpacing: 60,
            hooks: IHooks(address(quoterB))
        });
        targets[1] = TargetedQuoter({poolKey: mismatched, amountSpecified: 0});

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(multiplexer),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(ALFMultiplexer.TargetCurrencyMismatch.selector, uint256(1)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(multiplexerPoolKey, true, -1e18, _buildTargetedHookData(targets));
    }

    /// @dev Donations to the virtual multiplexer pool would be permanently locked since the pool
    ///      has no LP positions — `_beforeDonate` reverts unconditionally.
    function test_donate_revertsOnVirtualPool() public {
        deal(Currency.unwrap(currency0), address(this), 1e18);
        deal(Currency.unwrap(currency1), address(this), 1e18);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(donateRouter), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(donateRouter), type(uint256).max);

        vm.expectRevert();
        donateRouter.donate(multiplexerPoolKey, 1e18, 1e18, "");
    }
}
