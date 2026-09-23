// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DualPoolHook} from "../../src/alf/DualPoolHook.sol";
import {LiquidityBucket} from "../../src/alf/types/Distribution.sol";

/// @title DualPoolHookMainnetForkTest
/// @notice Mainnet-fork validation of the `maxWithdraw`-first effective-liquidity sizing
///         (`InventoryLib.realizableVaultAssets`) against the three production vault classes the
///         hybrid was designed for, all wrapping real USDT:
///
///           1. Spark spUSDT (liquidity-gated previews): `previewRedeem` reverts with
///              "SparkVault/insufficient-liquidity" whenever idle liquidity cannot cover the
///              amount; `maxWithdraw` returns `min(idle, assetsOf(owner))`. At the pinned block
///              the live vault holds ~59M USDT idle against ~410M totalAssets, so the gated
///              state is real, not manufactured.
///           2. Sky sUSDT ("Tether Savings"): same implementation contract as spUSDT
///              (0x1b992302652a92611dcd5090d1cb388c6377f455 behind both proxies), so the same
///              gating semantics.
///           3. Sky USDT Risk Capital (Morpho VaultV2): every `max*` view is a hard-zero
///              sentinel by construction; `previewRedeem` is the honest realizable value.
///
///         Using real USDT also exercises the hook's non-standard-token plumbing (SafeERC20
///         pulls, `Currency.transfer` payouts, forceApprove) against the genuine no-return-value
///         token. Swaps run USDC -> USDT only: the v4 test routers settle swap input with a
///         bool-decoding `transferFrom`, which real USDT breaks; USDT only ever leaves the
///         PoolManager via the assembly `Currency.transfer`, which is USDT-safe.
///
///         Tests skip (log + early return) when `MAINNET_RPC_URL` is not set, mirroring the
///         repo's fork-test convention. The fork is pinned to `FORK_BLOCK` so the live vault
///         states asserted here are reproducible.
contract DualPoolHookMainnetForkTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    // Mainnet addresses, verified with `cast code` / `cast call` (name, symbol, asset) at
    // FORK_BLOCK. All three vaults wrap USDT.
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    /// @dev "Spark Savings USDT" (spUSDT), ERC-1967 proxy -> 0x1b992302652a92611dcd5090d1cb388c6377f455.
    IERC4626 constant SPARK_SPUSDT = IERC4626(0xe2e7a17dFf93280dec073C995595155283e3C372);
    /// @dev "Tether Savings" (sUSDT), proxy to the same SparkVault implementation as spUSDT.
    IERC4626 constant SKY_SUSDT = IERC4626(0x74cb54e082411cfCAEADb00a0765625B10410DAa);
    /// @dev "sky.money USDT Risk Capital", Morpho VaultV2 (18-decimal shares, hard-zero max* views).
    IERC4626 constant SKY_MORPHO_USDT = IERC4626(0x2bD3A43863c07B6A01581FADa0E1614ca5DF0E3d);

    uint256 constant FORK_BLOCK = 25_576_334;

    // The partner-reported flow, at their exact scale: swap < idle < position value.
    uint256 constant POSITION_PER_SIDE = 1_000_000e6; // 1M USDC + 1M USDT bootstrap
    uint256 constant DRAINED_IDLE = 500_000e6; // savings-vault idle after simulated allocation
    uint256 constant SWAP_IN = 100_000e6; // USDC exact-in

    uint24 constant FEE_PIPS = 1_000; // 0.1%

    DualPoolHook hook;
    address owner = makeAddr("owner");
    address allocationSink = makeAddr("sparkAllocationSink");

    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            try vm.envString("INFURA_API_KEY") returns (string memory) {
                rpc = vm.rpcUrl("mainnet");
            } catch {}
        }
        if (bytes(rpc).length == 0) {
            console2.log("Skipping fork tests: set MAINNET_RPC_URL (or INFURA_API_KEY) to run them.");
            return;
        }
        forked = true;
        vm.createSelectFork(rpc, FORK_BLOCK);

        deployFreshManagerAndRouters();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        hook = DualPoolHook(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags)));
        deployCodeTo("DualPoolHook", abi.encode(manager, uint32(100_000), owner, type(uint64).max), address(hook));

        // Swap input (USDC) settlement allowance for the v4 test router.
        IERC20(USDC).forceApprove(address(swapRouter), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Initialize a USDC/USDT pool with `usdtVault` on the USDT side only (USDC held raw),
    ///      mirroring the partner deployment shape. Distinct `tickSpacing` per vault keeps the
    ///      PoolIds distinct while every pool uses the same +-60-tick bucket.
    function _initVaultedPool(IERC4626 usdtVault, int24 tickSpacing) internal returns (PoolKey memory key) {
        LiquidityBucket[] memory dist = new LiquidityBucket[](1);
        dist[0] = LiquidityBucket({tickLower: -60, tickUpper: 60, weightBps: 10_000});
        key = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(USDT),
            fee: FEE_PIPS,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(hook))
        });
        vm.prank(owner);
        hook.initializePool(
            key,
            DualPoolHook.PoolConfig({
                sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
                distribution: dist,
                allowExternalDeposits: true,
                vault0: IERC4626(address(0)),
                vault1: usdtVault,
                minDepositBlocks: 0
            })
        );
    }

    /// @dev Bootstrap `key` with `amount` per side from `owner`. Real-token `deal` plus
    ///      `forceApprove` (USDT rejects bool-decoding approvals and non-zero -> non-zero).
    function _bootstrap(PoolKey memory key, uint256 amount) internal {
        deal(USDC, owner, amount);
        deal(USDT, owner, amount);
        vm.startPrank(owner);
        IERC20(USDC).forceApprove(address(hook), amount);
        IERC20(USDT).forceApprove(address(hook), amount);
        hook.bootstrap(key, amount, amount);
        vm.stopPrank();
        vm.roll(block.number + 1);
    }

    /// @dev Simulate the savings vault's allocator deploying idle capital into strategies:
    ///      transfer idle USDT out of the vault down to `keepIdle`. SparkVault `totalAssets`
    ///      is rate-accumulator based (at FORK_BLOCK spUSDT reports ~410M totalAssets against
    ///      ~59M idle), so moving idle out changes only what a withdrawal can be served with,
    ///      exactly like production allocation.
    function _drainIdleTo(IERC4626 vault, uint256 keepIdle) internal {
        uint256 idle = IERC20(USDT).balanceOf(address(vault));
        assertGt(idle, keepIdle, "fixture: vault must hold more idle than the drain target");
        vm.prank(address(vault));
        IERC20(USDT).safeTransfer(allocationSink, idle - keepIdle);
    }

    /// @dev USDC exact-in swap funded by this contract; returns the USDT delivered.
    function _swapUsdcIn(PoolKey memory key, uint256 amountIn) internal returns (uint256 usdtOut) {
        deal(USDC, address(this), IERC20(USDC).balanceOf(address(this)) + amountIn);
        uint256 before = IERC20(USDT).balanceOf(address(this));
        swap(key, true, -int256(amountIn), "");
        usdtOut = IERC20(USDT).balanceOf(address(this)) - before;
    }

    /// @dev The partner-reported flow against a liquidity-gated savings vault (spUSDT or
    ///      sUSDT): bootstrap, drain idle below the position value, verify the gated state is
    ///      real, then check sizing, a swap, and an LP exit all clear.
    function _runGatedSavingsVaultFlow(IERC4626 vault, int24 tickSpacing) internal {
        PoolKey memory key = _initVaultedPool(vault, tickSpacing);
        _bootstrap(key, POSITION_PER_SIDE);
        _drainIdleTo(vault, DRAINED_IDLE);

        // Fixture validity: the exact partner-reported revert. The pool's position value
        // (~1M) exceeds idle (500k), so previewRedeem on the hook's shares reverts, which
        // is what bricked every swap under previewRedeem-primary sizing.
        uint256 hookShares = IERC20(address(vault)).balanceOf(address(hook));
        vm.expectRevert(bytes("SparkVault/insufficient-liquidity"));
        vault.previewRedeem(hookShares);

        // Sizing reports the idle-capped figure on the vaulted side and raw USDC on the other.
        (uint256 eff0, uint256 eff1) = hook.getEffectiveLiquidity(key);
        assertEq(eff0, POSITION_PER_SIDE, "USDC side: full raw balance");
        assertEq(eff1, DRAINED_IDLE, "USDT side: capped at vault idle liquidity");

        // Reserves still report the full economic stake (bootstrap value, share-rounding dust).
        (, uint256 reserves1) = hook.getReserves(key);
        assertApproxEqAbs(reserves1, POSITION_PER_SIDE, 10, "gross reserves unaffected by the idle cap");

        // The partner flow: swap (100k) < idle (500k) < position (1M) executes.
        uint256 usdtOut = _swapUsdcIn(key, SWAP_IN);
        assertGt(usdtOut, (SWAP_IN * 99) / 100, "stable swap delivered near-par output");
        assertLe(usdtOut, SWAP_IN, "output cannot exceed input on a balanced stable pool");

        // LP exit within remaining idle clears; the payout is real USDT in the owner's wallet.
        uint256 ownerShares = hook.userShares(key.toId(), owner);
        uint256 usdtBefore = IERC20(USDT).balanceOf(owner);
        vm.prank(owner);
        hook.removeLiquidity(key, ownerShares / 5, 0, 0, block.timestamp);
        assertGt(IERC20(USDT).balanceOf(owner), usdtBefore, "LP exit returned USDT");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                  LIQUIDITY-GATED SAVINGS VAULTS (SparkVault impl)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_fork_spUSDT_gatedIdle_swapAndExit() public {
        if (!forked) return;
        _runGatedSavingsVaultFlow(SPARK_SPUSDT, 10);
    }

    function test_fork_skySUSDT_gatedIdle_swapAndExit() public {
        if (!forked) return;
        _runGatedSavingsVaultFlow(SKY_SUSDT, 30);
    }

    /// @dev The live spUSDT vault is already in the gated state at FORK_BLOCK (~59M idle vs
    ///      ~410M totalAssets) without any manufactured drain: previewRedeem on the whole
    ///      supply reverts. Pin that so the fixture assumption stays visibly true.
    function test_fork_spUSDT_liveVaultIsGatedToday() public {
        if (!forked) return;
        uint256 supply = IERC20(address(SPARK_SPUSDT)).totalSupply();
        vm.expectRevert(bytes("SparkVault/insufficient-liquidity"));
        SPARK_SPUSDT.previewRedeem(supply);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                  MORPHO VAULTV2 (hard-zero max* sentinel)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_fork_skyMorphoVaultV2_sentinelFallback_swapAndExit() public {
        if (!forked) return;
        PoolKey memory key = _initVaultedPool(SKY_MORPHO_USDT, 60);
        _bootstrap(key, POSITION_PER_SIDE);

        // Fixture validity: VaultV2 reports the zero sentinel from maxWithdraw while
        // previewRedeem returns the honest realizable value, so sizing must have taken the
        // fallback path to produce a non-zero figure.
        assertEq(SKY_MORPHO_USDT.maxWithdraw(address(hook)), 0, "VaultV2 maxWithdraw is a hard-zero sentinel");
        uint256 hookShares = IERC20(address(SKY_MORPHO_USDT)).balanceOf(address(hook));
        assertGt(SKY_MORPHO_USDT.previewRedeem(hookShares), 0, "previewRedeem is the honest value");

        (uint256 eff0, uint256 eff1) = hook.getEffectiveLiquidity(key);
        assertEq(eff0, POSITION_PER_SIDE, "USDC side: full raw balance");
        assertApproxEqAbs(eff1, POSITION_PER_SIDE, 10, "USDT side: previewRedeem fallback, full position");

        uint256 usdtOut = _swapUsdcIn(key, SWAP_IN);
        assertGt(usdtOut, (SWAP_IN * 99) / 100, "stable swap delivered near-par output");

        uint256 ownerShares = hook.userShares(key.toId(), owner);
        uint256 usdtBefore = IERC20(USDT).balanceOf(owner);
        vm.prank(owner);
        hook.removeLiquidity(key, ownerShares / 5, 0, 0, block.timestamp);
        assertGt(IERC20(USDT).balanceOf(owner), usdtBefore, "LP exit returned USDT");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                  PARITY: ALL THREE VAULTS OPERATE IDENTICALLY
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Three pools, one per vault, identical bootstrap and identical swap; all vaults
    ///      fully able to serve the position (no drain), so all three sizing paths should land
    ///      on the same effective liquidity from different mechanisms:
    ///        - spUSDT / sUSDT: `min(maxWithdraw, convertToAssets)` (idle exceeds the position)
    ///        - VaultV2: `previewRedeem` fallback behind the zero sentinel
    ///      and identical swaps must produce matching outputs.
    function test_fork_allThreeVaults_operateIdentically() public {
        if (!forked) return;
        IERC4626[3] memory vaults = [SPARK_SPUSDT, SKY_SUSDT, SKY_MORPHO_USDT];
        int24[3] memory spacings = [int24(10), int24(30), int24(60)];

        uint256[3] memory outs;
        for (uint256 i = 0; i < 3; i++) {
            PoolKey memory key = _initVaultedPool(vaults[i], spacings[i]);
            _bootstrap(key, POSITION_PER_SIDE);

            (uint256 eff0, uint256 eff1) = hook.getEffectiveLiquidity(key);
            assertEq(eff0, POSITION_PER_SIDE, "USDC side identical");
            assertApproxEqAbs(eff1, POSITION_PER_SIDE, 10, "USDT side sized to the full position");

            outs[i] = _swapUsdcIn(key, SWAP_IN);
            assertGt(outs[i], (SWAP_IN * 99) / 100, "near-par stable output");
        }

        // Identical pools, identical swaps: outputs match across all three vault mechanisms
        // (tolerance covers per-vault share-conversion rounding dust).
        assertApproxEqRel(outs[0], outs[1], 5e14, "spUSDT vs sUSDT output parity");
        assertApproxEqRel(outs[0], outs[2], 5e14, "spUSDT vs VaultV2 output parity");
    }
}
