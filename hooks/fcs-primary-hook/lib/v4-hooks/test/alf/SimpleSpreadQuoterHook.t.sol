// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SimpleSpreadQuoterHook} from "../../src/alf/SimpleSpreadQuoterHook.sol";
import {SpreadQuoterBase} from "../../src/alf/base/SpreadQuoterBase.sol";
import {OwnedALFHook} from "../../src/alf/base/OwnedALFHook.sol";
import {SwapSimulator} from "../../src/alf/libraries/SwapSimulator.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

contract SimpleSpreadQuoterHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    SimpleSpreadQuoterHook public hook;

    address owner = makeAddr("owner");

    PoolKey testPoolKey;

    // Fee pips for tests: 20_000 pips = 2%
    uint24 constant FEE_PIPS = 20_000;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // Deploy hook at flag-mined address.
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG
        );
        hook =
            SimpleSpreadQuoterHook(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags)));
        deployCodeTo("SimpleSpreadQuoterHook", abi.encode(manager, uint32(50_000), owner), address(hook));

        // Create pool key with static fee (`PoolKey.fee`)
        testPoolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: FEE_PIPS, tickSpacing: 60, hooks: IHooks(address(hook))
        });

        // Initialize pool at tick 90 via owner-only `initializePool` — direct
        // `manager.initialize` is now blocked. The choice of 90 (with tickSpacing=60)
        // floor-aligns to 60 -- deliberately NOT 0 so subsequent assertions on
        // `activeLowerTick` distinguish a working derivation from the mapping's `int24(0)`
        // default. A historical setup used tick 30 here, which floor-aligned to 0 and
        // silently passed the active-tick assertion even when the derivation never ran.
        // 90 is also mid-range within [60, 120], and the price (~1.009) is close enough
        // to 1 that the existing swap-fee tests' price-impact tolerances still hold.
        vm.prank(owner);
        hook.initializePool(testPoolKey, TickMath.getSqrtPriceAtTick(90));

        // Authorize the modifyLiquidityRouter for LP operations
        vm.prank(owner);
        hook.setAuthorizedLP(address(modifyLiquidityRouter), true);

        // Add LP at the active tick (single-tick concentration)
        _seedAtActiveTick(testPoolKey, 10_000e18, 10_000e18);

        // Activate the pool for swaps (defaults to paused after manager.initialize)
        vm.prank(owner);
        hook.setPoolLive(testPoolKey, true);
    }

    // ──── Helpers ────

    function _seedAtActiveTick(PoolKey memory key_, uint256 amount0, uint256 amount1) internal {
        int24 activeTick = hook.activeLowerTick(key_.toId());
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

    // ──── initializePool active-tick derivation ────

    /// @dev `initializePool` derives `activeLowerTick` inline from the tick returned by
    ///      `poolManager.initialize`. With tickSpacing=60 and init tick 90, floor(90/60)*60 = 60
    ///      -- a value that is distinguishable from the mapping's `int24(0)` default, so this
    ///      assertion fails if the derivation ever stops running.
    function test_initializePool_setsActiveLowerTick() public view {
        assertEq(hook.activeLowerTick(testPoolKey.toId()), int24(60));
    }

    /// @dev Cover multiple initial ticks to confirm `_setActiveTickFromInitialTick`'s
    ///      floor-align + clamp logic, including the negative-tick floor adjustment and
    ///      the MIN/MAX-usable clamp. Boundary ticks use `MIN_TICK + 1` / `MAX_TICK - 1`
    ///      because `poolManager.initialize` rejects `sqrtPrice == MIN_SQRT_PRICE` and
    ///      `sqrtPrice == MAX_SQRT_PRICE` (the bound is strict).
    function test_initializePool_setsActiveLowerTick_acrossTicks() public {
        int24[5] memory inits = [int24(-887271), int24(-150), int24(0), int24(150), int24(887271)];
        // -887271: negative non-aligned → compressed `--` → candidate -887280, below minUsable(60)=-887220 → clamp UP
        // -150:    floor(-150/60)*60 with negative adjustment → -180
        //  0:      floor(0/60)*60 = 0
        //  150:    floor(150/60)*60 = 120
        //  887271: floor(887271/60)*60 = 887220, ABOVE maxLower = maxUsable(60)-60 = 887160 → clamp DOWN
        int24 minUsable = TickMath.minUsableTick(60);
        int24 maxLower = TickMath.maxUsableTick(60) - 60;
        int24[5] memory expected = [minUsable, int24(-180), int24(0), int24(120), maxLower];

        for (uint256 i; i < inits.length; i++) {
            PoolKey memory k = PoolKey({
                currency0: currency0,
                currency1: currency1,
                fee: FEE_PIPS,
                tickSpacing: 60,
                // Vary salt-like field by using a different tickSpacing per iteration would
                // change PoolId; instead use a different hooks pointer? No -- need same hook.
                // Easier: vary fee by index so each iteration is a distinct PoolId.
                hooks: IHooks(address(hook))
            });
            // Bump fee per iteration to get a distinct PoolId; offset by 100 so iteration 0
            // doesn't collide with `testPoolKey` (which uses `fee = FEE_PIPS`).
            k.fee = FEE_PIPS + 100 + uint24(i);

            vm.prank(owner);
            hook.initializePool(k, TickMath.getSqrtPriceAtTick(inits[i]));
            assertEq(hook.activeLowerTick(k.toId()), expected[i], "active tick mismatch");
        }
    }

    /// @dev `key.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG` would leave `slot0.lpFee` at 0 forever
    ///      (no fee-update entry point exists) and every swap would charge zero LP fee.
    ///      `initializePool` rejects the configuration at the boundary.
    function test_initializePool_revertsOnDynamicFeeFlag() public {
        PoolKey memory dynKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        vm.prank(owner);
        vm.expectRevert(SpreadQuoterBase.DynamicFeeNotSupported.selector);
        hook.initializePool(dynKey, TickMath.getSqrtPriceAtTick(0));
    }

    // ──── init gating ────

    /// @dev Direct `manager.initialize` on a SpreadQuoter pool MUST revert. Without the
    ///      `_beforeInitialize` gate, an attacker could front-run an operator-planned launch
    ///      and pin the pool's `sqrtPriceX96` (immutable for the pool's lifetime) to a
    ///      price the operator did not choose.
    function test_directInitialize_reverts() public {
        PoolKey memory unowned = PoolKey({
            currency0: currency0, currency1: currency1, fee: FEE_PIPS, tickSpacing: 30, hooks: IHooks(address(hook))
        });
        vm.expectRevert();
        manager.initialize(unowned, TickMath.getSqrtPriceAtTick(0));
    }

    /// @dev `initializePool` is `onlyOwner` — non-owners cannot bypass the gate via the
    ///      hook's own entry point either.
    function test_initializePool_onlyOwner() public {
        PoolKey memory unowned = PoolKey({
            currency0: currency0, currency1: currency1, fee: FEE_PIPS, tickSpacing: 30, hooks: IHooks(address(hook))
        });
        vm.expectRevert();
        hook.initializePool(unowned, TickMath.getSqrtPriceAtTick(0));
    }

    // ──── LP authorization ────

    function test_addLiquidity_unauthorized_reverts() public {
        int24 activeTick = hook.activeLowerTick(testPoolKey.toId());

        // Revoke the router's authorization
        vm.prank(owner);
        hook.setAuthorizedLP(address(modifyLiquidityRouter), false);

        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            testPoolKey,
            ModifyLiquidityParams({
                tickLower: activeTick,
                tickUpper: activeTick + testPoolKey.tickSpacing,
                liquidityDelta: 1e18,
                salt: bytes32(uint256(1))
            }),
            ""
        );
    }

    function test_removeLiquidity_unauthorized_reverts() public {
        int24 activeTick = hook.activeLowerTick(testPoolKey.toId());

        // Revoke the router's authorization
        vm.prank(owner);
        hook.setAuthorizedLP(address(modifyLiquidityRouter), false);

        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            testPoolKey,
            ModifyLiquidityParams({
                tickLower: activeTick, tickUpper: activeTick + testPoolKey.tickSpacing, liquidityDelta: -1e18, salt: 0
            }),
            ""
        );
    }

    function test_setAuthorizedLP_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.setAuthorizedLP(makeAddr("someone"), true);
    }

    function test_setAuthorizedLP_grantsAndRevokes() public {
        address lp = makeAddr("lp");

        vm.prank(owner);
        hook.setAuthorizedLP(lp, true);
        assertTrue(hook.authorizedLPs(lp));

        vm.prank(owner);
        hook.setAuthorizedLP(lp, false);
        assertFalse(hook.authorizedLPs(lp));
    }

    // ──── Tick enforcement ────

    function test_addLiquidity_wrongTickRange_reverts() public {
        // Try adding with a range wider than one tick spacing
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            testPoolKey,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: bytes32(uint256(1))}),
            ""
        );
    }

    function test_addLiquidity_wrongActiveTick_reverts() public {
        int24 activeTick = hook.activeLowerTick(testPoolKey.toId());

        // Correct width but wrong starting tick
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            testPoolKey,
            ModifyLiquidityParams({
                tickLower: activeTick + testPoolKey.tickSpacing,
                tickUpper: activeTick + 2 * testPoolKey.tickSpacing,
                liquidityDelta: 1e18,
                salt: bytes32(uint256(1))
            }),
            ""
        );
    }

    /// @dev Setting the same active tick is an idempotent no-op -- the band-empty guard is
    ///      bypassed because no relocation is happening. This is the only valid call shape
    ///      while LP is seeded at the current active tick.
    function test_setActiveTick_sameTickIsIdempotentNoOp() public {
        int24 currentActive = hook.activeLowerTick(testPoolKey.toId());
        vm.prank(owner);
        hook.setActiveTick(testPoolKey, currentActive);
        assertEq(hook.activeLowerTick(testPoolKey.toId()), currentActive);
    }

    /// @dev Operator footgun guard: refusing to relocate the active band while liquidity
    ///      still references the old tick prevents an orphaned-position scenario where the
    ///      old-band LP sits in v4 outside the hook's enforced range. setUp seeds LP at
    ///      tick 60 (the initial active tick); a relocation to 120 must revert.
    function test_setActiveTick_revertsWhenOldBandHasLiquidity() public {
        int24 oldActive = hook.activeLowerTick(testPoolKey.toId());
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SpreadQuoterBase.ActiveTickBandNonEmpty.selector, oldActive));
        hook.setActiveTick(testPoolKey, oldActive + int24(60));
    }

    /// @dev After fully draining the prior band, relocation succeeds. Confirms the guard is
    ///      gated on the liquidity-gross check, not a permanent lock.
    function test_setActiveTick_succeedsAfterDrainingOldBand() public {
        int24 oldActive = hook.activeLowerTick(testPoolKey.toId());

        // Drain all LP at the old band. The setUp seeded via `_seedAtActiveTick` with the
        // modifyLiquidityRouter as authorized LP; remove the position entirely.
        uint128 currentLiq = manager.getLiquidity(testPoolKey.toId());
        modifyLiquidityRouter.modifyLiquidity(
            testPoolKey,
            ModifyLiquidityParams({
                tickLower: oldActive,
                tickUpper: oldActive + testPoolKey.tickSpacing,
                liquidityDelta: -int128(currentLiq),
                salt: 0
            }),
            ""
        );

        int24 newActive = oldActive + int24(60);
        vm.prank(owner);
        hook.setActiveTick(testPoolKey, newActive);
        assertEq(hook.activeLowerTick(testPoolKey.toId()), newActive);
    }

    function test_setActiveTick_unaligned_reverts() public {
        vm.prank(owner);
        vm.expectRevert();
        hook.setActiveTick(testPoolKey, int24(13)); // not aligned to tickSpacing=60
    }

    function test_setActiveTick_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.setActiveTick(testPoolKey, int24(60));
    }

    // ──── getIndicativeQuote (AMM simulation) ────

    function test_getIndicativeQuote_zeroForOne() public view {
        uint256 output = hook.getIndicativeQuote(testPoolKey, true, -100e18, "");
        // Simulates AMM swap with 2% fee → ~98e18 output (minimal price impact)
        assertApproxEqRel(output, 98e18, 0.01e18);
    }

    function test_getIndicativeQuote_oneForZero() public view {
        uint256 output = hook.getIndicativeQuote(testPoolKey, false, -100e18, "");
        // Simulates AMM swap with 2% fee → ~98e18 output (symmetric)
        assertApproxEqRel(output, 98e18, 0.01e18);
    }

    function test_getIndicativeQuote_unlivePool_returnsZero() public {
        vm.prank(owner);
        hook.setPoolLive(testPoolKey, false);

        uint256 output = hook.getIndicativeQuote(testPoolKey, true, -100e18, "");
        assertEq(output, 0);
    }

    function test_getIndicativeQuote_noLiquidity_returnsZero() public {
        // Create a fresh pool with no LP
        PoolKey memory emptyPoolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: FEE_PIPS, tickSpacing: 10, hooks: IHooks(address(hook))
        });
        vm.prank(owner);
        hook.initializePool(emptyPoolKey, Constants.SQRT_PRICE_1_1);

        vm.prank(owner);
        hook.setPoolLive(emptyPoolKey, true);

        // No liquidity → simulation returns 0
        uint256 output = hook.getIndicativeQuote(emptyPoolKey, true, -1e18, "");
        assertEq(output, 0);
    }

    /// @dev Regression for `SwapSimulator._walkTicks`'s `MAX_WALK_STEPS` cap. Pre-cap, an
    ///      empty pool with `tickSpacing=1` would walk roughly 7K bitmap words from the init
    ///      tick to `MIN_SQRT_PRICE + 1`, burning tens of millions of gas on a single
    ///      `getIndicativeQuote`. Wrap the call in a tight gas envelope (well below what an
    ///      unbounded walk would need) and assert it completes and returns 0; a regression
    ///      that removes the cap would OOG and surface here.
    function test_getIndicativeQuote_boundedGas_onEmptyPool() public {
        PoolKey memory emptyPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: FEE_PIPS,
            tickSpacing: 1, // worst case for the bitmap walk
            hooks: IHooks(address(hook))
        });
        vm.prank(owner);
        hook.initializePool(emptyPoolKey, Constants.SQRT_PRICE_1_1);
        vm.prank(owner);
        hook.setPoolLive(emptyPoolKey, true);

        // 25M gas comfortably exceeds the cap's ~20M worst case but is well below the
        // ~35M+ an unbounded walk would consume at tickSpacing=1.
        (bool ok, bytes memory data) = address(hook).staticcall{gas: 25_000_000}(
            abi.encodeWithSignature(
                "getIndicativeQuote((address,address,uint24,int24,address),bool,int256,bytes)",
                emptyPoolKey,
                true,
                int256(-1e18),
                bytes("")
            )
        );
        assertTrue(ok, "quote must complete within bounded gas");
        assertEq(abi.decode(data, (uint256)), 0, "empty pool quote must be 0");
    }

    function test_getIndicativeQuote_matchesSwapExecution() public {
        // Indicative quote should closely match actual swap output
        uint256 indicative = hook.getIndicativeQuote(testPoolKey, true, -1e18, "");

        BalanceDelta delta = swap(testPoolKey, true, -1e18, "");
        uint256 actual = uint256(int256(delta.amount1()));

        // Should be very close — same fee, same pool state
        assertEq(indicative, actual);
    }

    // ──── swapToPrice: soft-fail on invalid sqrtPriceLimitX96 ────
    //
    //  `Pool.swap` rejects limits on the wrong side of the current price or at/past
    //  `MIN_SQRT_PRICE` / `MAX_SQRT_PRICE` with `PriceLimitAlreadyExceeded` /
    //  `PriceLimitOutOfBounds`. `SwapSimulator.simulateSwapToPrice` mirrors those guards
    //  but soft-fails to `(0, 0)` so off-chain planners can rely on the invariant
    //  `(0, 0) ⇔ untradable`. Without these checks, a wrong-side limit returned a
    //  numerically valid but fictional non-zero tuple describing a swap that could never
    //  execute, leading planners to schedule unfillable legs.

    /// @dev Positive control: with a valid limit, swapToPrice returns non-zero -- confirms
    ///      the soft-fail guards don't accidentally zero out legitimate quotes.
    function test_swapToPrice_returnsNonZero_whenLimitIsValid() public view {
        (uint160 current,,,) = manager.getSlot0(testPoolKey.toId());
        // zeroForOne: valid limit must be strictly between MIN_SQRT_PRICE and current.
        uint160 validZeroForOneLimit = uint160(uint256(current) - 1);
        (uint256 ain, uint256 aout) = hook.swapToPrice(testPoolKey, true, -1e18, validZeroForOneLimit, "");
        assertGt(ain + aout, 0, "valid zeroForOne limit must produce a quote");

        // oneForZero: valid limit must be strictly between current and MAX_SQRT_PRICE.
        uint160 validOneForZeroLimit = uint160(uint256(current) + 1);
        (uint256 bin, uint256 bout) = hook.swapToPrice(testPoolKey, false, -1e18, validOneForZeroLimit, "");
        assertGt(bin + bout, 0, "valid oneForZero limit must produce a quote");
    }

    /// @dev Regime 1: limit on the wrong side of the current price. Pre-fix, the simulator
    ///      computed a fictional opposite-direction step and returned non-zero whenever
    ///      current-tick liquidity was non-zero (which it is in this fixture). Post-fix,
    ///      both directions soft-fail.
    function test_swapToPrice_returnsZero_whenLimitOnWrongSide() public view {
        (uint160 current,,,) = manager.getSlot0(testPoolKey.toId());

        // zeroForOne (price moves DOWN) with limit at/above current is wrong-side.
        (uint256 ain, uint256 aout) = hook.swapToPrice(testPoolKey, true, -1e18, current, "");
        assertEq(ain, 0, "zeroForOne, limit == current");
        assertEq(aout, 0, "zeroForOne, limit == current");
        (ain, aout) = hook.swapToPrice(testPoolKey, true, -1e18, uint160(uint256(current) + 1), "");
        assertEq(ain, 0, "zeroForOne, limit > current");
        assertEq(aout, 0, "zeroForOne, limit > current");

        // oneForZero (price moves UP) with limit at/below current is wrong-side.
        (ain, aout) = hook.swapToPrice(testPoolKey, false, -1e18, current, "");
        assertEq(ain, 0, "oneForZero, limit == current");
        assertEq(aout, 0, "oneForZero, limit == current");
        (ain, aout) = hook.swapToPrice(testPoolKey, false, -1e18, uint160(uint256(current) - 1), "");
        assertEq(ain, 0, "oneForZero, limit < current");
        assertEq(aout, 0, "oneForZero, limit < current");
    }

    /// @dev Regime 2: limit exactly at `MIN_SQRT_PRICE` / `MAX_SQRT_PRICE`. `Pool.swap`'s
    ///      bounds are strict (`<= MIN_SQRT_PRICE` and `>= MAX_SQRT_PRICE` both revert), so
    ///      the simulator soft-fails at equality to maintain parity.
    function test_swapToPrice_returnsZero_whenLimitAtBoundary() public view {
        (uint256 ain, uint256 aout) = hook.swapToPrice(testPoolKey, true, -1e18, TickMath.MIN_SQRT_PRICE, "");
        assertEq(ain, 0);
        assertEq(aout, 0);

        (ain, aout) = hook.swapToPrice(testPoolKey, false, -1e18, TickMath.MAX_SQRT_PRICE, "");
        assertEq(ain, 0);
        assertEq(aout, 0);
    }

    /// @dev Regime 3: limit past the representable boundary. Pre-fix, the tick-walk could
    ///      not terminate (target price unreachable), running to the iteration cap and
    ///      returning a non-zero tuple. Post-fix, soft-fails immediately.
    function test_swapToPrice_returnsZero_whenLimitPastBoundary() public view {
        // For zeroForOne, "past MIN" means any value below MIN_SQRT_PRICE down to 0.
        (uint256 ain, uint256 aout) = hook.swapToPrice(testPoolKey, true, -1e18, uint160(0), "");
        assertEq(ain, 0);
        assertEq(aout, 0);

        // For oneForZero, "past MAX" means any value above MAX_SQRT_PRICE up to uint160.max.
        (ain, aout) = hook.swapToPrice(testPoolKey, false, -1e18, type(uint160).max, "");
        assertEq(ain, 0);
        assertEq(aout, 0);
    }

    /// @dev A paused pool must not produce a price-bounded simulation: routers reading
    ///      `swapToPrice` for split planning would otherwise plan flow into a pool whose
    ///      `beforeSwap` rejects it.
    function test_swapToPrice_pausedPool_returnsZero() public {
        vm.prank(owner);
        hook.setPoolLive(testPoolKey, false);

        (uint256 ain, uint256 aout) = hook.swapToPrice(testPoolKey, true, -1e18, TickMath.MIN_SQRT_PRICE + 1, "");
        assertEq(ain, 0, "paused pool simulates no input");
        assertEq(aout, 0, "paused pool simulates no output");
    }

    /// @dev `initializePool` must reject a PoolKey referencing a different hook: accepting it
    ///      would register active-tick state for a pool this hook does not serve.
    function test_initializePool_revertsOnWrongHookAddress() public {
        PoolKey memory foreign = PoolKey({
            currency0: currency0, currency1: currency1, fee: FEE_PIPS, tickSpacing: 60, hooks: IHooks(address(0xBEEF))
        });
        vm.prank(owner);
        vm.expectRevert(SpreadQuoterBase.InvalidHookAddress.selector);
        hook.initializePool(foreign, Constants.SQRT_PRICE_1_1);
    }

    /// @dev Defense-in-depth: `SwapSimulator` validates `lpFeePips <= MAX_SWAP_FEE` (1e6)
    ///      directly so out-of-range fees fail fast with a clear `InvalidLpFeePips` error
    ///      instead of corrupting `SwapMath.computeSwapStep`'s unchecked subtraction.
    ///      Triggered here by forcing the hook to forward a `DYNAMIC_FEE_FLAG`-bearing fee
    ///      via `_staticFee`'s pre-strip being bypassed -- we exercise the library directly
    ///      through a low-level call with a synthetic out-of-range fee.
    function test_simulateSwapToPrice_revertsOnInvalidFee() public {
        // Drive the library through a thin wrapper: deploy a tiny helper that exposes
        // simulateSwapToPrice with caller-controlled lpFeePips, bypassing the hook's
        // `_staticFee` strip. We use vm.expectRevert with the library's typed selector.
        SwapSimulatorHarness harness = new SwapSimulatorHarness();
        uint24 invalidFee = LPFeeLibrary.MAX_LP_FEE + 1; // exactly one over the bound
        vm.expectRevert(abi.encodeWithSelector(SwapSimulator.InvalidLpFeePips.selector, invalidFee));
        harness.simulateSwapToPrice(
            manager, testPoolKey.toId(), true, -1e18, invalidFee, testPoolKey.tickSpacing, TickMath.MIN_SQRT_PRICE + 1
        );
    }

    /// @dev Regression for the post-loop `int128` bounds check that mirrors `Pool.swap`'s
    ///      final `toInt128()` cast (`SafeCastOverflow`). The trigger: a near-`MAX_LP_FEE`
    ///      pool (fee multiplier `MAX_SWAP_FEE / (MAX_SWAP_FEE - fee) ≈ 1e6`) seeded with
    ///      `uint128.max` liquidity. A modest exact-output ask drives a base `amountIn`
    ///      that, once multiplied by the fee factor, pushes cumulative `amountIn +
    ///      feeAmount` past `int128.max`. `Pool.swap` reverts (`SafeCastOverflow`); the
    ///      simulator must soft-fail to `(0, 0)` rather than return the pre-cast int256
    ///      garbage value that would slip past the limit guards.
    function test_simulateSwapToPrice_softFailsOnInt128Overflow() public {
        uint24 nearMaxFee = uint24(LPFeeLibrary.MAX_LP_FEE - 1); // 999_999 = 99.9999%
        // tickSpacing 600 lets `maxLiquidityPerTick` reach ~1.15e35 (vs ~1.15e34 at
        // spacing 60), which combined with the wider band [0, 600] produces a base
        // amountIn large enough to overflow int128 once multiplied by the fee factor.
        PoolKey memory extremeKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: nearMaxFee, tickSpacing: 600, hooks: IHooks(address(hook))
        });

        vm.prank(owner);
        hook.initializePool(extremeKey, TickMath.getSqrtPriceAtTick(0));

        // Math: oneForZero from `tick 0` to `tick 600` has `Δ_sqrtP / 2^96 ≈ 0.03`, so
        // base `amount1_in ≈ L * 0.03`. With L = 1e34: base ≈ 3e32. At fee 999_999
        // (multiplier ≈ 1e6), cumulative `amountIn + feeAmount ≈ 3e38` -- past
        // `int128.max` (~1.7e38), so Pool.swap reverts at its final `toInt128()` cast.
        int256 hugeLiquidity = 1e34;
        uint256 hugeBalance = type(uint256).max / 2;
        deal(Currency.unwrap(currency0), address(this), hugeBalance);
        deal(Currency.unwrap(currency1), address(this), hugeBalance);
        modifyLiquidityRouter.modifyLiquidity(
            extremeKey,
            ModifyLiquidityParams({
                tickLower: 0, tickUpper: extremeKey.tickSpacing, liquidityDelta: hugeLiquidity, salt: 0
            }),
            ""
        );

        vm.prank(owner);
        hook.setPoolLive(extremeKey, true);

        // oneForZero exact-output. Ask for an amount large enough to push price all the
        // way to the band's upper edge, draining the LP capacity. With L=1e35, full-band
        // drain produces ~3e32 base input → ~3e38 with fee multiplier → overflows int128.
        int256 modestOutput = int256(type(int128).max); // ensures we drain the band
        uint160 limit = TickMath.MAX_SQRT_PRICE - 1; // unbounded — drain LP, don't clamp at tick 60

        // Leg 1: the live `Pool.swap` rejects this configuration. The revert path is
        // `SafeCast.toInt128()` inside `Pool.swap`'s final delta construction -- this is
        // PoolManager-internal, NOT a hook callback, so v4's `Hooks.callHook` wrapping
        // does not apply and the bare `SafeCastOverflow()` selector reaches the caller.
        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        swap(extremeKey, false, modestOutput, "");

        // Leg 2: the simulator soft-fails to `(0, 0)` instead of returning the
        // pre-`toInt128()` int256 value that PoolManager would reject.
        (uint256 ain, uint256 aout) = hook.swapToPrice(extremeKey, false, modestOutput, limit, "");
        assertEq(ain, 0, "amountIn must soft-fail to 0 on int128 overflow");
        assertEq(aout, 0, "amountOut must soft-fail to 0 on int128 overflow");
    }

    // ──── beforeSwap: fee override ────

    function test_beforeSwap_zeroForOne_appliesFee() public {
        // Swap 1e18 token0 → token1 with FEE_PIPS (2%)
        BalanceDelta delta = swap(testPoolKey, true, -1e18, "");

        assertEq(delta.amount0(), -1e18);
        int128 output = delta.amount1();
        assertTrue(output > 0);
        assertApproxEqRel(uint256(int256(output)), 0.98e18, 0.01e18);
    }

    function test_beforeSwap_oneForZero_appliesFee() public {
        // Swap 1e18 token1 → token0 with FEE_PIPS (2%) — symmetric
        BalanceDelta delta = swap(testPoolKey, false, -1e18, "");

        assertEq(delta.amount1(), -1e18);
        int128 output = delta.amount0();
        assertTrue(output > 0);
        assertApproxEqRel(uint256(int256(output)), 0.98e18, 0.01e18);
    }

    function test_beforeSwap_unlivePool_reverts() public {
        vm.prank(owner);
        hook.setPoolLive(testPoolKey, false);

        vm.expectRevert();
        swap(testPoolKey, true, -1e18, "");
    }

    function test_beforeSwap_exactOutput_zeroForOne() public {
        BalanceDelta delta = swap(testPoolKey, true, 0.5e18, "");

        assertEq(delta.amount1(), int128(0.5e18));
        int128 input = delta.amount0();
        assertTrue(input < 0);
        assertApproxEqRel(uint256(int256(-input)), 0.5102e18, 0.01e18);
    }

    // ──── Owner functions ────

    function test_setPoolLive_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.setPoolLive(testPoolKey, false);
    }

    /// @dev `renounceOwnership` is overridden to revert. Renouncing would permanently brick
    ///      every onlyOwner entry point (initializePool, setPoolLive, setActiveTick,
    ///      setAuthorizedLP) and orphan every pool referencing this hook. The operator must
    ///      use `transferOwnership` to rotate, never renounce.
    function test_renounceOwnership_reverts() public {
        vm.prank(owner);
        vm.expectRevert(OwnedALFHook.RenounceOwnershipDisabled.selector);
        hook.renounceOwnership();
    }
}

/// @dev Exposes `SwapSimulator.simulateSwapToPrice` directly so tests can exercise the
///      library's input validation (`InvalidLpFeePips`) without going through the hook's
///      `_staticFee` strip on `key.fee`. Internal-only in production -- only used for
///      regression coverage of library-level invariants.
contract SwapSimulatorHarness {
    function simulateSwapToPrice(
        IPoolManager manager,
        PoolId poolId,
        bool zeroForOne,
        int256 amountSpecified,
        uint24 lpFeePips,
        int24 tickSpacing,
        uint160 sqrtPriceLimitX96
    ) external view returns (uint256 amountIn, uint256 amountOut) {
        return SwapSimulator.simulateSwapToPrice(
            manager, poolId, zeroForOne, amountSpecified, lpFeePips, tickSpacing, sqrtPriceLimitX96
        );
    }
}
