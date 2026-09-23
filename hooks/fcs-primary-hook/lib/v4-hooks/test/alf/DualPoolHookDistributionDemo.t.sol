// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

import {DualPoolHook} from "../../src/alf/DualPoolHook.sol";
import {LiquidityBucket} from "../../src/alf/types/Distribution.sol";

/// @notice Demonstration tests showing JIT swap behavior under each of the
///         liquidity-distribution shapes documented in
///         `docs/technical/DualPoolHook.md`. Run with
///         `forge test --match-path test/alf/DualPoolHookDistributionDemo.t.sol -vv`
///         to see per-swap input/output/slippage/tick logs.
///
/// @dev Pools use no rehypothecation vault so reserves equal raw ERC-20 and
///      results reflect distribution shape alone, not vault accounting.
contract DualPoolHookDistributionDemoTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    DualPoolHook public hook;
    address owner = makeAddr("owner");

    MockERC20 token0;
    MockERC20 token1;

    uint24 constant FEE_PIPS = 1_000; // 0.1% symmetric LP fee
    /// @dev Sized so the swap ladder (up to 5,000 t0) actually consumes a meaningful share
    ///      of pool depth and surfaces distribution-shape differences. With BOOTSTRAP_AMOUNT
    ///      at 1M, even 1k swaps register only the LP fee — not interesting for a demo.
    uint256 constant BOOTSTRAP_AMOUNT = 10_000 ether;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        hook = DualPoolHook(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags)));
        deployCodeTo("DualPoolHook", abi.encode(manager, uint32(100_000), owner, type(uint64).max), address(hook));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          DISTRIBUTION DEMOS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Conservative shape from the doc: most depth at the peg, tapering tails.
    ///         75% [-10, 10] / 15% [-30, 30] / 10% [-60, 60].
    function test_demo_conservative() public {
        LiquidityBucket[] memory dist = new LiquidityBucket[](3);
        dist[0] = LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 7_500});
        dist[1] = LiquidityBucket({tickLower: -30, tickUpper: 30, weightBps: 1_500});
        dist[2] = LiquidityBucket({tickLower: -60, tickUpper: 60, weightBps: 1_000});
        PoolKey memory key =
            _initWithDistribution("Conservative (75/15/10 across [-10,10] [-30,30] [-60,60])", dist, 10);
        _runSwapSeries(key);
    }

    /// @notice Ultra-tight stable-pair shape: 45% [-1, 1] / 35% [-5, 5] / 15% [-20, 20] /
    ///         5% [-100, 100]. Capital-efficient on tiny swaps, fragile on bigger ones.
    function test_demo_ultraTight() public {
        LiquidityBucket[] memory dist = new LiquidityBucket[](4);
        dist[0] = LiquidityBucket({tickLower: -1, tickUpper: 1, weightBps: 4_500});
        dist[1] = LiquidityBucket({tickLower: -5, tickUpper: 5, weightBps: 3_500});
        dist[2] = LiquidityBucket({tickLower: -20, tickUpper: 20, weightBps: 1_500});
        dist[3] = LiquidityBucket({tickLower: -100, tickUpper: 100, weightBps: 500});
        PoolKey memory key =
            _initWithDistribution("Ultra-tight (45/35/15/5 across [-1,1] [-5,5] [-20,20] [-100,100])", dist, 1);
        _runSwapSeries(key);
    }

    /// @notice Barbell shape: tight center plus far one-sided tails for shock absorption.
    ///         50% [-5, 5] / 20% [-25, 25] / 15% [-250, -50] / 15% [50, 250].
    function test_demo_barbell() public {
        LiquidityBucket[] memory dist = new LiquidityBucket[](4);
        dist[0] = LiquidityBucket({tickLower: -5, tickUpper: 5, weightBps: 5_000});
        dist[1] = LiquidityBucket({tickLower: -25, tickUpper: 25, weightBps: 2_000});
        dist[2] = LiquidityBucket({tickLower: -250, tickUpper: -50, weightBps: 1_500});
        dist[3] = LiquidityBucket({tickLower: 50, tickUpper: 250, weightBps: 1_500});
        PoolKey memory key = _initWithDistribution("Barbell (50/20/15/15 with [-250,-50] and [50,250] tails)", dist, 5);
        _runSwapSeries(key);
    }

    /// @notice Inventory-skewed shape: maker is token0-heavy, places a sell wall above peg
    ///         to convert token0 into token1 as price rises.
    ///         35% [-10, 10] / 40% [10, 80] / 20% [-80, 80] / 5% [-200, -80].
    function test_demo_inventorySkewed() public {
        LiquidityBucket[] memory dist = new LiquidityBucket[](4);
        dist[0] = LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 3_500});
        dist[1] = LiquidityBucket({tickLower: 10, tickUpper: 80, weightBps: 4_000});
        dist[2] = LiquidityBucket({tickLower: -80, tickUpper: 80, weightBps: 2_000});
        dist[3] = LiquidityBucket({tickLower: -200, tickUpper: -80, weightBps: 500});
        PoolKey memory key = _initWithDistribution("Inventory-skewed (token0-heavy, upper sell wall [10,80])", dist, 10);
        _runSwapSeries(key);
    }

    /// @notice Peg-defense ladder: asymmetric, deeper support below the peg with a smaller
    ///         recovery band above. 30% [-8, 8] / 25% [-40, -8] / 25% [-120, -40] /
    ///         20% [8, 80].
    function test_demo_pegDefense() public {
        LiquidityBucket[] memory dist = new LiquidityBucket[](4);
        dist[0] = LiquidityBucket({tickLower: -8, tickUpper: 8, weightBps: 3_000});
        dist[1] = LiquidityBucket({tickLower: -40, tickUpper: -8, weightBps: 2_500});
        dist[2] = LiquidityBucket({tickLower: -120, tickUpper: -40, weightBps: 2_500});
        dist[3] = LiquidityBucket({tickLower: 8, tickUpper: 80, weightBps: 2_000});
        PoolKey memory key = _initWithDistribution("Peg-defense ladder (asymmetric, deeper below peg)", dist, 8);
        _runSwapSeries(key);
    }

    /// @notice Volatility-adaptive rotation: same pool, swap once under a calm distribution,
    ///         rotate to a stressed distribution via setDistribution, swap the same size
    ///         again. Demonstrates how shape changes alone (constant reserves) move slippage.
    function test_demo_volatilityRotation() public {
        LiquidityBucket[] memory calm = new LiquidityBucket[](2);
        calm[0] = LiquidityBucket({tickLower: -5, tickUpper: 5, weightBps: 8_000});
        calm[1] = LiquidityBucket({tickLower: -30, tickUpper: 30, weightBps: 2_000});
        PoolKey memory key =
            _initWithDistribution("Volatility-adaptive: CALM phase (80/20 across [-5,5] [-30,30])", calm, 5);

        _logSwap(key, true, -100 ether, "ZF1 size 100   t0   [calm]");
        _logSwap(key, true, -1_000 ether, "ZF1 size 1000  t0   [calm]");
        _logSwap(key, true, -5_000 ether, "ZF1 size 5000  t0   [calm]");
        _logSwap(key, false, -500 ether, "1F0 size 500   t1   [calm recover]");
        _logSwap(key, true, -9_500 ether, "ZF1 size 9_500 t0   [calm boundary]");

        // Rotate to stressed shape mid-life. Same reserves, much wider spread of liquidity.
        LiquidityBucket[] memory stressed = new LiquidityBucket[](3);
        stressed[0] = LiquidityBucket({tickLower: -5, tickUpper: 5, weightBps: 2_500});
        stressed[1] = LiquidityBucket({tickLower: -250, tickUpper: 250, weightBps: 5_000});
        stressed[2] = LiquidityBucket({tickLower: 50, tickUpper: 500, weightBps: 2_500});
        vm.prank(owner);
        hook.setDistribution(key, stressed);
        console2.log("--- rotated distribution to STRESSED (25/50/25) ---");

        // Reset price so stressed-phase swaps run from a comparable starting point. Stressed
        // shape's wide [-250,250] bucket means a few k of t1 only walks tick partway; use a
        // bigger reset.
        _logSwap(key, false, -5_000 ether, "1F0 size 5000  t1   [stressed reset]");
        _logSwap(key, true, -100 ether, "ZF1 size 100   t0   [stressed]");
        _logSwap(key, true, -1_000 ether, "ZF1 size 1000  t0   [stressed]");
        _logSwap(key, true, -5_000 ether, "ZF1 size 5000  t0   [stressed]");
    }

    /// @notice Vault rehypothecation with maxWithdraw cap. Pool reserves are 10k of each in
    ///         vaults; vault1 is then capped so only 2k of t1 can be withdrawn at once.
    ///         Logs getReserves vs getEffectiveLiquidity, then runs a ZF1 large enough that
    ///         it should hit the cap — execution truncates while LP shares remain unchanged
    ///         (LPs still own the full economic stake).
    function test_demo_vaultRehypothecation() public {
        // Two ERC4626 vaults — vault1 has a settable maxWithdraw cap; vault0 is uncapped.
        CappedMockERC4626 v0 = new CappedMockERC4626(ERC20(address(token0)));
        CappedMockERC4626 v1 = new CappedMockERC4626(ERC20(address(token1)));

        LiquidityBucket[] memory dist = new LiquidityBucket[](3);
        dist[0] = LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 7_500});
        dist[1] = LiquidityBucket({tickLower: -30, tickUpper: 30, weightBps: 1_500});
        dist[2] = LiquidityBucket({tickLower: -60, tickUpper: 60, weightBps: 1_000});
        PoolKey memory key = _initWithDistributionEx(
            "Vault rehypothecation: vault1 maxWithdraw capped at 2k of 10k",
            dist,
            10,
            FEE_PIPS,
            IERC4626(address(v0)),
            IERC4626(address(v1))
        );

        // Cap vault1 at 2k t1 — simulates a paused/utilized lending vault.
        v1.setWithdrawCap(2_000 ether);

        (uint256 r0, uint256 r1) = hook.getReserves(key);
        (uint256 e0, uint256 e1) = hook.getEffectiveLiquidity(key);
        console2.log(
            string.concat("  getReserves        : t0=", vm.toString(r0 / 1 ether), " t1=", vm.toString(r1 / 1 ether))
        );
        console2.log(
            string.concat(
                "  getEffectiveLiq    : t0=",
                vm.toString(e0 / 1 ether),
                " t1=",
                vm.toString(e1 / 1 ether),
                " (vault1 cap surfaces here)"
            )
        );

        // ZF1 large enough that the JIT cycle would normally need >2k t1 to pay out;
        // bounded by the cap, so output truncates near 2k t1. Tick crashes to MIN_TICK
        // because the JIT couldn't honour the requested input fully.
        _logSwap(key, true, -3_000 ether, "ZF1 size 3000 t0 (cap=2k t1)");

        // Walk the price back toward peg with a reverse swap so subsequent ZF1s have
        // headroom (otherwise they'd revert on PriceLimitAlreadyExceeded).
        _logSwap(key, false, -2_000 ether, "1F0 size 2000 t1 (recover)");

        // Lift the cap, repeat ZF1 at the same size -- output now reflects full effective
        // liquidity instead of being truncated.
        v1.setWithdrawCap(type(uint256).max);
        console2.log("--- vault1 cap lifted ---");
        (uint256 e0b, uint256 e1b) = hook.getEffectiveLiquidity(key);
        console2.log(
            string.concat(
                "  getEffectiveLiq    : t0=",
                vm.toString(e0b / 1 ether),
                " t1=",
                vm.toString(e1b / 1 ether),
                " (now matches reserves)"
            )
        );
        _logSwap(key, true, -3_000 ether, "ZF1 size 3000 t0 (uncapped)");
    }

    /// @notice Compares `getIndicativeQuote` to actual swap execution across three
    ///         distribution shapes. Drift in pips = (actual - predicted) / predicted in ppm.
    ///         The doc notes the indicative quote is "compact, not a full virtual tick-walking
    ///         simulator", so drift on swaps that cross multiple bucket boundaries is expected.
    function test_demo_quoteVsExec_drift() public {
        // (a) Conservative — most-likely-realistic baseline.
        LiquidityBucket[] memory conservative = new LiquidityBucket[](3);
        conservative[0] = LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 7_500});
        conservative[1] = LiquidityBucket({tickLower: -30, tickUpper: 30, weightBps: 1_500});
        conservative[2] = LiquidityBucket({tickLower: -60, tickUpper: 60, weightBps: 1_000});
        _runQuoteSeries(_initWithDistribution("Conservative -- single dense bucket, simple drift", conservative, 10));

        // (b) Barbell — far one-sided tails should make multi-bucket-crossing drift obvious.
        LiquidityBucket[] memory barbell = new LiquidityBucket[](4);
        barbell[0] = LiquidityBucket({tickLower: -5, tickUpper: 5, weightBps: 5_000});
        barbell[1] = LiquidityBucket({tickLower: -25, tickUpper: 25, weightBps: 2_000});
        barbell[2] = LiquidityBucket({tickLower: -250, tickUpper: -50, weightBps: 1_500});
        barbell[3] = LiquidityBucket({tickLower: 50, tickUpper: 250, weightBps: 1_500});
        _runQuoteSeries(_initWithDistribution("Barbell -- multi-bucket crossings expected on big swaps", barbell, 5));

        // (c) Ultra-tight — narrow active band, drift should grow as swap exits the [-1,1] core.
        LiquidityBucket[] memory tight = new LiquidityBucket[](4);
        tight[0] = LiquidityBucket({tickLower: -1, tickUpper: 1, weightBps: 4_500});
        tight[1] = LiquidityBucket({tickLower: -5, tickUpper: 5, weightBps: 3_500});
        tight[2] = LiquidityBucket({tickLower: -20, tickUpper: 20, weightBps: 1_500});
        tight[3] = LiquidityBucket({tickLower: -100, tickUpper: 100, weightBps: 500});
        _runQuoteSeries(_initWithDistribution("Ultra-tight -- drift grows once size pushes past micro band", tight, 1));
    }

    function _runQuoteSeries(PoolKey memory key) internal {
        _logSwapWithQuote(key, true, -1 ether, "ZF1 1 t0   ");
        _logSwapWithQuote(key, true, -10 ether, "ZF1 10 t0  ");
        _logSwapWithQuote(key, true, -100 ether, "ZF1 100 t0 ");
        _logSwapWithQuote(key, true, -1_000 ether, "ZF1 1000 t0");
        _logSwapWithQuote(key, true, -5_000 ether, "ZF1 5000 t0");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    function _initWithDistribution(string memory name, LiquidityBucket[] memory dist, int24 tickSpacing)
        internal
        returns (PoolKey memory key)
    {
        return _initWithDistributionEx(name, dist, tickSpacing, FEE_PIPS, IERC4626(address(0)), IERC4626(address(0)));
    }

    /// @dev Extended initializer accepting a custom fee and per-currency vaults. Used by the
    ///      vault-rehypothecation demo.
    function _initWithDistributionEx(
        string memory name,
        LiquidityBucket[] memory dist,
        int24 tickSpacing,
        uint24 feePips,
        IERC4626 vault0,
        IERC4626 vault1
    ) internal returns (PoolKey memory key) {
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: feePips,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(hook))
        });
        DualPoolHook.PoolConfig memory cfg = DualPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            distribution: dist,
            allowExternalDeposits: false,
            vault0: vault0,
            vault1: vault1,
            minDepositBlocks: 0
        });
        vm.prank(owner);
        hook.initializePool(key, cfg);

        token0.mint(owner, BOOTSTRAP_AMOUNT);
        token1.mint(owner, BOOTSTRAP_AMOUNT);
        vm.startPrank(owner);
        token0.approve(address(hook), BOOTSTRAP_AMOUNT);
        token1.approve(address(hook), BOOTSTRAP_AMOUNT);
        hook.bootstrap(key, BOOTSTRAP_AMOUNT, BOOTSTRAP_AMOUNT);
        vm.stopPrank();

        // Step a block so we are not literally inside the bootstrap tx.
        vm.roll(block.number + 1);

        console2.log("");
        console2.log("=========================================================");
        console2.log("  DISTRIBUTION:", name);
        console2.log("---------------------------------------------------------");
        console2.log(
            string.concat(
                "  tickSpacing=",
                vm.toString(int256(tickSpacing)),
                "  reserves=",
                vm.toString(BOOTSTRAP_AMOUNT / 1 ether),
                " token0/1 each",
                "  fee=",
                _bps(uint256(feePips))
            )
        );
        for (uint256 i; i < dist.length; i++) {
            console2.log(
                string.concat(
                    "  bucket[",
                    vm.toString(i),
                    "] weightBps=",
                    vm.toString(uint256(dist[i].weightBps)),
                    "  range=[",
                    vm.toString(int256(dist[i].tickLower)),
                    ",",
                    vm.toString(int256(dist[i].tickUpper)),
                    "]"
                )
            );
        }
        console2.log("---------------------------------------------------------");
    }

    /// @dev Size ladder: tiny → 1 → 10 → 100 → 500 → 1000 → 5000 t0.
    ///      With a 10k-ether pool, the larger sizes consume real depth and surface
    ///      distribution-shape impact rather than just the flat LP fee. Then a reverse
    ///      pair to show the ask side.
    function _runSwapSeries(PoolKey memory key) internal {
        // Standard size ladder: tiny -> small -> medium -> large.
        _logSwap(key, true, -1e15, "ZF1 size 0.001  t0");
        _logSwap(key, true, -1 ether, "ZF1 size 1      t0");
        _logSwap(key, true, -10 ether, "ZF1 size 10     t0");
        _logSwap(key, true, -100 ether, "ZF1 size 100    t0");
        _logSwap(key, true, -500 ether, "ZF1 size 500    t0");
        _logSwap(key, true, -1_000 ether, "ZF1 size 1000   t0");
        _logSwap(key, true, -5_000 ether, "ZF1 size 5000   t0");
        // Walk price back so the boundary swap has headroom on shapes that crashed to MIN_TICK.
        _logSwap(key, false, -1_000 ether, "1F0 size 1000   t1 (recover)");
        // Boundary push: ~95% of pool depth -- reaches the outer bucket on most shapes, may
        // truncate to a partial fill on asymmetric shapes whose lower-side depth is thin.
        _logSwap(key, true, -9_500 ether, "ZF1 size 9_500  t0 (boundary)");
        // Mini-recover so the way-past swap can start above MIN_TICK.
        _logSwap(key, false, -500 ether, "1F0 size 500    t1 (recover)");
        // Way past: 5x pool size -- always partial-fills and crashes tick to MIN_TICK.
        _logSwap(key, true, -50_000 ether, "ZF1 size 50_000 t0 (way past)");
        // Final buy-side from the depleted state.
        _logSwap(key, false, -1_000 ether, "1F0 size 1000   t1 (buy at depletion)");
    }

    /// @dev Run a single swap and log size, in/out (in milli-token units = 1e15 wei),
    ///      slippage in pips (= ppm), and tick before/after.
    function _logSwap(PoolKey memory key, bool zeroForOne, int256 amountIn, string memory label) internal {
        (, int24 tickBefore,,) = manager.getSlot0(key.toId());
        BalanceDelta delta = swap(key, zeroForOne, amountIn, "");
        (, int24 tickAfter,,) = manager.getSlot0(key.toId());

        // From the swapper's perspective: input is the negative leg, output is the positive.
        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();
        uint256 inAbs = zeroForOne ? _abs(d0) : _abs(d1);
        uint256 outAbs = zeroForOne ? _abs(d1) : _abs(d0);

        // Slippage in pips (= ppm) = (in - out) / in, signed. Negative = favorable execution
        // for the swapper (price improved relative to 1:1 because the pool drifted in the
        // swapper's direction earlier). Both currencies are 18-decimal so the ratio is clean.
        bool favorable = outAbs > inAbs;
        uint256 absDiff = favorable ? outAbs - inAbs : inAbs - outAbs;
        uint256 slipPips = inAbs > 0 ? (absDiff * 1_000_000) / inAbs : 0;

        console2.log(
            string.concat(
                "  ",
                label,
                " | in=",
                vm.toString(inAbs / 1e15),
                "e15  out=",
                vm.toString(outAbs / 1e15),
                "e15  slip=",
                favorable ? "-" : "",
                _bps(slipPips),
                "  tick:",
                vm.toString(int256(tickBefore)),
                "->",
                vm.toString(int256(tickAfter))
            )
        );
    }

    function _abs(int128 x) private pure returns (uint256) {
        return x < 0 ? uint256(int256(-x)) : uint256(int256(x));
    }

    /// @dev Format a ppm value (= pips) as a fixed-2-decimal bps string. 1 bps = 100 pips,
    ///      so 1024 pips renders as "10.24bps".
    function _bps(uint256 pips) private pure returns (string memory) {
        uint256 frac = pips % 100;
        string memory fracStr = frac < 10 ? string.concat("0", _toStr(frac)) : _toStr(frac);
        return string.concat(_toStr(pips / 100), ".", fracStr, "bps");
    }

    function _toStr(uint256 x) private pure returns (string memory) {
        if (x == 0) return "0";
        uint256 len;
        for (uint256 t = x; t > 0; t /= 10) {
            len++;
        }
        bytes memory b = new bytes(len);
        for (uint256 i = len; i > 0; i--) {
            b[i - 1] = bytes1(uint8(48 + (x % 10)));
            x /= 10;
        }
        return string(b);
    }

    /// @dev Same as `_logSwap` but also queries `getIndicativeQuote` first and reports the
    ///      drift between predicted and actual output. Used by the quote/exec drift demo.
    ///      Drift sign convention: positive = execution beat the quote (pool gave more out
    ///      than predicted); negative = execution underdelivered.
    function _logSwapWithQuote(PoolKey memory key, bool zeroForOne, int256 amountIn, string memory label) internal {
        uint256 predicted = hook.getIndicativeQuote(key, zeroForOne, amountIn, "");

        BalanceDelta delta = swap(key, zeroForOne, amountIn, "");
        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();
        uint256 inAbs = zeroForOne ? _abs(d0) : _abs(d1);
        uint256 outAbs = zeroForOne ? _abs(d1) : _abs(d0);

        bool over = outAbs > predicted;
        uint256 absDiff = predicted == 0 ? 0 : (over ? outAbs - predicted : predicted - outAbs);
        uint256 driftPips = predicted > 0 ? (absDiff * 1_000_000) / predicted : 0;

        console2.log(
            string.concat(
                "  ",
                label,
                " | in=",
                vm.toString(inAbs / 1e15),
                "e15  predicted=",
                vm.toString(predicted / 1e15),
                "e15  actual=",
                vm.toString(outAbs / 1e15),
                "e15  drift=",
                over ? "+" : "-",
                _bps(driftPips)
            )
        );
    }
}

