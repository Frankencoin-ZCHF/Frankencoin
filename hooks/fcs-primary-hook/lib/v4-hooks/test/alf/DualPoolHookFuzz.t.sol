// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {DualPoolHook} from "../../src/alf/DualPoolHook.sol";
import {LiquidityBucket} from "../../src/alf/types/Distribution.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";

/// @title DualPoolHookFuzzTest
/// @notice Stateless ("property") fuzzing for DualPoolHook against a live, bootstrapped pool.
///         Complements the stateful invariant suite (`DualPoolInvariantTest`) by asserting
///         per-operation properties over a wide input space: LP round-trip value conservation,
///         preview/quote fidelity that routers rely on, and the JIT zero-liquidity property.
///
/// @dev    The pool is bootstrapped once in `setUp`. Stateless fuzz tests do NOT re-run `setUp`
///         between runs, so tests that mutate pool state (deposits, swaps) are written so the
///         asserted property holds regardless of accumulated state across runs.
contract DualPoolHookFuzzTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    DualPoolHook public hook;
    MockERC4626 public vault0;
    MockERC4626 public vault1;
    MockERC20 token0;
    MockERC20 token1;

    address poolOwner = makeAddr("poolOwner");
    address alice = makeAddr("alice");

    PoolKey testKey;
    PoolId poolId;

    uint24 constant FEE_PIPS = 1_000; // 0.1%
    int24 constant TICK_SPACING = 10;
    uint256 constant BOOTSTRAP_AMOUNT = 1e22; // 10k 18-dec tokens each side; >> inflation floor

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));
        vault0 = new MockERC4626(ERC20(address(token0)));
        vault1 = new MockERC4626(ERC20(address(token1)));

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        hook = DualPoolHook(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags)));
        deployCodeTo("DualPoolHook", abi.encode(manager, uint32(100_000), poolOwner, type(uint64).max), address(hook));

        testKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: FEE_PIPS,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        poolId = testKey.toId();

        // Three-bucket conservative distribution centered on tick 0 so swaps/quotes have depth.
        LiquidityBucket[] memory dist = new LiquidityBucket[](3);
        dist[0] = LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 7_500});
        dist[1] = LiquidityBucket({tickLower: -30, tickUpper: 30, weightBps: 1_500});
        dist[2] = LiquidityBucket({tickLower: -60, tickUpper: 60, weightBps: 1_000});

        DualPoolHook.PoolConfig memory cfg = DualPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            distribution: dist,
            allowExternalDeposits: true,
            vault0: IERC4626(address(vault0)),
            vault1: IERC4626(address(vault1)),
            minDepositBlocks: 0
        });

        vm.prank(poolOwner);
        hook.initializePool(testKey, cfg);

        token0.mint(poolOwner, BOOTSTRAP_AMOUNT);
        token1.mint(poolOwner, BOOTSTRAP_AMOUNT);
        vm.startPrank(poolOwner);
        token0.approve(address(hook), BOOTSTRAP_AMOUNT);
        token1.approve(address(hook), BOOTSTRAP_AMOUNT);
        hook.bootstrap(testKey, BOOTSTRAP_AMOUNT, BOOTSTRAP_AMOUNT);
        vm.stopPrank();

        vm.roll(block.number + 1);
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _fund(address who, uint256 amt0, uint256 amt1) internal {
        token0.mint(who, amt0);
        token1.mint(who, amt1);
        vm.startPrank(who);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    // ───────────────────────────── LP value conservation ─────────────────────────────

    /// @notice NO FREE MONEY: deposit then immediately withdraw the same shares never returns
    ///         more than was paid in, on either side. Deposits round up, withdrawals round
    ///         down, so an LP cannot extract value via a round-trip (the canonical share-math
    ///         attack surface). Also confirms `removeLiquidity` returns exactly `previewWithdraw`.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_addThenRemove_noProfit(uint256 sharesSeed) public {
        uint256 supply = hook.totalShares(poolId);
        uint256 shares = bound(sharesSeed, 1, supply); // up to 100% of current supply

        (uint256 want0, uint256 want1) = hook.previewDeposit(testKey, shares);
        _fund(alice, want0, want1);

        vm.prank(alice);
        (uint256 dep0, uint256 dep1) =
            hook.addLiquidity(testKey, shares, type(uint256).max, type(uint256).max, type(uint256).max);

        vm.roll(block.number + 1);

        // Preview must equal the realized withdraw at the pre-removal state.
        (uint256 pw0, uint256 pw1) = hook.previewWithdraw(testKey, shares);

        vm.prank(alice);
        (uint256 rec0, uint256 rec1) = hook.removeLiquidity(testKey, shares, 0, 0, type(uint256).max);

        assertEq(rec0, pw0, "removeLiquidity0 != previewWithdraw0");
        assertEq(rec1, pw1, "removeLiquidity1 != previewWithdraw1");
        assertLe(rec0, dep0, "round-trip minted token0 value");
        assertLe(rec1, dep1, "round-trip minted token1 value");
    }

    /// @notice PREVIEW FIDELITY: the amounts `addLiquidity` actually pulls equal the
    ///         `previewDeposit` quote at the same state. Routers and depositors size approvals
    ///         and slippage bounds off the preview, so any divergence is a correctness bug.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_previewDeposit_matchesActual(uint256 sharesSeed) public {
        uint256 supply = hook.totalShares(poolId);
        uint256 shares = bound(sharesSeed, 1, supply);

        (uint256 p0, uint256 p1) = hook.previewDeposit(testKey, shares);
        _fund(alice, p0, p1);

        vm.prank(alice);
        (uint256 a0, uint256 a1) =
            hook.addLiquidity(testKey, shares, type(uint256).max, type(uint256).max, type(uint256).max);

        assertEq(a0, p0, "actual0 != previewDeposit0");
        assertEq(a1, p1, "actual1 != previewDeposit1");
    }

    /// @notice SLIPPAGE BOUND IS HONORED: a `maxAmount` strictly below the required deposit
    ///         reverts with `SlippageExceeded` rather than silently overspending.
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_addLiquidity_respectsSlippageCap(uint256 sharesSeed) public {
        uint256 supply = hook.totalShares(poolId);
        uint256 shares = bound(sharesSeed, 1e9, supply); // large enough that required amounts > 1

        (uint256 p0, uint256 p1) = hook.previewDeposit(testKey, shares);
        if (p0 == 0 || p1 == 0) return; // can't under-cap a zero requirement
        _fund(alice, p0, p1);

        // Cap currency0 one wei below the requirement → must revert.
        vm.prank(alice);
        vm.expectRevert(DualPoolHook.SlippageExceeded.selector);
        hook.addLiquidity(testKey, shares, p0 - 1, p1, type(uint256).max);
    }

    // ───────────────────────────── quote / simulation fidelity ─────────────────────────────

    /// @notice QUOTE MONOTONICITY: for exact-input swaps, a larger input never yields a smaller
    ///         indicative output. Routers rank fills on this; a non-monotone quote would break
    ///         split planning.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_indicativeQuote_monotonicInInput(uint256 baseSeed, uint256 deltaSeed, bool zeroForOne)
        public
        view
    {
        uint256 amtA = bound(baseSeed, 1e6, 1e21);
        uint256 amtB = amtA + bound(deltaSeed, 0, 1e21); // amtB >= amtA

        uint256 qA = hook.getIndicativeQuote(testKey, zeroForOne, -int256(amtA), "");
        uint256 qB = hook.getIndicativeQuote(testKey, zeroForOne, -int256(amtB), "");

        assertGe(qB, qA, "more input produced less output");
    }

    /// @notice VIEW CONSISTENCY: `getIndicativeQuote` (exact-in) equals the output leg of
    ///         `swapToPrice` at the full price range. Both are the router-facing surface; they
    ///         must not disagree for the same swap.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_indicativeQuote_matchesSwapToPrice(uint256 amtSeed, bool zeroForOne) public view {
        uint256 amt = bound(amtSeed, 1e3, 1e21);
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        uint256 q = hook.getIndicativeQuote(testKey, zeroForOne, -int256(amt), "");
        (, uint256 outAmt) = hook.swapToPrice(testKey, zeroForOne, -int256(amt), limit, "");

        assertEq(q, outAmt, "getIndicativeQuote != swapToPrice output");
    }

    /// @notice HOOKDATA IS IGNORED: the indicative quote is identical whether `hookData` is
    ///         empty or arbitrary bytes. DualPool is a static-pricing strategy; integrators
    ///         must be able to pass anything (or nothing) without changing the price.
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_indicativeQuote_ignoresHookData(uint256 amtSeed, bytes calldata hookData, bool zeroForOne)
        public
        view
    {
        uint256 amt = bound(amtSeed, 1e3, 1e21);
        uint256 qEmpty = hook.getIndicativeQuote(testKey, zeroForOne, -int256(amt), "");
        uint256 qData = hook.getIndicativeQuote(testKey, zeroForOne, -int256(amt), hookData);
        assertEq(qEmpty, qData, "hookData changed the quote");
    }

    // ───────────────────────────── JIT property ─────────────────────────────

    /// @notice ZERO PERSISTENT LIQUIDITY: after any swap attempt, the v4 pool holds no
    ///         liquidity. On success, `afterSwap` tore the JIT positions down; on revert the
    ///         whole tx rolled back to the (already zero) pre-swap state. Either way the
    ///         post-state liquidity is exactly zero.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_swap_leavesNoPersistentLiquidity(uint256 amtSeed, bool zeroForOne, bool exactOut) public {
        int256 mag = int256(bound(amtSeed, 1e6, 1e20));
        int256 amount = exactOut ? mag : -mag;

        _fund(alice, 1e22, 1e22);
        vm.startPrank(alice);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        SwapParams memory params =
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amount, sqrtPriceLimitX96: limit});
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        try swapRouter.swap(testKey, params, settings, "") returns (BalanceDelta) {} catch {}
        vm.stopPrank();

        assertEq(manager.getLiquidity(poolId), 0, "pool retained liquidity after swap");
    }

    // ───────────────────────────── distribution validation ─────────────────────────────

    /// @notice DISTRIBUTION HAPPY PATH: any well-formed distribution (1..8 buckets, aligned
    ///         ticks, non-zero weights summing to 10_000) is accepted and read back intact.
    ///         Exercises `_setDistribution` across many fuzzed shapes; the stored post-state
    ///         must always satisfy the documented invariants.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_setDistribution_validShapesRoundtrip(uint256 nSeed, uint256 widthSeed) public {
        uint256 n = bound(nSeed, 1, 8);
        LiquidityBucket[] memory dist = _validDistribution(n, widthSeed);

        vm.prank(poolOwner);
        hook.setDistribution(testKey, dist);

        LiquidityBucket[] memory stored = hook.getDistribution(poolId);
        assertEq(stored.length, n, "bucket count not stored");

        uint256 sum;
        for (uint256 i; i < stored.length; i++) {
            assertGt(stored[i].weightBps, 0, "zero-weight bucket stored");
            assertLt(stored[i].tickLower, stored[i].tickUpper, "lower >= upper stored");
            assertEq(stored[i].tickLower % TICK_SPACING, 0, "tickLower misaligned");
            assertEq(stored[i].tickUpper % TICK_SPACING, 0, "tickUpper misaligned");
            assertGe(stored[i].tickLower, TickMath.MIN_TICK, "tickLower below MIN_TICK");
            assertLe(stored[i].tickUpper, TickMath.MAX_TICK, "tickUpper above MAX_TICK");
            sum += stored[i].weightBps;
        }
        assertEq(sum, 10_000, "weights do not sum to 10_000");
    }

    /// @notice DISTRIBUTION VALIDATION IS TOTAL: feeding semi-arbitrary buckets either reverts
    ///         (bad weights/ticks) or stores a distribution that satisfies every invariant —
    ///         it never silently stores a malformed distribution.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_setDistribution_revertsOrStoresValid(
        uint16 w0,
        uint16 w1,
        int24 lo0,
        int24 up0,
        int24 lo1,
        int24 up1
    ) public {
        LiquidityBucket[] memory dist = new LiquidityBucket[](2);
        dist[0] = LiquidityBucket({tickLower: lo0, tickUpper: up0, weightBps: w0});
        dist[1] = LiquidityBucket({tickLower: lo1, tickUpper: up1, weightBps: w1});

        vm.prank(poolOwner);
        try hook.setDistribution(testKey, dist) {
            // Accepted → post-state must be fully valid.
            LiquidityBucket[] memory stored = hook.getDistribution(poolId);
            uint256 sum;
            for (uint256 i; i < stored.length; i++) {
                assertGt(stored[i].weightBps, 0, "stored zero weight");
                assertLt(stored[i].tickLower, stored[i].tickUpper, "stored lower >= upper");
                assertEq(stored[i].tickLower % TICK_SPACING, 0, "stored tickLower misaligned");
                assertEq(stored[i].tickUpper % TICK_SPACING, 0, "stored tickUpper misaligned");
                sum += stored[i].weightBps;
            }
            assertEq(sum, 10_000, "accepted distribution with weights != 10_000");
        } catch {
            // Rejected → fine. The validator is allowed to revert on malformed input.
        }
    }

    /// @dev Build a guaranteed-valid distribution of `n` buckets: weights split evenly with the
    ///      remainder folded into the last bucket (all > 0 since 10_000/8 = 1_250 >= 1), and a
    ///      symmetric tick band per bucket aligned to `TICK_SPACING` and within tick bounds.
    function _validDistribution(uint256 n, uint256 widthSeed) internal pure returns (LiquidityBucket[] memory dist) {
        dist = new LiquidityBucket[](n);
        uint256 base = 10_000 / n;
        uint256 assigned;
        for (uint256 i; i < n; i++) {
            uint16 w = (i == n - 1) ? uint16(10_000 - assigned) : uint16(base);
            if (i != n - 1) assigned += base;
            // Distinct, strictly-positive half-width per bucket → valid lower<upper, aligned,
            // and well inside MAX_TICK (max half-width here is (1_000 + 7) * 10 = 10_070 ticks).
            uint256 mult = bound(widthSeed, 1, 1_000) + i;
            int24 hw = int24(uint24(mult)) * TICK_SPACING;
            dist[i] = LiquidityBucket({tickLower: -hw, tickUpper: hw, weightBps: w});
        }
    }
}
