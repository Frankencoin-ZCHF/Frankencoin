// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {QuoterRevert} from "@uniswap/v4-periphery/src/libraries/QuoterRevert.sol";
import {BaseHook} from "../../src/base/BaseHook.sol";
import {ALFMultiplexer} from "../../src/alf/ALFMultiplexer.sol";
import {SimpleSpreadQuoterHook} from "../../src/alf/SimpleSpreadQuoterHook.sol";
import {SpreadQuoterBase} from "../../src/alf/base/SpreadQuoterBase.sol";
import {MultiplexerHookData, TargetedQuoter} from "../../src/alf/types/MultiplexerTypes.sol";
import {FillableALFQuoter} from "./mocks/FillableALFQuoter.sol";
import {MockAdversarialALFHook} from "./mocks/MockAdversarialALFHook.sol";

/// @dev Exposes the multiplexer's pure guard helpers so their branches can be pinned directly:
///      the tier-4 QuoteSwap parser's length/selector gates and `_toBeforeSwapDelta`'s
///      `UnrepresentableDelta` backstop are unreachable (or nondeterministic to reach) through
///      the PoolManager, but their behavior is load-bearing for soft-fail semantics.
contract MultiplexerHarness is ALFMultiplexer {
    constructor(IPoolManager pm) ALFMultiplexer(pm) {}

    /// @dev Skip hook-address flag validation; the harness is never used as a hook.
    function validateHookAddress(BaseHook) internal pure override {}

    function parseQuoteOrZero(bytes memory reason) external pure returns (uint256) {
        return _parseQuoteOrZero(reason);
    }

    function toBeforeSwapDelta(BalanceDelta delta, SwapParams calldata params) external pure returns (BeforeSwapDelta) {
        return _toBeforeSwapDelta(delta, params);
    }
}