/// @notice ERC-4626 mock with a settable `withdrawCap` so tests can simulate
///         paused/utilization-constrained vaults that cannot honour their full
///         `convertToAssets(balanceOf)` on demand. Mirrors the small interface
///         PoolVault actually uses (deposit, withdraw, convertToShares,
///         convertToAssets, asset, maxWithdraw).
contract CappedMockERC4626 is ERC20 {
    ERC20 public immutable asset;
    uint256 public withdrawCap;

    constructor(ERC20 _asset)
        ERC20(string.concat("Capped Vault ", _asset.name()), string.concat("cv", _asset.symbol()), _asset.decimals())
    {
        asset = _asset;
        withdrawCap = type(uint256).max;
    }

    function setWithdrawCap(uint256 cap) external {
        withdrawCap = cap;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = convertToShares(assets);
        asset.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner_) external returns (uint256 shares) {
        require(assets <= withdrawCap, "CappedMockERC4626: cap");
        shares = convertToShares(assets);
        if (msg.sender != owner_) {
            uint256 allowed = allowance[owner_][msg.sender];
            if (allowed != type(uint256).max) {
                allowance[owner_][msg.sender] = allowed - shares;
            }
        }
        _burn(owner_, shares);
        asset.transfer(receiver, assets);
    }

    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply;
        return supply == 0 ? assets : (assets * supply) / totalAssets();
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply;
        return supply == 0 ? shares : (shares * totalAssets()) / supply;
    }

    /// @dev `previewRedeem` reports the realizable amount after applying the same withdraw
    ///      cap as `maxWithdraw`. With the cap binding, `previewRedeem` returns
    ///      `min(convertToAssets(shares), cap)` so callers using `previewRedeem` for
    ///      deployable-now sizing see the constrained value.
    function previewRedeem(uint256 shares) public view returns (uint256) {
        uint256 gross = convertToAssets(shares);
        return gross < withdrawCap ? gross : withdrawCap;
    }

    function previewDeposit(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    /// @dev Effective max-withdraw is the lesser of the economic share value and the cap.
    ///      Mirrors how Aave-style vaults reduce maxWithdraw when underlying is utilised.
    function maxWithdraw(address owner_) external view returns (uint256) {
        uint256 economic = convertToAssets(balanceOf[owner_]);
        return economic < withdrawCap ? economic : withdrawCap;
    }
}
