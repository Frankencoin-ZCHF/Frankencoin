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
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {ALFMultiplexer} from "../../src/alf/ALFMultiplexer.sol";
import {SimpleSpreadQuoterHook} from "../../src/alf/SimpleSpreadQuoterHook.sol";
import {SpreadQuoterBase} from "../../src/alf/base/SpreadQuoterBase.sol";
import {SwapSimulator} from "../../src/alf/libraries/SwapSimulator.sol";
import {MultiplexerHookData, TargetedQuoter} from "../../src/alf/types/MultiplexerTypes.sol";
import {MockWaterfallHook} from "./mocks/MockWaterfallHook.sol";

/// @title ALFMultiplexerWaterfallTest
/// @notice Covers the four-tier multiplexer selection waterfall added on top of the original
///         IALFHook-only path. Each test forces a single tier to fire and verifies both the
///         selection result (via `quote()`) and the execution result (via `swap()`) end-to-end.
contract ALFMultiplexerWaterfallTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    int24 constant VANILLA_TICK_SPACING = 60;
    uint24 constant VANILLA_FEE = 3000; // 0.3%
    uint24 constant ALF_FEE = 50_000; // 5% — wide so the spread-quoter responses dominate the test pair
    uint24 constant MOCK_FEE_PIPS = 1_000; // 0.1% on MockWaterfallHook

    ALFMultiplexer public multiplexer;
    SimpleSpreadQuoterHook public quoterA;
    SimpleSpreadQuoterHook public quoterB;
    MockWaterfallHook public mockHook;

    address ownerA = makeAddr("ownerA");
    address ownerB = makeAddr("ownerB");

    PoolKey multiplexerPoolKey;
    PoolKey quoterAPoolKey;
    PoolKey quoterBPoolKey;
    PoolKey vanillaPoolKey; // No hook — exercises tier 2 (SwapSimulator).
    PoolKey mockPoolKey; // BEFORE_SWAP_RETURNS_DELTA hook — exercises tier 3 / tier 4.

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // ── Multiplexer ──
        uint160 multiplexerFlags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_DONATE_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        multiplexer = ALFMultiplexer(
            address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | multiplexerFlags))
        );
        deployCodeTo("ALFMultiplexer", abi.encode(manager), address(multiplexer));

        // ── Two ALF quoters (used only for the gas-baseline test) ──
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

        // ── MockWaterfallHook (BEFORE_SWAP + BEFORE_SWAP_RETURNS_DELTA, NOT simulator-safe) ──
        uint160 mockHookFlags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        mockHook = MockWaterfallHook(
            address(uint160((uint256(type(uint160).max) - (2 << 14)) & clearAllHookPermissionsMask | mockHookFlags))
        );
        deployCodeTo("MockWaterfallHook", abi.encode(manager), address(mockHook));
        mockHook.setFeePips(MOCK_FEE_PIPS);

        // ── Pool keys ──
        quoterAPoolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: ALF_FEE, tickSpacing: 60, hooks: IHooks(address(quoterA))
        });
        quoterBPoolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 10_000, tickSpacing: 60, hooks: IHooks(address(quoterB))
        });
        vanillaPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: VANILLA_FEE,
            tickSpacing: VANILLA_TICK_SPACING,
            hooks: IHooks(address(0))
        });
        mockPoolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 60, hooks: IHooks(address(mockHook))
        });
        multiplexerPoolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 1, hooks: IHooks(address(multiplexer))
        });

        // ── Initialize ──
        vm.prank(ownerA);
        quoterA.initializePool(quoterAPoolKey, TickMath.getSqrtPriceAtTick(30));
        vm.prank(ownerB);
        quoterB.initializePool(quoterBPoolKey, TickMath.getSqrtPriceAtTick(30));
        manager.initialize(vanillaPoolKey, Constants.SQRT_PRICE_1_1);
        manager.initialize(mockPoolKey, Constants.SQRT_PRICE_1_1);
        manager.initialize(multiplexerPoolKey, Constants.SQRT_PRICE_1_1);

        // ── Liquidity / inventory seeding ──
        vm.prank(ownerA);
        quoterA.setAuthorizedLP(address(modifyLiquidityRouter), true);
        vm.prank(ownerB);
        quoterB.setAuthorizedLP(address(modifyLiquidityRouter), true);
        _seedAtActiveTick(quoterAPoolKey, quoterA, 10_000e18, 10_000e18);
        _seedAtActiveTick(quoterBPoolKey, quoterB, 10_000e18, 10_000e18);
        vm.prank(ownerA);
        quoterA.setPoolLive(quoterAPoolKey, true);
        vm.prank(ownerB);
        quoterB.setPoolLive(quoterBPoolKey, true);

        // Vanilla pool: wide LP range straddling spot, deep enough that 1-token swaps stay in-range.
        _seedLP(vanillaPoolKey, -1200, 1200, 250_000e18, 250_000e18);

        // MockWaterfallHook: hold inventory directly so flash-accounting transfers succeed.
        MockERC20(Currency.unwrap(currency0)).mint(address(mockHook), 100_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(mockHook), 100_000e18);
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    //  TIER 2 — vanilla pool routed via SwapSimulator
    // ══════════════════════════════════════════════════════════════════════════════════════════

    /// @dev SwapSimulator must exactly match an actual swap on a vanilla CFMM pool with no hook.
    function test_simulator_matchesActualSwap_vanillaPool_exactIn() public {
        int256 amountSpecified = -1e18;
        bool zeroForOne = true;

        // Snapshot the pool, do a real swap, then revert state.
        uint256 snapId = vm.snapshotState();
        BalanceDelta delta = swap(vanillaPoolKey, zeroForOne, amountSpecified, "");
        // For exact-in zeroForOne, delta.amount1() is the output (positive).
        uint256 actualOut = uint256(int256(delta.amount1()));
        vm.revertToState(snapId);

        // Run the simulator against the post-revert (original) state.
        uint256 simulatedOut = SwapSimulator.simulateSwap(
            manager, vanillaPoolKey.toId(), zeroForOne, amountSpecified, VANILLA_FEE, VANILLA_TICK_SPACING
        );

        assertEq(simulatedOut, actualOut, "SwapSimulator must match actual swap output exactly");
    }

    function test_simulator_matchesActualSwap_vanillaPool_exactOut() public {
        int256 amountSpecified = 1e18; // exact-out: want exactly 1e18 of token1
        bool zeroForOne = true;

        uint256 snapId = vm.snapshotState();
        BalanceDelta delta = swap(vanillaPoolKey, zeroForOne, amountSpecified, "");
        // For exact-out zeroForOne, delta.amount0() is the input (negative).
        uint256 actualIn = uint256(int256(-delta.amount0()));
        vm.revertToState(snapId);

        uint256 simulatedIn = SwapSimulator.simulateSwap(
            manager, vanillaPoolKey.toId(), zeroForOne, amountSpecified, VANILLA_FEE, VANILLA_TICK_SPACING
        );

        assertEq(simulatedIn, actualIn, "SwapSimulator must match actual swap input exactly");
    }

    /// @dev The multiplexer's view-side `quote()` must return the simulator's number when the
    ///      only target is a vanilla pool — proving tier 2 selection wires through correctly.
    function test_multiplexer_quote_routesVanillaPoolViaSimulator() public view {
        int256 amountSpecified = -1e18;
        TargetedQuoter[] memory targets = new TargetedQuoter[](1);
        targets[0] = TargetedQuoter({poolKey: vanillaPoolKey, amountSpecified: 0});

        (,, uint256 bestQuote,) = multiplexer.quote(true, amountSpecified, _buildHookData(targets));

        uint256 expected = SwapSimulator.simulateSwap(
            manager, vanillaPoolKey.toId(), true, amountSpecified, VANILLA_FEE, VANILLA_TICK_SPACING
        );
        assertEq(bestQuote, expected, "multiplexer should report simulator quote for vanilla pool");
        assertGt(bestQuote, 0, "non-zero quote expected");
    }

    /// @dev End-to-end: autonomous-mode swap with a single vanilla target. The multiplexer
    ///      should select tier 2, fill the vanilla pool, and produce a delta that matches what
    ///      a direct swap on that pool would have produced.
    function test_multiplexer_swap_executesAgainstVanillaPool() public {
        int256 amountSpecified = -1e18;
        TargetedQuoter[] memory targets = new TargetedQuoter[](1);
        targets[0] = TargetedQuoter({poolKey: vanillaPoolKey, amountSpecified: 0});

        // Reference: what would a direct swap return?
        uint256 snapId = vm.snapshotState();
        BalanceDelta direct = swap(vanillaPoolKey, true, amountSpecified, "");
        uint256 directOut = uint256(int256(direct.amount1()));
        vm.revertToState(snapId);

        // Route the same swap through the multiplexer.
        BalanceDelta routed = swap(multiplexerPoolKey, true, amountSpecified, _buildHookData(targets));
        assertEq(routed.amount0(), amountSpecified, "specified side should equal input");
        uint256 routedOut = uint256(int256(routed.amount1()));
        assertEq(routedOut, directOut, "multiplexer-routed output must equal direct-swap output");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    //  TIER 3 — IIndicativeQuote hook
    // ══════════════════════════════════════════════════════════════════════════════════════════

    /// @dev When the target advertises IIndicativeQuote via ERC-165, the multiplexer must call
    ///      `indicativeQuote` and trust its return value.
    function test_tier3_quote_callsIndicativeQuote() public {
        mockHook.setClaimIndicativeQuote(true);
        mockHook.setIndicativeQuoteOverride(1337);

        TargetedQuoter[] memory targets = new TargetedQuoter[](1);
        targets[0] = TargetedQuoter({poolKey: mockPoolKey, amountSpecified: 0});

        (,, uint256 bestQuote,) = multiplexer.quote(true, -1e18, _buildHookData(targets));
        assertEq(bestQuote, 1337, "tier 3 should return the hook's indicativeQuote value verbatim");
    }

    /// @dev Even if the hook claims IIndicativeQuote but reverts in the actual call, tier 3
    ///      catches the revert. From `quote()`'s perspective (view-only), the target ends up
    ///      filtered out and the call reverts with `NoValidQuotes` if it's the only candidate.
    function test_tier3_quoteRevert_filtersTargetInViewPath() public {
        mockHook.setClaimIndicativeQuote(true);
        mockHook.setIndicativeQuoteReverts(true);

        TargetedQuoter[] memory targets = new TargetedQuoter[](1);
        targets[0] = TargetedQuoter({poolKey: mockPoolKey, amountSpecified: 0});

        vm.expectRevert(ALFMultiplexer.NoValidQuotes.selector);
        multiplexer.quote(true, -1e18, _buildHookData(targets));
    }

    /// @dev In the actual-swap path (autonomous mode), a reverting `indicativeQuote` causes the
    ///      view-tier to return 0, and `_queryTargetBySwap` falls through to tier 4 (reverting
    ///      self-swap). The mock hook still executes its real beforeSwap, so the swap completes.
    function test_tier3_quoteRevert_fallsThroughToTier4_andExecutes() public {
        mockHook.setClaimIndicativeQuote(true);
        mockHook.setIndicativeQuoteReverts(true);

        TargetedQuoter[] memory targets = new TargetedQuoter[](1);
        targets[0] = TargetedQuoter({poolKey: mockPoolKey, amountSpecified: 0});

        // Swap should succeed even though `indicativeQuote` reverts.
        BalanceDelta routed = swap(multiplexerPoolKey, true, -1e18, _buildHookData(targets));
        assertEq(routed.amount0(), -1e18, "specified side equals input");
        // MockWaterfallHook applies feePips=1000 (0.1%) → 0.999e18 output.
        assertEq(uint256(int256(routed.amount1())), 0.999e18, "tier 4 reverting-swap quote produced execution");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    //  TIER 4 — opaque hook reaches reverting-swap fallback
    // ══════════════════════════════════════════════════════════════════════════════════════════

    /// @dev Hook does NOT claim IIndicativeQuote and is not simulator-safe. Multiplexer must
    ///      fall through to tier 4 reverting-swap and still produce a quote + execute the swap.
    function test_tier4_opaqueHook_routesViaRevertingSwap() public {
        // Default state: claimIndicativeQuote=false, no overrides. This is the "opaque hook" case.
        mockHook.setClaimIndicativeQuote(false);

        TargetedQuoter[] memory targets = new TargetedQuoter[](1);
        targets[0] = TargetedQuoter({poolKey: mockPoolKey, amountSpecified: 0});

        // `quote()` is view-only; tier 4 (state-mutating) is unreachable there → no valid quote.
        vm.expectRevert(ALFMultiplexer.NoValidQuotes.selector);
        multiplexer.quote(true, -1e18, _buildHookData(targets));

        // But the actual execution path runs the reverting self-swap, gets a quote, then executes.
        BalanceDelta routed = swap(multiplexerPoolKey, true, -1e18, _buildHookData(targets));
        assertEq(routed.amount0(), -1e18);
        assertEq(uint256(int256(routed.amount1())), 0.999e18, "opaque hook executed via tier 4");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    //  TIER 2 — dynamic-fee pool (simulator-safe: no `BEFORE_SWAP_FLAG`) quotes via slot0.lpFee.
    //
    //  V4 only allows per-swap fee overrides when the hook has `BEFORE_SWAP_FLAG`. Without that
    //  flag, the fee applied at swap is exactly `slot0.lpFee`, so the simulator will exactly
    //  match the execution within the same call frame as `quote()`.
    // ══════════════════════════════════════════════════════════════════════════════════════════

    /// @dev V4 requires `hooks != address(0)` for dynamic-fee pools but allows zero permission
    ///      flags. We use a no-code, high-bit-only address so `_supportsInterface` short-circuits
    ///      on `code.length == 0` and the manager never tries to call into the hook.
    function test_tier2_dynamicFeePool_usesSlot0Fee() public {
        IHooks zeroFlagsHook = IHooks(address(uint160(1 << 20))); // bits 0..13 (permission flags) all clear
        PoolKey memory dynamicFeeKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: VANILLA_TICK_SPACING,
            hooks: zeroFlagsHook
        });
        manager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);
        _seedLP(dynamicFeeKey, -1200, 1200, 250_000e18, 250_000e18);

        // Push a non-zero dynamic fee so the slot0 read is actually meaningful (default is 0).
        // updateDynamicLPFee is gated on msg.sender == address(key.hooks); impersonate it.
        uint24 dynamicLpFee = 3000; // 0.3%
        vm.prank(address(zeroFlagsHook));
        manager.updateDynamicLPFee(dynamicFeeKey, dynamicLpFee);
        (,,, uint24 actualSlot0Fee) = manager.getSlot0(dynamicFeeKey.toId());
        assertEq(actualSlot0Fee, dynamicLpFee, "slot0 fee should reflect the update");

        int256 amountSpecified = -1e18;
        TargetedQuoter[] memory targets = new TargetedQuoter[](1);
        targets[0] = TargetedQuoter({poolKey: dynamicFeeKey, amountSpecified: 0});

        // View-side: the multiplexer should hit tier 2 and quote with the slot0 fee, not 0.
        (,, uint256 bestQuote,) = multiplexer.quote(true, amountSpecified, _buildHookData(targets));
        uint256 expected = SwapSimulator.simulateSwap(
            manager, dynamicFeeKey.toId(), true, amountSpecified, dynamicLpFee, VANILLA_TICK_SPACING
        );
        assertEq(bestQuote, expected, "tier 2 dynamic-fee quote must use slot0.lpFee");
        assertGt(bestQuote, 0, "non-zero quote expected");

        // End-to-end: routed execution exactly matches a direct swap on the dynamic-fee pool.
        uint256 snapId = vm.snapshotState();
        BalanceDelta direct = swap(dynamicFeeKey, true, amountSpecified, "");
        uint256 directOut = uint256(int256(direct.amount1()));
        vm.revertToState(snapId);

        BalanceDelta routed = swap(multiplexerPoolKey, true, amountSpecified, _buildHookData(targets));
        assertEq(routed.amount0(), amountSpecified);
        assertEq(uint256(int256(routed.amount1())), directOut, "tier 2 execution matches direct swap exactly");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    //  TIER 1 baseline — lock the gas profile so a regression that re-adds the reverting-swap
    //  verification step would be caught.
    // ══════════════════════════════════════════════════════════════════════════════════════════

    function test_gas_autonomousSelection_alfOnly_twoCandidates() public {
        TargetedQuoter[] memory targets = new TargetedQuoter[](2);
        targets[0] = TargetedQuoter({poolKey: quoterAPoolKey, amountSpecified: 0});
        targets[1] = TargetedQuoter({poolKey: quoterBPoolKey, amountSpecified: 0});

        swap(multiplexerPoolKey, true, -1e18, _buildHookData(targets));
        vm.snapshotGasLastCall("ALFMultiplexer_autonomous_alfOnly_twoCandidates");
    }

    // ──── helpers ────

    function _buildHookData(TargetedQuoter[] memory targets) internal pure returns (bytes memory) {
        return abi.encode(MultiplexerHookData({attestationData: "", targets: targets, strictTolerancePips: 0}));
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

    function _seedLP(PoolKey memory key_, int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1) internal {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key_.toId());
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );
        modifyLiquidityRouter.modifyLiquidity(
            key_,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int128(liq), salt: 0}),
            ""
        );
    }
}