/// @notice Branch-coverage suite for `ALFMultiplexer`: exact-output execution, pre-planned
///         validation and clamping, strict-tolerance baselines against adversarial tier-1
///         candidates, and the pure guard helpers. Complements `ALFMultiplexer.t.sol`
///         (happy paths) and `ALFMultiplexerWaterfall.t.sol` (tier selection).
contract ALFMultiplexerBranchesTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    ALFMultiplexer public multiplexer;
    MultiplexerHarness public harness;

    SimpleSpreadQuoterHook public quoterA; // 5% fee, deep
    SimpleSpreadQuoterHook public quoterB; // 1% fee, deep
    SimpleSpreadQuoterHook public quoterC; // 1% fee, shallow (clamp / partial-fill cases)
    FillableALFQuoter public fillable; // tier-1 metadata, fills via ordinary pool LP
    MockAdversarialALFHook public adversarial;

    address owner = makeAddr("owner");

    PoolKey multiplexerPoolKey;
    PoolKey quoterAPoolKey;
    PoolKey quoterBPoolKey;
    PoolKey quoterCPoolKey;
    PoolKey fillablePoolKey;
    PoolKey adversarialPoolKey;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // ── Multiplexer on its virtual pool ──
        uint160 muxFlags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_DONATE_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        multiplexer =
            ALFMultiplexer(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | muxFlags)));
        deployCodeTo("ALFMultiplexer", abi.encode(manager), address(multiplexer));

        harness = new MultiplexerHarness(manager);

        // ── Three spread quoters (tier-1 IALFHook with native LP) ──
        uint160 quoterFlags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG
        );
        quoterA = SimpleSpreadQuoterHook(_hookAddr(0, quoterFlags));
        quoterB = SimpleSpreadQuoterHook(_hookAddr(1, quoterFlags));
        quoterC = SimpleSpreadQuoterHook(_hookAddr(2, quoterFlags));
        deployCodeTo("SimpleSpreadQuoterHook", abi.encode(manager, uint32(750_000), owner), address(quoterA));
        deployCodeTo("SimpleSpreadQuoterHook", abi.encode(manager, uint32(750_000), owner), address(quoterB));
        deployCodeTo("SimpleSpreadQuoterHook", abi.encode(manager, uint32(750_000), owner), address(quoterC));

        quoterAPoolKey = _key(50_000, 60, address(quoterA));
        quoterBPoolKey = _key(10_000, 60, address(quoterB));
        quoterCPoolKey = _key(10_000, 60, address(quoterC));
        multiplexerPoolKey = _key(0, 1, address(multiplexer));

        vm.startPrank(owner);
        quoterA.initializePool(quoterAPoolKey, TickMath.getSqrtPriceAtTick(30));
        quoterB.initializePool(quoterBPoolKey, TickMath.getSqrtPriceAtTick(30));
        quoterC.initializePool(quoterCPoolKey, TickMath.getSqrtPriceAtTick(30));
        quoterA.setAuthorizedLP(address(modifyLiquidityRouter), true);
        quoterB.setAuthorizedLP(address(modifyLiquidityRouter), true);
        quoterC.setAuthorizedLP(address(modifyLiquidityRouter), true);
        vm.stopPrank();

        manager.initialize(multiplexerPoolKey, Constants.SQRT_PRICE_1_1);

        _seedAtActiveTick(quoterAPoolKey, quoterA, 10_000e18, 10_000e18);
        _seedAtActiveTick(quoterBPoolKey, quoterB, 10_000e18, 10_000e18);
        _seedAtActiveTick(quoterCPoolKey, quoterC, 100e18, 100e18);

        vm.startPrank(owner);
        quoterA.setPoolLive(quoterAPoolKey, true);
        quoterB.setPoolLive(quoterBPoolKey, true);
        quoterC.setPoolLive(quoterCPoolKey, true);
        vm.stopPrank();

        // ── Fillable tier-1 quoter: metadata from the mock, execution against pool LP ──
        fillable = FillableALFQuoter(_hookAddr(3, uint160(Hooks.BEFORE_SWAP_FLAG)));
        deployCodeTo("FillableALFQuoter", abi.encode(manager, uint32(500_000)), address(fillable));
        fillablePoolKey = _key(3_000, 60, address(fillable));
        manager.initialize(fillablePoolKey, Constants.SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            fillablePoolKey, ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e24, salt: 0}), ""
        );

        // ── Adversarial tier-1 metadata surface (quote-path only, never swapped) ──
        adversarial = new MockAdversarialALFHook();
        adversarialPoolKey = _key(3_000, 60, address(adversarial));
    }

    // ══════════════════════════════════════════════════════════
    //  Helpers
    // ══════════════════════════════════════════════════════════

    function _hookAddr(uint256 i, uint160 flags) internal view returns (address payable) {
        return payable(address(uint160((uint256(type(uint160).max) - (i << 14)) & clearAllHookPermissionsMask | flags)));
    }

    function _key(uint24 fee, int24 spacing, address hook) internal view returns (PoolKey memory) {
        return
            PoolKey({currency0: currency0, currency1: currency1, fee: fee, tickSpacing: spacing, hooks: IHooks(hook)});
    }

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

    function _targets1(PoolKey memory k, int256 amt) internal pure returns (TargetedQuoter[] memory t) {
        t = new TargetedQuoter[](1);
        t[0] = TargetedQuoter({poolKey: k, amountSpecified: amt});
    }

    function _targets2(PoolKey memory k0, int256 a0, PoolKey memory k1, int256 a1)
        internal
        pure
        returns (TargetedQuoter[] memory t)
    {
        t = new TargetedQuoter[](2);
        t[0] = TargetedQuoter({poolKey: k0, amountSpecified: a0});
        t[1] = TargetedQuoter({poolKey: k1, amountSpecified: a1});
    }

    function _hookData(TargetedQuoter[] memory targets, uint24 tol) internal pure returns (bytes memory) {
        return abi.encode(MultiplexerHookData({attestationData: "", targets: targets, strictTolerancePips: tol}));
    }

    function _wrapped(bytes4 innerSelector) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(multiplexer),
            IHooks.beforeSwap.selector,
            abi.encodeWithSelector(innerSelector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    // ══════════════════════════════════════════════════════════
    //  Entry guards
    // ══════════════════════════════════════════════════════════

    function test_quoteTargetBySwap_revertsForExternalCaller() public {
        vm.expectRevert(ALFMultiplexer.NotSelf.selector);
        multiplexer.quoteTargetBySwap(quoterBPoolKey, true, -1e18, "");
    }

    function test_quote_emptyHookData_reverts() public {
        vm.expectRevert(ALFMultiplexer.TargetsRequired.selector);
        multiplexer.quote(true, -1e18, "");
    }

    function test_quote_emptyTargets_reverts() public {
        vm.expectRevert(ALFMultiplexer.TargetsRequired.selector);
        multiplexer.quote(true, -1e18, _hookData(new TargetedQuoter[](0), 0));
    }

    function test_swap_emptyTargets_reverts() public {
        vm.expectRevert(_wrapped(ALFMultiplexer.TargetsRequired.selector));
        swap(multiplexerPoolKey, true, -1e18, _hookData(new TargetedQuoter[](0), 0));
    }

    // ══════════════════════════════════════════════════════════
    //  Adversarial tier-1 metadata: every failure soft-skips
    // ══════════════════════════════════════════════════════════

    function test_quote_skipsCandidateWhenIsLiveReverts() public {
        adversarial.setRevertOnIsLive(true);
        (, address winner,,) =
            multiplexer.quote(true, -1e18, _hookData(_targets2(adversarialPoolKey, 0, quoterBPoolKey, 0), 0));
        assertEq(winner, address(quoterB), "reverting isLive soft-skips the candidate");
    }

    function test_quote_skipsCandidateWhenNotLive() public {
        adversarial.setLiveValue(false);
        (, address winner,,) =
            multiplexer.quote(true, -1e18, _hookData(_targets2(adversarialPoolKey, 0, quoterBPoolKey, 0), 0));
        assertEq(winner, address(quoterB), "isLive == false soft-skips the candidate");
    }

    function test_quote_skipsCandidateWhenMaxGasReverts() public {
        adversarial.setRevertOnMaxGas(true);
        (, address winner,,) =
            multiplexer.quote(true, -1e18, _hookData(_targets2(adversarialPoolKey, 0, quoterBPoolKey, 0), 0));
        assertEq(winner, address(quoterB), "reverting maxGas soft-skips the candidate");
    }

    function test_quote_skipsCandidateWhenIndicativeReverts() public {
        adversarial.setRevertOnQuote(true);
        (, address winner,,) =
            multiplexer.quote(true, -1e18, _hookData(_targets2(adversarialPoolKey, 0, quoterBPoolKey, 0), 0));
        assertEq(winner, address(quoterB), "reverting getIndicativeQuote soft-skips the candidate");
    }

    function test_quote_revertsWhenOnlyCandidateIsAdversarial() public {
        adversarial.setRevertOnIsLive(true);
        vm.expectRevert(ALFMultiplexer.NoValidQuotes.selector);
        multiplexer.quote(true, -1e18, _hookData(_targets1(adversarialPoolKey, 0), 0));
    }

    /// @dev Dynamic-fee pool whose hook has `BEFORE_SWAP_FLAG`: the hook could push a per-swap
    ///      fee override the view path cannot observe, so tier 2 must refuse to simulate. With
    ///      no other tier available the candidate yields no quote.
    function test_quote_dynamicFeeWithBeforeSwapHook_isNotSimulatorSafe() public {
        PoolKey memory unsafeKey = _key(LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, address(uint160(Hooks.BEFORE_SWAP_FLAG)));
        vm.expectRevert(ALFMultiplexer.NoValidQuotes.selector);
        multiplexer.quote(true, -1e18, _hookData(_targets1(unsafeKey, 0), 0));
    }

    // ══════════════════════════════════════════════════════════
    //  Exact-output execution
    // ══════════════════════════════════════════════════════════

    function test_exactOutput_autonomous_deliversRequestedOutput() public {
        BalanceDelta delta =
            swap(multiplexerPoolKey, true, 200e18, _hookData(_targets2(quoterAPoolKey, 0, quoterBPoolKey, 0), 0));

        assertEq(delta.amount1(), 200e18, "exact-output delivers the requested amount");
        assertLt(delta.amount0(), 0, "input paid");
        // B (1% fee) wins the ascending exact-out sort, so input is near output * 1.01.
        assertApproxEqRel(uint256(int256(-delta.amount0())), 202e18, 0.02e18);
    }

    /// @dev Conservation across the split fill: whatever the requested exact-output size (up to
    ///      aggregate depth), the swapper receives exactly that amount and pays a positive input.
    function testFuzz_exactOutput_autonomous_deliversExactAmount(uint256 amountOut) public {
        amountOut = bound(amountOut, 1e12, 2_000e18);

        BalanceDelta delta = swap(
            multiplexerPoolKey, true, int256(amountOut), _hookData(_targets2(quoterAPoolKey, 0, quoterBPoolKey, 0), 0)
        );

        assertEq(uint256(int256(delta.amount1())), amountOut, "output delivered exactly as requested");
        assertLt(delta.amount0(), 0, "input paid");
    }

    function test_exactOutput_insufficientAggregateLiquidity_reverts() public {
        // Both quoters' single-band depth combined cannot deliver 50k of output.
        vm.expectRevert(_wrapped(ALFMultiplexer.InsufficientLiquidity.selector));
        swap(multiplexerPoolKey, true, 50_000e18, _hookData(_targets2(quoterAPoolKey, 0, quoterBPoolKey, 0), 0));
    }

    // ══════════════════════════════════════════════════════════
    //  Strict tolerance: baselines and deviations
    // ══════════════════════════════════════════════════════════

    /// @dev Non-IALFHook candidates carry no reserve view, so their contribution enters the
    ///      baseline unbounded and a well-behaved fill passes a generous tolerance.
    function test_strictTolerance_tier2Baseline_passes() public {
        BalanceDelta delta =
            swap(multiplexerPoolKey, true, -1e18, _hookData(_targets2(quoterAPoolKey, 0, quoterBPoolKey, 0), 500_000));
        assertGt(delta.amount1(), 0, "fill succeeds within 50% tolerance");
    }

    /// @dev A tier-1 candidate whose `getEffectiveLiquidity` reverts cannot be reserve-bounded;
    ///      the baseline falls back to the raw indicative rather than aborting the swap.
    function test_strictTolerance_effectiveLiquidityRevert_fallsBackToRawIndicative() public {
        fillable.setPrice(0.9e18); // below real execution (~0.997e18 out), so no deviation
        fillable.setRevertOnEffectiveLiquidity(true);

        BalanceDelta delta = swap(multiplexerPoolKey, true, -1e18, _hookData(_targets1(fillablePoolKey, 0), 500_000));
        assertGt(delta.amount1(), 0, "fill succeeds; baseline used the unbounded indicative");
    }

    /// @dev Exact output, downside = paying MORE input than the baseline. The tier-1 candidate
    ///      quotes an optimistically low input while execution against real LP costs ~0.3% more
    ///      plus fees, tripping a 1% tolerance.
    function test_strictTolerance_exactOutput_deviationReverts() public {
        fillable.setPrice(90e18); // claimed input for 100e18 out; real cost ~100.4e18
        fillable.setEffectiveLiquidity(1e30, 1e30); // reserves cover the request: baseline = 90e18

        // Control run (no tolerance) captures the true executed input for the exact revert args.
        uint256 snap = vm.snapshotState();
        BalanceDelta control = swap(multiplexerPoolKey, true, 100e18, _hookData(_targets1(fillablePoolKey, 0), 0));
        uint256 executedInput = uint256(int256(-control.amount0()));
        assertGt(executedInput, 90e18, "sanity: execution costs more than the optimistic quote");
        vm.revertToState(snap);

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(multiplexer),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(ALFMultiplexer.QuoteDeviation.selector, 90e18, executedInput),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(multiplexerPoolKey, true, 100e18, _hookData(_targets1(fillablePoolKey, 0), 10_000));
    }

    /// @dev Exact output where the only candidate's declared reserves cannot deliver the
    ///      requested amount: its contribution is dropped, no baseline exists, and strict
    ///      tolerance refuses the swap rather than silently running unprotected.
    function test_strictTolerance_exactOutput_noDeliverableBaseline_reverts() public {
        fillable.setPrice(101e18);
        fillable.setEffectiveLiquidity(1, 1); // cannot deliver 100e18 of output

        vm.expectRevert(_wrapped(ALFMultiplexer.MissingQuoteBaseline.selector));
        swap(multiplexerPoolKey, true, 100e18, _hookData(_targets1(fillablePoolKey, 0), 10_000));
    }

    // ══════════════════════════════════════════════════════════
    //  Pre-planned mode: validation
    // ══════════════════════════════════════════════════════════

    function test_prePlanned_directionMismatch_reverts() public {
        // Exact-input outer with an exact-output leg.
        vm.expectRevert(_wrapped(ALFMultiplexer.TargetDirectionMismatch.selector));
        swap(multiplexerPoolKey, true, -100e18, _hookData(_targets2(quoterAPoolKey, 50e18, quoterBPoolKey, 0), 0));
    }

    function test_prePlanned_overAllocated_exactInput_reverts() public {
        vm.expectRevert(_wrapped(ALFMultiplexer.TargetsOverAllocated.selector));
        swap(multiplexerPoolKey, true, -100e18, _hookData(_targets2(quoterAPoolKey, -80e18, quoterBPoolKey, -80e18), 0));
    }

    function test_prePlanned_overAllocated_exactOutput_reverts() public {
        vm.expectRevert(_wrapped(ALFMultiplexer.TargetsOverAllocated.selector));
        swap(multiplexerPoolKey, true, 100e18, _hookData(_targets2(quoterAPoolKey, 80e18, quoterBPoolKey, 80e18), 0));
    }

    // ══════════════════════════════════════════════════════════
    //  Pre-planned mode: execution shapes
    // ══════════════════════════════════════════════════════════

    function test_prePlanned_selfTarget_skippedAndCatchAllFills() public {
        // A leg pointing back at the multiplexer is skipped (recursion guard); the catch-all
        // inherits the full budget.
        BalanceDelta delta = swap(
            multiplexerPoolKey, true, -100e18, _hookData(_targets2(multiplexerPoolKey, -50e18, quoterBPoolKey, 0), 0)
        );
        assertEq(delta.amount0(), -100e18, "full input consumed by the catch-all leg");
        assertGt(delta.amount1(), 0);
    }

    /// @dev Strict tolerance in pre-planned mode queries indicatives for the baseline. The
    ///      paused first leg yields no quote (and its fill soft-fails), while the healthy
    ///      catch-all sets the baseline and fills the full amount.
    function test_prePlanned_strictTolerance_baselineFromHealthyLeg() public {
        vm.prank(owner);
        quoterC.setPoolLive(quoterCPoolKey, false);

        BalanceDelta delta = swap(
            multiplexerPoolKey, true, -100e18, _hookData(_targets2(quoterCPoolKey, -10e18, quoterBPoolKey, 0), 500_000)
        );
        assertEq(delta.amount0(), -100e18, "catch-all absorbed the skipped leg's budget");
        assertGt(delta.amount1(), 0);
    }

    /// @dev A catch-all leg that only partially fills leaves a residual, and a later sized leg
    ///      larger than that residual must be clamped down to it; otherwise the aggregate would
    ///      exceed the swapper's stated amount.
    function test_prePlanned_sizedLegClampedToRemaining_exactInput() public {
        // quoterC (shallow) first as catch-all: absorbs only its band depth, leaving a residual
        // smaller than the sized quoterB leg (-990e18).
        BalanceDelta delta = swap(
            multiplexerPoolKey, true, -1_000e18, _hookData(_targets2(quoterCPoolKey, 0, quoterBPoolKey, -990e18), 0)
        );
        assertEq(delta.amount0(), -1_000e18, "aggregate input exactly matches the outer swap");
        assertGt(delta.amount1(), 0);
    }

    function test_prePlanned_sizedLegClampedToRemaining_exactOutput() public {
        BalanceDelta delta = swap(
            multiplexerPoolKey, true, 1_000e18, _hookData(_targets2(quoterCPoolKey, 0, quoterBPoolKey, 990e18), 0)
        );
        assertEq(delta.amount1(), 1_000e18, "aggregate output exactly matches the outer swap");
        assertLt(delta.amount0(), 0);
    }

    // ══════════════════════════════════════════════════════════
    //  Pure guard helpers (via harness)
    // ══════════════════════════════════════════════════════════

    function test_parseQuoteOrZero_acceptsQuoteSwapEncoding() public view {
        bytes memory reason = abi.encodeWithSelector(QuoterRevert.QuoteSwap.selector, uint256(42e18));
        assertEq(harness.parseQuoteOrZero(reason), 42e18);
    }

    function test_parseQuoteOrZero_rejectsWrongLength() public view {
        assertEq(harness.parseQuoteOrZero(hex"deadbeef"), 0, "4-byte reason rejected");
        assertEq(harness.parseQuoteOrZero(""), 0, "empty reason rejected");
        bytes memory tooLong = abi.encodeWithSelector(QuoterRevert.QuoteSwap.selector, uint256(1), uint256(2));
        assertEq(harness.parseQuoteOrZero(tooLong), 0, "68-byte reason rejected");
    }

    function test_parseQuoteOrZero_rejectsWrongSelectorAtExactLength() public view {
        // 36 bytes (selector + one word) but not QuoteSwap: must yield 0, not a bogus quote.
        bytes memory reason = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(42e18));
        assertEq(reason.length, 36, "setup: candidate-error shape");
        assertEq(harness.parseQuoteOrZero(reason), 0);
    }

    function test_toBeforeSwapDelta_revertsOnUnrepresentableDelta() public {
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

        vm.expectRevert(ALFMultiplexer.UnrepresentableDelta.selector);
        harness.toBeforeSwapDelta(toBalanceDelta(type(int128).min, 0), params);

        vm.expectRevert(ALFMultiplexer.UnrepresentableDelta.selector);
        harness.toBeforeSwapDelta(toBalanceDelta(0, type(int128).min), params);
    }
}
