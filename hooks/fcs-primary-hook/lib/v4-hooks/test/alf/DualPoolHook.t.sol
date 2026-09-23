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
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {
    InsufficientBootstrap,
    VaultNotBootstrapped,
    InsufficientShares,
    DepositLocked
} from "../../src/alf/types/Shares.sol";

import {DualPoolHook} from "../../src/alf/DualPoolHook.sol";
import {LiquidityBucket} from "../../src/alf/types/Distribution.sol";
import {OwnedALFHook} from "../../src/alf/base/OwnedALFHook.sol";
import {PoolVault} from "../../src/alf/base/PoolVault.sol";
import {InventoryLib} from "../../src/alf/libraries/InventoryLib.sol";
import {ALFHookData} from "../../src/alf/interfaces/IALFHook.sol";
import {PoolNotLive} from "../../src/alf/types/Liveness.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";
import {MockMorphoVaultV2} from "./mocks/MockMorphoVaultV2.sol";
import {MockSparkVault} from "./mocks/MockSparkVault.sol";

/// @title DualPoolHookTest
/// @notice End-to-end tests for DualPoolHook covering pool lifecycle, JIT execution,
///         token compatibility, multi-pool isolation, reentrancy, pricing-state syncing,
///         and quote-vs-execution fidelity.
contract DualPoolHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    DualPoolHook public hook;

    MockERC4626 public vault0;
    MockERC4626 public vault1;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    PoolKey testPoolKey;
    PoolId testPoolId;

    MockERC20 token0;
    MockERC20 token1;

    uint24 constant FEE_PIPS = 1_000; // 0.1%

    /// @dev Exact-output spot checks still assert to the wei; broad quote/execution tests use
    ///      a small relative tolerance because DualPool now uses a compact indicative quote.
    uint256 constant ABS_TOLERANCE = 1;
    uint256 constant INDICATIVE_REL_TOLERANCE = 5e14; // 5 bps

    /// @dev Mirror of `PoolVault._decimalsOffset()` so test expectations can be computed with
    ///      the same EIP-4626 virtual-shares formula the contract uses.
    uint8 internal constant _OFFSET = 12;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        vault0 = new MockERC4626(ERC20(address(token0)));
        vault1 = new MockERC4626(ERC20(address(token1)));

        // Deploy hook at flag-mined address.
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        hook = DualPoolHook(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags)));
        deployCodeTo("DualPoolHook", abi.encode(manager, uint32(100_000), owner, type(uint64).max), address(hook));

        testPoolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: FEE_PIPS, tickSpacing: 10, hooks: IHooks(address(hook))
        });

        vm.prank(owner);
        hook.initializePool(testPoolKey, _defaultConfig());

        testPoolId = testPoolKey.toId();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    function _defaultConfig() internal view returns (DualPoolHook.PoolConfig memory) {
        LiquidityBucket[] memory dist = new LiquidityBucket[](1);
        dist[0] = LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 10_000});
        return DualPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            distribution: dist,
            allowExternalDeposits: false,
            vault0: IERC4626(address(vault0)),
            vault1: IERC4626(address(vault1)),
            minDepositBlocks: 0
        });
    }

    /// @dev Bootstrap-or-deposit. Bootstraps with `(amount, amount)` if the pool is empty;
    ///      otherwise mints `amount` shares proportionally. Advances one block at the end so
    ///      the same-block-withdraw guard does not block immediate `removeLiquidity` in tests.
    function _depositAsOperator(uint256 amount) internal {
        if (hook.totalShares(testPoolId) == 0) {
            // sqrt(amount * amount) = amount → matching-amount bootstrap shares == amount,
            // all credited to the owner. Inflation defense is virtual-shares offsets, not
            // a dead-share lock.
            token0.mint(owner, amount);
            token1.mint(owner, amount);
            vm.startPrank(owner);
            token0.approve(address(hook), amount);
            token1.approve(address(hook), amount);
            hook.bootstrap(testPoolKey, amount, amount);
            vm.stopPrank();
            vm.roll(block.number + 1);
            return;
        }
        (uint256 need0, uint256 need1) = hook.previewDeposit(testPoolKey, amount);
        token0.mint(owner, need0);
        token1.mint(owner, need1);
        vm.startPrank(owner);
        token0.approve(address(hook), need0);
        token1.approve(address(hook), need1);
        hook.addLiquidity(testPoolKey, amount, type(uint256).max, type(uint256).max, block.timestamp);
        vm.stopPrank();
        vm.roll(block.number + 1);
    }

    /// @dev Initialize a second pool sharing the same currencies but with a different
    ///      tickSpacing (so it has a distinct PoolId). Used by cross-pool isolation tests.
    function _initSecondaryPool(bool vaulted, uint256 bootstrapAmount)
        internal
        returns (PoolKey memory key, PoolId id)
    {
        LiquidityBucket[] memory dist = new LiquidityBucket[](1);
        dist[0] = LiquidityBucket({tickLower: -60, tickUpper: 60, weightBps: 10_000});
        key = PoolKey({
            currency0: currency0, currency1: currency1, fee: FEE_PIPS, tickSpacing: 60, hooks: IHooks(address(hook))
        });
        id = key.toId();

        DualPoolHook.PoolConfig memory cfg = DualPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            distribution: dist,
            allowExternalDeposits: true,
            vault0: vaulted ? IERC4626(address(vault0)) : IERC4626(address(0)),
            vault1: vaulted ? IERC4626(address(vault1)) : IERC4626(address(0)),
            minDepositBlocks: 0
        });
        vm.prank(owner);
        hook.initializePool(key, cfg);

        if (bootstrapAmount > 0) {
            token0.mint(owner, bootstrapAmount);
            token1.mint(owner, bootstrapAmount);
            vm.startPrank(owner);
            token0.approve(address(hook), bootstrapAmount);
            token1.approve(address(hook), bootstrapAmount);
            hook.bootstrap(key, bootstrapAmount, bootstrapAmount);
            vm.stopPrank();
            vm.roll(block.number + 1);
        }
    }

    /// @dev Mint `amount` shares to `user` on `key`. Requires the pool to be bootstrapped and
    ///      `externalDepositsEnabled` (or `user == owner`). Advances one block at the end.
    function _externalDeposit(PoolKey memory key, address user, uint256 amount) internal {
        (uint256 need0, uint256 need1) = hook.previewDeposit(key, amount);
        token0.mint(user, need0);
        token1.mint(user, need1);
        vm.startPrank(user);
        token0.approve(address(hook), need0);
        token1.approve(address(hook), need1);
        hook.addLiquidity(key, amount, type(uint256).max, type(uint256).max, block.timestamp);
        vm.stopPrank();
        vm.roll(block.number + 1);
    }

    /// @dev Per-pool reserves match what the pool can actually pay out, AND the sum across
    ///      pools never exceeds the contract's physical backing. Captures both "pool A is
    ///      solvent on its own" and "pool A and pool B are jointly solvent" invariants.
    ///
    ///      Backing = raw ERC-20 balance + ERC4626 vault assets + ERC-6909 claims on PM.
    ///      Claims are part of backing because positive JIT deltas mint them via PM, and they
    ///      become ERC-20 again on the next swap's `_redeemPoolClaims`.
    function _assertCrossPoolSolvency(PoolKey memory keyA, PoolKey memory keyB) internal view {
        (uint256 a0, uint256 a1) = hook.getReserves(keyA);
        (uint256 b0, uint256 b1) = hook.getReserves(keyB);
        uint256 backing0 = token0.balanceOf(address(hook)) + vault0.convertToAssets(vault0.balanceOf(address(hook)))
            + manager.balanceOf(address(hook), currency0.toId());
        uint256 backing1 = token1.balanceOf(address(hook)) + vault1.convertToAssets(vault1.balanceOf(address(hook)))
            + manager.balanceOf(address(hook), currency1.toId());

        assertLe(a0 + b0, backing0, "currency0 solvency: pools claim more than backed");
        assertLe(a1 + b1, backing1, "currency1 solvency: pools claim more than backed");
    }

    /// @dev Replace the pool's distribution with the canonical 3-bucket fixture used by
    ///      quote-fidelity tests: 75% tight, 15% medium, 10% wide — all symmetric around 0.
    function _useMultiBucketDistribution() internal {
        LiquidityBucket[] memory dist = new LiquidityBucket[](3);
        dist[0] = LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 7500});
        dist[1] = LiquidityBucket({tickLower: -30, tickUpper: 30, weightBps: 1500});
        dist[2] = LiquidityBucket({tickLower: -60, tickUpper: 60, weightBps: 1000});
        vm.prank(owner);
        hook.setDistribution(testPoolKey, dist);
    }

    /// @dev Compares `getIndicativeQuote` output to actual swap execution. DualPool uses a
    ///      compact current-liquidity quote so the deployable hook keeps its composability
    ///      surface without carrying the full virtual tick-walk simulator.
    ///
    ///      Per IALFHook: for exact-input (amountSpecified < 0), the quote returns the
    ///      *output* side. For exact-output (amountSpecified > 0), the quote returns the
    ///      *required input* — assert against the input leg accordingly.
    function _assertQuoteFidelity(bool zeroForOne, int256 amountSpecified) internal {
        uint256 quoted = hook.getIndicativeQuote(testPoolKey, zeroForOne, amountSpecified, "");
        assertGt(quoted, 0, "Quote should be non-zero");

        BalanceDelta delta = swap(testPoolKey, zeroForOne, amountSpecified, "");

        // Deployers.swap returns deltas from the swapper:
        //   zeroForOne: amount0 < 0 (input), amount1 > 0 (output)
        //   oneForZero: amount1 < 0 (input), amount0 > 0 (output)
        uint256 actual;
        if (amountSpecified < 0) {
            actual = zeroForOne ? uint256(int256(delta.amount1())) : uint256(int256(delta.amount0()));
        } else {
            actual = zeroForOne ? uint256(-int256(delta.amount0())) : uint256(-int256(delta.amount1()));
        }

        assertApproxEqRel(quoted, actual, INDICATIVE_REL_TOLERANCE, "Quote/execution mismatch");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          POOL INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    function test_initializePool_setsConfig() public view {
        assertFalse(hook.externalDepositsEnabled(testPoolId));
        LiquidityBucket[] memory dist = hook.getDistribution(testPoolId);
        assertEq(dist.length, 1);
        assertEq(dist[0].tickLower, -10);
        assertEq(dist[0].tickUpper, 10);
        assertEq(dist[0].weightBps, 10_000);
    }

    function test_initializePool_revertsOnDirectInit() public {
        PoolKey memory key2 = PoolKey({
            currency0: currency0, currency1: currency1, fee: FEE_PIPS, tickSpacing: 20, hooks: IHooks(address(hook))
        });
        vm.expectRevert();
        manager.initialize(key2, TickMath.getSqrtPriceAtTick(0));
    }

    function test_initializePool_onlyOwner() public {
        PoolKey memory key2 = PoolKey({
            currency0: currency0, currency1: currency1, fee: FEE_PIPS, tickSpacing: 20, hooks: IHooks(address(hook))
        });
        LiquidityBucket[] memory dist = new LiquidityBucket[](1);
        dist[0] = LiquidityBucket({tickLower: -20, tickUpper: 20, weightBps: 10_000});

        vm.prank(alice);
        vm.expectRevert();
        hook.initializePool(
            key2,
            DualPoolHook.PoolConfig({
                sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
                distribution: dist,
                allowExternalDeposits: false,
                vault0: IERC4626(address(vault0)),
                vault1: IERC4626(address(vault1)),
                minDepositBlocks: 0
            })
        );
    }

    /// @dev `renounceOwnership` is overridden in `OwnedALFHook` to revert. Renouncing
    ///      would permanently brick every onlyOwner entry point (initializePool, bootstrap,
    ///      setPoolLive, setExternalDeposits, setDistribution, refreshVaultApproval, etc.)
    ///      and orphan every pool referencing this hook. The operator must use
    ///      `transferOwnership` to rotate, never renounce.
    function test_renounceOwnership_reverts() public {
        vm.prank(owner);
        vm.expectRevert(OwnedALFHook.RenounceOwnershipDisabled.selector);
        hook.renounceOwnership();
    }

    function test_initializePool_revertsOnNativeCurrency0() public {
        LiquidityBucket[] memory dist = new LiquidityBucket[](1);
        dist[0] = LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 10_000});

        PoolKey memory nativeKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: currency1,
            fee: FEE_PIPS,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });
        DualPoolHook.PoolConfig memory cfg = DualPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            distribution: dist,
            allowExternalDeposits: false,
            vault0: IERC4626(address(0)),
            vault1: IERC4626(address(0)),
            minDepositBlocks: 0
        });
        vm.prank(owner);
        vm.expectRevert(DualPoolHook.NativeNotSupported.selector);
        hook.initializePool(nativeKey, cfg);
    }

    /// @dev Ordering normally puts native ETH at currency0; we test currency1=native defensively.
    function test_initializePool_revertsOnNativeCurrency1() public {
        LiquidityBucket[] memory dist = new LiquidityBucket[](1);
        dist[0] = LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 10_000});

        PoolKey memory weirdKey = PoolKey({
            currency0: currency0,
            currency1: Currency.wrap(address(0)),
            fee: FEE_PIPS,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });
        DualPoolHook.PoolConfig memory cfg = DualPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            distribution: dist,
            allowExternalDeposits: false,
            vault0: IERC4626(address(0)),
            vault1: IERC4626(address(0)),
            minDepositBlocks: 0
        });
        vm.prank(owner);
        vm.expectRevert(DualPoolHook.NativeNotSupported.selector);
        hook.initializePool(weirdKey, cfg);
    }

    function test_initializePool_revertsAboveMaxLPFee() public {
        // Fees are static (`PoolKey.fee`); v4's PoolManager rejects fees > MAX_LP_FEE on init.
        LiquidityBucket[] memory dist = new LiquidityBucket[](1);
        dist[0] = LiquidityBucket({tickLower: -60, tickUpper: 60, weightBps: 10_000});
        PoolKey memory key2 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.MAX_LP_FEE + 1,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        DualPoolHook.PoolConfig memory bad = DualPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            distribution: dist,
            allowExternalDeposits: false,
            vault0: IERC4626(address(0)),
            vault1: IERC4626(address(0)),
            minDepositBlocks: 0
        });
        vm.prank(owner);
        vm.expectRevert();
        hook.initializePool(key2, bad);
    }

    /// @dev DualPool's pricing is statically fixed at pool creation via `PoolKey.fee`. The
    ///      v4 PoolManager treats `fee == DYNAMIC_FEE_FLAG (0x800000)` as a signal that the
    ///      hook will set the fee dynamically each swap, which this hook does NOT implement.
    ///      Reject at init so the static-fee contract invariant is enforced at the boundary.
    function test_initializePool_revertsOnDynamicFeeFlag() public {
        LiquidityBucket[] memory dist = new LiquidityBucket[](1);
        dist[0] = LiquidityBucket({tickLower: -60, tickUpper: 60, weightBps: 10_000});
        PoolKey memory dynKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        DualPoolHook.PoolConfig memory cfg = DualPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            distribution: dist,
            allowExternalDeposits: false,
            vault0: IERC4626(address(vault0)),
            vault1: IERC4626(address(vault1)),
            minDepositBlocks: 0
        });
        vm.prank(owner);
        vm.expectRevert(DualPoolHook.DynamicFeeNotSupported.selector);
        hook.initializePool(dynKey, cfg);
    }

    /// @dev Fee-on-entry vaults are rejected at init: the JIT cycle would bleed the entry
    ///      fee on every swap (after-swap re-deposit), and LP deposit math socializes the
    ///      entry-fee shortfall against existing shareholders. See PoolVault's
    ///      `Vault Compatibility` NatSpec for the structural rationale.
    function test_initializePool_revertsOnEntryFeeVault() public {
        MockMorphoVaultV2 feeVault0 = new MockMorphoVaultV2(ERC20(address(token0)));
        feeVault0.setEntryFeeBps(10); // 10 bps entry fee — well above any rounding noise

        LiquidityBucket[] memory dist = new LiquidityBucket[](1);
        dist[0] = LiquidityBucket({tickLower: -60, tickUpper: 60, weightBps: 10_000});
        PoolKey memory feeKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: FEE_PIPS, tickSpacing: 60, hooks: IHooks(address(hook))
        });
        DualPoolHook.PoolConfig memory cfg = DualPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            distribution: dist,
            allowExternalDeposits: false,
            vault0: IERC4626(address(feeVault0)),
            vault1: IERC4626(address(vault1)),
            minDepositBlocks: 0
        });
        vm.prank(owner);
        vm.expectRevert(InventoryLib.VaultChargesEntryFee.selector);
        hook.initializePool(feeKey, cfg);
    }

    /// @dev Fee-on-exit vaults are rejected at init: same JIT-bleed pathology plus a
    ///      first-out-wins / last-out-loses LP redemption race.
    function test_initializePool_revertsOnExitFeeVault() public {
        MockMorphoVaultV2 feeVault1 = new MockMorphoVaultV2(ERC20(address(token1)));
        feeVault1.setExitFeeBps(10); // 10 bps exit fee

        LiquidityBucket[] memory dist = new LiquidityBucket[](1);
        dist[0] = LiquidityBucket({tickLower: -60, tickUpper: 60, weightBps: 10_000});
        PoolKey memory feeKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: FEE_PIPS, tickSpacing: 60, hooks: IHooks(address(hook))
        });
        DualPoolHook.PoolConfig memory cfg = DualPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            distribution: dist,
            allowExternalDeposits: false,
            vault0: IERC4626(address(vault0)),
            vault1: IERC4626(address(feeVault1)),
            minDepositBlocks: 0
        });
        vm.prank(owner);
        vm.expectRevert(InventoryLib.VaultChargesExitFee.selector);
        hook.initializePool(feeKey, cfg);
    }

    /// @dev Regression: a *feeless* vault whose share price has drifted from 1:1 (any vault
    ///      that has accrued yield) must still pass `_requireFeelessVault`. The exit-side probe
    ///      compares `previewRedeem` (shares → assets) against `convertToAssets` (shares →
    ///      assets); these coincide with `convertToShares` only at a 1:1 ratio, so an exit
    ///      check baselined on `convertToShares` would spuriously revert with
    ///      `VaultChargesExitFee` once the vault has yield.
    function test_initializePool_acceptsFeelessVaultAtNonUnitySharePrice() public {
        MockMorphoVaultV2 yieldVault1 = new MockMorphoVaultV2(ERC20(address(token1)));

        // Drive the vault to a 2:1 share price while keeping it strictly feeless: deposit
        // 1_000 assets (mints 1_000 shares at the initial 1:1), then accrue an equal amount of
        // underlying as yield so totalAssets == 2 * totalSupply.
        token1.mint(address(this), 1_000e18);
        token1.approve(address(yieldVault1), 1_000e18);
        yieldVault1.deposit(1_000e18, address(this));
        yieldVault1.simulateYield(1_000e18);

        // Preconditions: share price is genuinely non-1:1, and the vault charges no exit fee.
        uint256 probe = 10 ** uint256(yieldVault1.decimals());
        assertTrue(
            yieldVault1.convertToShares(probe) != yieldVault1.convertToAssets(probe),
            "precondition: share price must be non-1:1 to exercise the bug"
        );
        assertEq(yieldVault1.previewRedeem(probe), yieldVault1.convertToAssets(probe), "vault is feeless on exit");

        LiquidityBucket[] memory dist = new LiquidityBucket[](1);
        dist[0] = LiquidityBucket({tickLower: -60, tickUpper: 60, weightBps: 10_000});
        PoolKey memory feeKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: FEE_PIPS, tickSpacing: 60, hooks: IHooks(address(hook))
        });
        DualPoolHook.PoolConfig memory cfg = DualPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            distribution: dist,
            allowExternalDeposits: false,
            vault0: IERC4626(address(vault0)),
            vault1: IERC4626(address(yieldVault1)),
            minDepositBlocks: 0
        });

        // Must NOT revert: the vault is feeless despite the non-1:1 ratio.
        vm.prank(owner);
        hook.initializePool(feeKey, cfg);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          VAULT CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    function test_vaultsConfiguredAtInit() public view {
        assertEq(address(hook.vaults(testPoolId, currency0)), address(vault0));
        assertEq(address(hook.vaults(testPoolId, currency1)), address(vault1));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              BOOTSTRAP
    // ═══════════════════════════════════════════════════════════════════════════

    function test_bootstrap_onlyOwner() public {
        token0.mint(alice, 1_000e18);
        token1.mint(alice, 1_000e18);
        vm.startPrank(alice);
        token0.approve(address(hook), 1_000e18);
        token1.approve(address(hook), 1_000e18);
        vm.expectRevert();
        hook.bootstrap(testPoolKey, 1_000e18, 1_000e18);
        vm.stopPrank();
    }

    function test_bootstrap_rejectsZeroAmount() public {
        // Bootstrap requires both amounts > 0; the inflation defense relies on virtual-shares
        // offsets in the conversion math (not a sqrt-floor), so even (1, 1) is now allowed.
        token0.mint(owner, 1);
        token1.mint(owner, 1);
        vm.startPrank(owner);
        token0.approve(address(hook), 1);
        token1.approve(address(hook), 1);
        vm.expectRevert(InsufficientBootstrap.selector);
        hook.bootstrap(testPoolKey, 0, 1);
        vm.stopPrank();
    }

    function test_addLiquidity_revertsBeforeBootstrap() public {
        // Use a fresh pool that isn't bootstrapped yet.
        (PoolKey memory key,) = _initSecondaryPool({vaulted: false, bootstrapAmount: 0});

        token0.mint(alice, 100e18);
        token1.mint(alice, 100e18);
        vm.startPrank(alice);
        token0.approve(address(hook), 100e18);
        token1.approve(address(hook), 100e18);
        vm.expectRevert(VaultNotBootstrapped.selector);
        hook.addLiquidity(key, 100e18, type(uint256).max, type(uint256).max, block.timestamp);
        vm.stopPrank();
    }

    function test_bootstrap_supportsAsymmetricAmounts() public {
        // Fresh unvaulted pool; bootstrap with mismatched scales (think USDC-6dp vs WETH-18dp).
        // Amounts are scaled to land above the BootstrapTooSmall floor
        // (`S >= 100 * 10**_decimalsOffset()` = `100 * 1e12` = `1e14` for the default offset).
        (PoolKey memory key, PoolId id) = _initSecondaryPool({vaulted: false, bootstrapAmount: 0});

        uint256 a0 = 1_000_000e6; // 1M "USDC" (6dp)
        uint256 a1 = 100e18; // 100 "WETH" (18dp) — sqrt = 1e16 ≫ 1e14 floor
        token0.mint(owner, a0);
        token1.mint(owner, a1);
        vm.startPrank(owner);
        token0.approve(address(hook), a0);
        token1.approve(address(hook), a1);
        uint256 shares = hook.bootstrap(key, a0, a1);
        vm.stopPrank();

        // sqrt(1e12 * 1e20) = 1e16; bootstrap shares are independent of decimal scale.
        assertGt(shares, 0);
        assertEq(hook.totalShares(id), shares);
        assertEq(hook.userShares(id, owner), shares, "owner gets full bootstrap shares");
        assertEq(hook.userShares(id, address(0)), 0, "no dead-share lock under virtual offsets");
        // Initial ratio reflects what the owner deposited, not 1:1.
        (uint256 r0, uint256 r1) = hook.getReserves(key);
        assertEq(r0, a0);
        assertEq(r1, a1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                       LP DEPOSITS & WITHDRAWALS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_addLiquidity_ownerCanDeposit() public {
        _depositAsOperator(1_000e18);

        // Bootstrap: total shares == sqrt(1000e18 * 1000e18) == 1000e18, all credited to owner.
        // No dead-share lock; inflation defense is virtual-shares offsets in conversion math.
        assertEq(hook.totalShares(testPoolId), 1_000e18);
        assertEq(hook.userShares(testPoolId, owner), 1_000e18);
        assertEq(hook.userShares(testPoolId, address(0)), 0);

        // Tokens routed into vaults.
        assertEq(token0.balanceOf(address(hook)), 0);
        assertEq(token1.balanceOf(address(hook)), 0);
        assertGt(vault0.balanceOf(address(hook)), 0);
        assertGt(vault1.balanceOf(address(hook)), 0);
    }

    function test_addLiquidity_externalUserBlocked() public {
        _depositAsOperator(1_000e18);

        token0.mint(alice, 1_000e18);
        token1.mint(alice, 1_000e18);
        vm.startPrank(alice);
        token0.approve(address(hook), 1_000e18);
        token1.approve(address(hook), 1_000e18);
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        hook.addLiquidity(testPoolKey, 1_000e18, type(uint256).max, type(uint256).max, block.timestamp);
        vm.stopPrank();
    }

    function test_addLiquidity_externalUserAllowedWhenEnabled() public {
        _depositAsOperator(1_000e18);

        vm.prank(owner);
        hook.setExternalDeposits(testPoolKey, true);

        token0.mint(alice, 1_000e18);
        token1.mint(alice, 1_000e18);
        vm.startPrank(alice);
        token0.approve(address(hook), 1_000e18);
        token1.approve(address(hook), 1_000e18);
        hook.addLiquidity(testPoolKey, 1_000e18, type(uint256).max, type(uint256).max, block.timestamp);
        vm.stopPrank();

        assertEq(hook.userShares(testPoolId, alice), 1_000e18);
    }

    function test_removeLiquidity_returnsTokens() public {
        _depositAsOperator(1_000e18);

        uint256 balBefore0 = token0.balanceOf(owner);
        uint256 balBefore1 = token1.balanceOf(owner);
        uint256 ownerSharesBefore = hook.userShares(testPoolId, owner);

        vm.prank(owner);
        hook.removeLiquidity(testPoolKey, 500e18, 0, 0, block.timestamp);

        // Withdraw rounds DOWN: floor(500e18 * (1000e18 + 1) / (1000e18 + 1e12)).
        uint256 expected = FixedPointMathLib.fullMulDiv(500e18, 1000e18 + 1, 1000e18 + 10 ** _OFFSET);
        assertEq(hook.userShares(testPoolId, owner), ownerSharesBefore - 500e18);
        assertEq(hook.totalShares(testPoolId), 1_000e18 - 500e18);
        assertEq(token0.balanceOf(owner) - balBefore0, expected);
        assertEq(token1.balanceOf(owner) - balBefore1, expected);
    }

    function test_removeLiquidity_revertsInsufficientShares() public {
        _depositAsOperator(1_000e18);

        vm.prank(owner);
        vm.expectRevert(InsufficientShares.selector);
        hook.removeLiquidity(testPoolKey, 2_000e18, 0, 0, block.timestamp);
    }

    /// @dev Deposit-then-withdraw within the configured lock duration is rejected --
    ///      defends against atomic JIT-fee/yield sniping. Uses a pool initialized with
    ///      `minDepositBlocks: 5` so the test exercises the general case, not just the
    ///      degenerate same-block ban.
    function test_removeLiquidity_revertsBeforeUnlockBlock() public {
        (PoolKey memory lockedKey,) = _initLockedPool(5);
        _bootstrapLockedPool(lockedKey, 1_000e18);

        token0.mint(bob, 100e18);
        token1.mint(bob, 100e18);
        vm.startPrank(bob);
        token0.approve(address(hook), 100e18);
        token1.approve(address(hook), 100e18);
        hook.addLiquidity(lockedKey, 100e18, type(uint256).max, type(uint256).max, block.timestamp);
        uint256 unlockBlock = block.number + 5;

        // Roll just below the unlock block.
        vm.roll(unlockBlock - 1);
        vm.expectRevert(abi.encodeWithSelector(DepositLocked.selector, unlockBlock));
        hook.removeLiquidity(lockedKey, 100e18, 0, 0, block.timestamp);
        vm.stopPrank();
    }

    function test_removeLiquidity_succeedsAtUnlockBlock() public {
        (PoolKey memory lockedKey,) = _initLockedPool(5);
        _bootstrapLockedPool(lockedKey, 1_000e18);

        token0.mint(bob, 100e18);
        token1.mint(bob, 100e18);
        vm.startPrank(bob);
        token0.approve(address(hook), 100e18);
        token1.approve(address(hook), 100e18);
        hook.addLiquidity(lockedKey, 100e18, type(uint256).max, type(uint256).max, block.timestamp);
        vm.stopPrank();

        // Roll past the 5-block lock.
        vm.roll(block.number + 5);
        vm.prank(bob);
        hook.removeLiquidity(lockedKey, 100e18, 0, 0, block.timestamp);
    }

    /// @dev Regression: a pool initialized with `minDepositBlocks: 0` permits same-block
    ///      deposit-then-withdraw. This is a deliberate semantic change from the legacy
    ///      unconditional same-block ban; the test locks the new default into CI so anyone
    ///      tightening it in the future is forced to update this assertion.
    function test_removeLiquidity_succeedsWhenMinDepositBlocksIsZero() public {
        // testPoolKey is initialized with minDepositBlocks: 0 via _defaultConfig.
        vm.prank(owner);
        hook.setExternalDeposits(testPoolKey, true);

        // Bootstrap (advances one block in the helper); now bob deposits AND withdraws in the
        // same block -- the zero-lock default permits this.
        _depositAsOperator(1_000e18);
        token0.mint(bob, 100e18);
        token1.mint(bob, 100e18);
        vm.startPrank(bob);
        token0.approve(address(hook), 100e18);
        token1.approve(address(hook), 100e18);
        hook.addLiquidity(testPoolKey, 100e18, type(uint256).max, type(uint256).max, block.timestamp);
        // No vm.roll -- same block as the deposit.
        hook.removeLiquidity(testPoolKey, 50e18, 0, 0, block.timestamp);
        vm.stopPrank();
    }

    /// @dev `initializePool` rejects `minDepositBlocks > maxMinDepositBlocks`. Deploys a
    ///      dedicated hook with a small `_maxMinDepositBlocks` so we don't have to rebuild
    ///      `testPoolKey`.
    function test_initializePool_revertsOnMinDepositBlocksTooLarge() public {
        // Deploy a fresh hook with maxMinDepositBlocks=100 at a non-conflicting address.
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        // Vary the base address slightly so it differs from the setUp hook.
        address tightAddr = address(uint160(uint256(type(uint160).max - 1) & clearAllHookPermissionsMask | flags));
        deployCodeTo("DualPoolHook", abi.encode(manager, uint32(100_000), owner, uint64(100)), tightAddr);
        DualPoolHook tight = DualPoolHook(tightAddr);

        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: FEE_PIPS, tickSpacing: 11, hooks: IHooks(tightAddr)
        });
        LiquidityBucket[] memory dist = new LiquidityBucket[](1);
        dist[0] = LiquidityBucket({tickLower: -11, tickUpper: 11, weightBps: 10_000});
        DualPoolHook.PoolConfig memory cfg = DualPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            distribution: dist,
            allowExternalDeposits: false,
            vault0: IERC4626(address(vault0)),
            vault1: IERC4626(address(vault1)),
            minDepositBlocks: 101 // one over the bound
        });
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(DualPoolHook.MinDepositBlocksTooLarge.selector, uint64(101), uint64(100))
        );
        tight.initializePool(key, cfg);
    }

    /// @dev Regression: after a swap, `afterSwap` mints positive hook deltas as ERC-6909
    ///      claims and `_depositAllToVaults` sweeps `s.erc20` to 0. An LP withdrawing in
    ///      this between-swaps window is owed an amount priced against the (erc20 + claims
    ///      + vault) total, but `_ensureERC20` historically inspected `s.erc20` and the
    ///      vault only -- so `vault.withdraw(amount)` could be called with `amount` larger
    ///      than the vault's idle reserves (because the claim portion isn't actually held
    ///      by the vault), bricking exits whenever the vault is even mildly capacity-bound.
    ///
    ///      To prove the bug, we use a `MockMorphoVaultV2` with an explicit
    ///      `maxWithdrawable` cap set BELOW the LP's full pro-rata payout but ABOVE
    ///      `payout - claims`. Pre-fix `_ensureERC20` would call `vault.withdraw(payout)`
    ///      and revert; post-fix the unlock-callback redeems claims first, the
    ///      `_ensureERC20` early-return path covers the claim portion from `s.erc20`, and
    ///      `vault.withdraw` is called only for the residual `payout - claims`, which fits
    ///      within the cap.
    function test_removeLiquidity_succeedsWithPendingClaims_postSwap() public {
        // Fresh pool with VaultV2-shaped vaults so we can configure `maxWithdrawable`.
        MockMorphoVaultV2 mv0 = new MockMorphoVaultV2(ERC20(address(token0)));
        MockMorphoVaultV2 mv1 = new MockMorphoVaultV2(ERC20(address(token1)));

        LiquidityBucket[] memory dist = new LiquidityBucket[](1);
        dist[0] = LiquidityBucket({tickLower: -60, tickUpper: 60, weightBps: 10_000});
        PoolKey memory mvKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: FEE_PIPS, tickSpacing: 60, hooks: IHooks(address(hook))
        });
        PoolId mvId = mvKey.toId();

        DualPoolHook.PoolConfig memory cfg = DualPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            distribution: dist,
            allowExternalDeposits: true,
            vault0: IERC4626(address(mv0)),
            vault1: IERC4626(address(mv1)),
            minDepositBlocks: 0
        });
        vm.prank(owner);
        hook.initializePool(mvKey, cfg);

        // Bootstrap with 10_000 each; owner is sole LP for the bug-exposure scenario.
        uint256 bootstrapAmount = 10_000e18;
        token0.mint(owner, bootstrapAmount);
        token1.mint(owner, bootstrapAmount);
        vm.startPrank(owner);
        token0.approve(address(hook), bootstrapAmount);
        token1.approve(address(hook), bootstrapAmount);
        hook.bootstrap(mvKey, bootstrapAmount, bootstrapAmount);
        vm.stopPrank();
        vm.roll(block.number + 1);

        // Swap to seed an ERC-6909 claim on the positive-delta side. After this, the
        // afterSwap settlement leaves `s.claims[currency_with_positive_delta] > 0` and
        // `_depositAllToVaults` has reset both `s.erc20` slots to 0.
        swap(mvKey, true, -100e18, "");

        // Snapshot the vault's actual underlying balances and the implied pro-rata payouts.
        uint256 vaultBal0 = token0.balanceOf(address(mv0));
        uint256 vaultBal1 = token1.balanceOf(address(mv1));
        uint256 ownerShares = hook.userShares(mvId, owner);
        (uint256 expectedAmount0, uint256 expectedAmount1) = hook.previewWithdraw(mvKey, ownerShares);

        // Without the fix, `_ensureERC20` would call `vault.withdraw(expectedAmount)` on the
        // claim-side currency. Cap the vault at exactly the idle balance so any oversized
        // request (i.e., one that includes the claim portion) reverts.
        mv0.setMaxWithdrawable(vaultBal0);
        mv1.setMaxWithdrawable(vaultBal1);

        // Sanity-check that the cap actually bites the un-patched path: at least one side's
        // expected payout must exceed its vault's idle balance, otherwise the test wouldn't
        // distinguish the fix from the bug.
        assertTrue(
            expectedAmount0 > vaultBal0 || expectedAmount1 > vaultBal1,
            "test fixture must produce a claim-induced shortfall"
        );

        // With the fix in place: unlock-callback redeems claims, `_ensureERC20` consumes
        // the claim portion from `s.erc20`, and `vault.withdraw` is called for only the
        // residual that fits within the cap. Without the fix, this would revert.
        vm.prank(owner);
        (uint256 amount0, uint256 amount1) = hook.removeLiquidity(mvKey, ownerShares, 0, 0, block.timestamp);

        assertEq(hook.userShares(mvId, owner), 0, "shares burned");
        assertEq(amount0, expectedAmount0, "currency0 payout matches preview");
        assertEq(amount1, expectedAmount1, "currency1 payout matches preview");
    }

    /// @dev Regression for the Spark integration report (July 2026): a liquidity-gated vault
    ///      (SparkVault) reverts `previewRedeem` whenever the pool's position value exceeds
    ///      the vault's idle liquidity, which is the vault's normal state once capital is
    ///      deployed. previewRedeem-primary sizing therefore reverted every swap in
    ///      `beforeSwap` (`_deployJIT` -> `_effectiveAssets`), regardless of swap size. The
    ///      required flow is `swap amount < vault idle liquidity < pool position value`; with
    ///      `maxWithdraw`-first sizing the JIT cycle sizes to the idle-capped figure and the
    ///      swap clears.
    function test_swap_succeedsWhenSparkVaultIdleBelowPositionValue() public {
        MockSparkVault spark0 = new MockSparkVault(ERC20(address(token0)));
        MockSparkVault spark1 = new MockSparkVault(ERC20(address(token1)));

        LiquidityBucket[] memory dist = new LiquidityBucket[](1);
        dist[0] = LiquidityBucket({tickLower: -60, tickUpper: 60, weightBps: 10_000});
        PoolKey memory sparkKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: FEE_PIPS, tickSpacing: 60, hooks: IHooks(address(hook))
        });

        vm.prank(owner);
        hook.initializePool(
            sparkKey,
            DualPoolHook.PoolConfig({
                sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
                distribution: dist,
                allowExternalDeposits: true,
                vault0: IERC4626(address(spark0)),
                vault1: IERC4626(address(spark1)),
                minDepositBlocks: 0
            })
        );

        // Pool position value: 1000 per side, all vaulted after bootstrap.
        uint256 bootstrapAmount = 1_000e18;
        token0.mint(owner, bootstrapAmount);
        token1.mint(owner, bootstrapAmount);
        vm.startPrank(owner);
        token0.approve(address(hook), bootstrapAmount);
        token1.approve(address(hook), bootstrapAmount);
        hook.bootstrap(sparkKey, bootstrapAmount, bootstrapAmount);
        vm.stopPrank();
        vm.roll(block.number + 1);

        // The vaults deploy 600 of their 1000 idle: swap (100) < idle (400) < position (1000).
        address allocator = makeAddr("sparkAllocator");
        spark0.allocate(allocator, 600e18);
        spark1.allocate(allocator, 600e18);

        // Fixture reproduces the reported state: previewRedeem on the pool's position reverts.
        uint256 position0 = spark0.balanceOf(address(hook));
        vm.expectRevert("SparkVault/insufficient-liquidity");
        spark0.previewRedeem(position0);

        // The integrator view reports the idle-capped figure instead of reverting (and instead
        // of the inflated previewRedeem value a fully liquid vault would report).
        (uint256 eff0, uint256 eff1) = hook.getEffectiveLiquidity(sparkKey);
        assertEq(eff0, 400e18, "token0 effective liquidity capped at idle");
        assertEq(eff1, 400e18, "token1 effective liquidity capped at idle");

        // The swap clears: the JIT cycle sizes to idle and withdraws within the vault's gate.
        uint256 out1Before = token1.balanceOf(address(this));
        swap(sparkKey, true, -100e18, "");
        assertGt(token1.balanceOf(address(this)) - out1Before, 0, "swap executed and delivered output");
    }

    /// @dev `unlockCallback` is `external` and decodes its argument into an LP withdraw.
    ///      Only the PoolManager (acting as a re-entrant continuation of our own
    ///      `poolManager.unlock` call) may invoke it; a direct call from anyone else with
    ///      crafted data must revert.
    function test_unlockCallback_revertsForUnauthorizedCaller() public {
        bytes memory payload = abi.encode(testPoolKey, owner, uint256(1));
        vm.expectRevert(DualPoolHook.UnauthorizedCallback.selector);
        hook.unlockCallback(payload);
    }

    /// @dev Helper: deploy a fresh pool with the given lock duration. The pool uses a
    ///      distinct tickSpacing so its PoolId differs from `testPoolKey`'s.
    function _initLockedPool(uint64 lockBlocks) internal returns (PoolKey memory key, PoolId id) {
        LiquidityBucket[] memory dist = new LiquidityBucket[](1);
        dist[0] = LiquidityBucket({tickLower: -12, tickUpper: 12, weightBps: 10_000});
        key = PoolKey({
            currency0: currency0, currency1: currency1, fee: FEE_PIPS, tickSpacing: 12, hooks: IHooks(address(hook))
        });
        id = key.toId();
        DualPoolHook.PoolConfig memory cfg = DualPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            distribution: dist,
            allowExternalDeposits: true,
            vault0: IERC4626(address(vault0)),
            vault1: IERC4626(address(vault1)),
            minDepositBlocks: lockBlocks
        });
        vm.prank(owner);
        hook.initializePool(key, cfg);
    }

    function _bootstrapLockedPool(PoolKey memory key, uint256 amount) internal {
        token0.mint(owner, amount);
        token1.mint(owner, amount);
        vm.startPrank(owner);
        token0.approve(address(hook), amount);
        token1.approve(address(hook), amount);
        hook.bootstrap(key, amount, amount);
        vm.stopPrank();
        // Step past the bootstrap lock.
        vm.roll(block.number + hook.minDepositBlocks(key.toId()));
    }

    /// @dev External actors cannot touch v4 LP positions directly — only the hook may.
    function test_externalLP_addBlocked() public {
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            testPoolKey,
            ModifyLiquidityParams({tickLower: -10, tickUpper: 10, liquidityDelta: 1000, salt: bytes32(0)}),
            ""
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          JIT SWAP CYCLE
    // ═══════════════════════════════════════════════════════════════════════════

    function test_swap_executesJITCycle() public {
        _depositAsOperator(10_000e18);

        // No LP in the v4 pool before the swap.
        uint128 liquidityBefore = manager.getLiquidity(testPoolId);
        assertEq(liquidityBefore, 0);

        swap(testPoolKey, true, -100e18, "");

        // No LP after the swap either — JIT positions were torn down.
        uint128 liquidityAfter = manager.getLiquidity(testPoolId);
        assertEq(liquidityAfter, 0);

        // Hook still has assets (slightly rebalanced).
        (uint256 reserves0, uint256 reserves1) = hook.getReserves(testPoolKey);
        assertGt(reserves0 + reserves1, 0);
    }

    /// @dev Coverage test for the multi-swap-per-tx code path. `_removeJIT`'s per-bucket
    ///      transient slots scope to the transaction, not the unlock, so two swaps on the
    ///      same pool within one tx share state. The fix clears each slot after read in
    ///      `_removeJIT`, so subsequent swaps see a clean slate.
    ///
    ///      This smoke test exercises the cleared-slot code path and ensures basic
    ///      multi-swap-per-tx liveness; correctness of the fix is verifiable by reading
    ///      the pool's liquidity after the last swap lands (should be zero).
    function test_swap_multipleInSameTx_succeeds() public {
        _depositAsOperator(10_000e18);

        // Two swaps in the same test transaction. Each invokes a fresh unlock but shares
        // the tx-scoped transient namespace.
        swap(testPoolKey, true, -100e18, "");
        swap(testPoolKey, true, -100e18, "");

        // Sanity: both swaps left the pool in a coherent state.
        (uint256 r0, uint256 r1) = hook.getReserves(testPoolKey);
        assertGt(r0 + r1, 0, "reserves intact after consecutive swaps");
        assertEq(manager.getLiquidity(testPoolId), 0, "no orphaned LP after tx ends");
    }

    function test_swap_movesPrice() public {
        _depositAsOperator(10_000e18);

        (, int24 tickBefore,,) = manager.getSlot0(testPoolId);
        swap(testPoolKey, true, -1_000e18, "");
        (, int24 tickAfter,,) = manager.getSlot0(testPoolId);

        assertLt(tickAfter, tickBefore, "zeroForOne should drop tick");
    }

    /// @dev Swaps on a pool that's been `initializePool`'d but not yet `bootstrap`'d are
    ///      rejected. Liveness is now gated on bootstrap: `initializePool` creates the pool
    ///      with `livePools[poolId] = false`, and `bootstrap` flips it true after the first
    ///      shares mint. Without this, a swapper could shift slot0's `sqrtPriceX96` against
    ///      a zero-liquidity pool in the init→bootstrap window and extract value from the
    ///      first real swap afterwards.
    function test_swap_revertsBeforeBootstrap() public {
        // testPoolKey is initialized in setUp() but never bootstrapped here. v4 wraps the
        // hook's revert in CustomRevert.WrappedError; assert the full envelope so a future
        // change that swaps the inner error (e.g., PoolNotLive -> PoolNotBootstrapped) is
        // caught instead of silently passing under a generic `vm.expectRevert()`.
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(PoolNotLive.selector, testPoolId),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(testPoolKey, true, -100e18, "");
    }

    function test_swap_revertsWhenPoolNotLive() public {
        _depositAsOperator(1_000e18);

        vm.prank(owner);
        hook.setPoolLive(testPoolKey, false);

        // Paused pools surface a hard `PoolNotLive(poolId)` error so routers and aggregators
        // can route flow elsewhere instead of silently no-op'ing through zero JIT liquidity.
        // v4 wraps hook reverts; assert the inner selector is present in the bubbled payload.
        vm.expectRevert();
        swap(testPoolKey, true, -1e18, "");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EMERGENCY VAULT REVOCATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev The atomic emergency lever flips all three pieces of state: both vault allowances
    ///      to zero, external deposits off, and the pool paused. After it runs, swaps revert.
    function test_emergencyRevokeVault_zeroesAllowancesPausesAndDisablesDeposits() public {
        _depositAsOperator(1_000e18);
        vm.prank(owner);
        hook.setExternalDeposits(testPoolKey, true);

        // Pre-state: standing max allowance to each vault, pool live, external deposits on.
        assertEq(token0.allowance(address(hook), address(vault0)), type(uint256).max, "pre: allowance0 != max");
        assertEq(token1.allowance(address(hook), address(vault1)), type(uint256).max, "pre: allowance1 != max");
        assertTrue(hook.livePools(testPoolId), "pre: not live");
        assertTrue(hook.externalDepositsEnabled(testPoolId), "pre: external deposits off");

        vm.prank(owner);
        hook.emergencyRevokeVault(testPoolKey);

        assertEq(token0.allowance(address(hook), address(vault0)), 0, "post: allowance0 != 0");
        assertEq(token1.allowance(address(hook), address(vault1)), 0, "post: allowance1 != 0");
        assertFalse(hook.livePools(testPoolId), "post: still live");
        assertFalse(hook.externalDepositsEnabled(testPoolId), "post: external deposits still on");

        // Swaps now revert (pool paused).
        vm.expectRevert();
        swap(testPoolKey, true, -1e18, "");
    }

    /// @dev Demonstrates the actual protection: a (now-suspect) vault holding the hook's
    ///      standing allowance can `transferFrom` the hook's raw token balance before
    ///      revocation, and is blocked after. The raw balance stands in for funds attributed to
    ///      a vault-less sibling pool sharing the currency.
    function test_emergencyRevokeVault_blocksVaultTransferFrom() public {
        _depositAsOperator(1_000e18);
        address attacker = makeAddr("attacker");

        // Hook holds raw token0 (e.g. a vault-less sibling pool's balance).
        token0.mint(address(hook), 2e18);

        // Before revocation: the vault's standing allowance lets it pull the hook's balance.
        vm.prank(address(vault0));
        token0.transferFrom(address(hook), attacker, 1e18);
        assertEq(token0.balanceOf(attacker), 1e18, "pre: drain should succeed via standing allowance");

        vm.prank(owner);
        hook.emergencyRevokeVault(testPoolKey);

        // After revocation: the same pull reverts (allowance is now zero).
        vm.prank(address(vault0));
        vm.expectRevert();
        token0.transferFrom(address(hook), attacker, 1e18);
    }

    /// @dev The load-bearing correction: because `addLiquidity` is not liveness-gated, disabling
    ///      external deposits is what actually prevents an external depositor from re-arming the
    ///      allowance via the deposit path while the pool is paused.
    function test_emergencyRevokeVault_externalDepositCannotReArm() public {
        _depositAsOperator(1_000e18);
        vm.prank(owner);
        hook.setExternalDeposits(testPoolKey, true);

        vm.prank(owner);
        hook.emergencyRevokeVault(testPoolKey);
        assertEq(token0.allowance(address(hook), address(vault0)), 0, "allowance not zeroed");

        // An external depositor can no longer call addLiquidity (deposits disabled), so the
        // `_ensureVaultAllowance` re-approval path is unreachable.
        (uint256 need0, uint256 need1) = hook.previewDeposit(testPoolKey, 100e18);
        token0.mint(alice, need0);
        token1.mint(alice, need1);
        vm.startPrank(alice);
        token0.approve(address(hook), need0);
        token1.approve(address(hook), need1);
        vm.expectRevert(DualPoolHook.Unauthorized.selector);
        hook.addLiquidity(testPoolKey, 100e18, type(uint256).max, type(uint256).max, block.timestamp);
        vm.stopPrank();

        // Allowance remains revoked.
        assertEq(token0.allowance(address(hook), address(vault0)), 0, "allowance silently re-armed");
    }

    /// @dev LPs are not trapped: an existing shareholder can still exit after revocation. The
    ///      vault-withdraw path needs no hook→vault allowance, so it neither re-arms nor reverts.
    function test_emergencyRevokeVault_removeLiquidityStillWorks() public {
        _depositAsOperator(1_000e18); // owner holds 1_000e18 shares

        vm.prank(owner);
        hook.emergencyRevokeVault(testPoolKey);

        vm.prank(owner);
        (uint256 out0, uint256 out1) = hook.removeLiquidity(testPoolKey, 500e18, 0, 0, block.timestamp);

        assertGt(out0, 0, "LP exit returned zero token0");
        assertGt(out1, 0, "LP exit returned zero token1");
        assertEq(hook.userShares(testPoolId, owner), 500e18, "shares not burned on exit");
    }

    /// @dev Only the owner may trigger the emergency lever.
    function test_emergencyRevokeVault_onlyOwner() public {
        _depositAsOperator(1_000e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        hook.emergencyRevokeVault(testPoolKey);
    }

    /// @dev The rescue leg: a cooperative vault's assets are pulled back out into the hook's
    ///      raw ledger, so they sit outside the suspect vault's reach. Economically neutral —
    ///      `getReserves` is unchanged because vault assets simply become raw ERC-20.
    function test_emergencyRevokeVault_drainsCooperativeVault() public {
        _depositAsOperator(1_000e18);

        (uint256 res0Before, uint256 res1Before) = hook.getReserves(testPoolKey);
        assertEq(vault0.balanceOf(address(hook)), 1_000e18, "pre: vault0 holds pool shares");
        assertEq(token0.balanceOf(address(hook)), 0, "pre: hook holds no raw token0");

        vm.prank(owner);
        hook.emergencyRevokeVault(testPoolKey);

        // Assets pulled out of the vault into the hook's raw balance.
        assertEq(vault0.balanceOf(address(hook)), 0, "post: vault0 shares not drained");
        assertEq(vault1.balanceOf(address(hook)), 0, "post: vault1 shares not drained");
        assertEq(token0.balanceOf(address(hook)), 1_000e18, "post: token0 not rescued to raw");
        assertEq(token1.balanceOf(address(hook)), 1_000e18, "post: token1 not rescued to raw");

        // Economically neutral: total reserves unchanged (vault assets -> raw ERC-20).
        (uint256 res0After, uint256 res1After) = hook.getReserves(testPoolKey);
        assertEq(res0After, res0Before, "reserves0 changed by drain");
        assertEq(res1After, res1Before, "reserves1 changed by drain");
    }

    /// @dev Best-effort guarantee: if the vault is bricked and reverts on redeem, the rescue is
    ///      skipped but the revocation + pause still land. The protections must never depend on
    ///      a compromised vault cooperating.
    function test_emergencyRevokeVault_drainBestEffortWhenVaultBricked() public {
        MockMorphoVaultV2 mv0 = new MockMorphoVaultV2(ERC20(address(token0)));
        MockMorphoVaultV2 mv1 = new MockMorphoVaultV2(ERC20(address(token1)));

        LiquidityBucket[] memory dist = new LiquidityBucket[](1);
        dist[0] = LiquidityBucket({tickLower: -60, tickUpper: 60, weightBps: 10_000});
        PoolKey memory mvKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: FEE_PIPS, tickSpacing: 60, hooks: IHooks(address(hook))
        });
        PoolId mvId = mvKey.toId();
        DualPoolHook.PoolConfig memory cfg = DualPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            distribution: dist,
            allowExternalDeposits: false,
            vault0: IERC4626(address(mv0)),
            vault1: IERC4626(address(mv1)),
            minDepositBlocks: 0
        });
        vm.prank(owner);
        hook.initializePool(mvKey, cfg);

        token0.mint(owner, 1_000e18);
        token1.mint(owner, 1_000e18);
        vm.startPrank(owner);
        token0.approve(address(hook), 1_000e18);
        token1.approve(address(hook), 1_000e18);
        hook.bootstrap(mvKey, 1_000e18, 1_000e18);
        vm.stopPrank();
        vm.roll(block.number + 1);

        uint256 sharesHeld = mv0.balanceOf(address(hook));
        assertGt(sharesHeld, 0, "precondition: hook holds vault shares");

        // Brick both vaults so the drain's `redeem` reverts.
        mv0.setWithdrawShortfall(true);
        mv1.setWithdrawShortfall(true);

        // Must NOT revert despite the failed drain.
        vm.prank(owner);
        hook.emergencyRevokeVault(mvKey);

        // Protections landed regardless of the vault being bricked.
        assertEq(token0.allowance(address(hook), address(mv0)), 0, "allowance0 not zeroed");
        assertEq(token1.allowance(address(hook), address(mv1)), 0, "allowance1 not zeroed");
        assertFalse(hook.livePools(mvId), "pool not paused");
        assertFalse(hook.externalDepositsEnabled(mvId), "external deposits not disabled");

        // Drain was skipped: the assets remain in the (bricked) vault.
        assertEq(mv0.balanceOf(address(hook)), sharesHeld, "shares should remain after skipped drain");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        RESERVES & QUOTE VIEWS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_getReserves_returnsVaultBalances() public {
        _depositAsOperator(5_000e18);
        (uint256 r0, uint256 r1) = hook.getReserves(testPoolKey);
        assertEq(r0, 5_000e18);
        assertEq(r1, 5_000e18);
    }

    function test_getEffectiveLiquidity_matchesReserves() public {
        _depositAsOperator(5_000e18);
        (uint256 r0, uint256 r1) = hook.getReserves(testPoolKey);
        (uint256 e0, uint256 e1) = hook.getEffectiveLiquidity(testPoolKey);
        assertEq(r0, e0);
        assertEq(r1, e1);
    }

    function test_indicativeQuote_returnsNonZero() public {
        _depositAsOperator(10_000e18);
        uint256 quote = hook.getIndicativeQuote(testPoolKey, true, -100e18, "");
        assertGt(quote, 0);
    }

    function test_indicativeQuote_returnsZeroWhenEmpty() public view {
        uint256 quote = hook.getIndicativeQuote(testPoolKey, true, -100e18, "");
        assertEq(quote, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //              hookData IGNORED BY DualPoolHook (BY DESIGN)
    // ═══════════════════════════════════════════════════════════════════════════
    //
    //  DualPoolHook overrides `_beforeSwap`, `getIndicativeQuote`, and `swapToPrice`
    //  to ignore hookData entirely — pricing is fully owner-controlled.

    function test_swap_ignoresHookData() public {
        _depositAsOperator(10_000e18);

        bytes memory hookData = abi.encode(ALFHookData({attestationData: bytes("anything")}));

        bool liveBefore = hook.livePools(testPoolId);
        swap(testPoolKey, true, -1e18, hookData);
        bool liveAfter = hook.livePools(testPoolId);

        assertEq(liveAfter, liveBefore, "stored live unchanged");
    }

    function test_indicativeQuote_ignoresHookData() public {
        _depositAsOperator(10_000e18);

        bytes memory hookData = abi.encode(ALFHookData({attestationData: bytes("anything")}));

        uint256 quoteWithData = hook.getIndicativeQuote(testPoolKey, true, -1e18, hookData);
        uint256 quoteWithEmpty = hook.getIndicativeQuote(testPoolKey, true, -1e18, "");
        assertEq(quoteWithData, quoteWithEmpty, "hookData has no effect on quote");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //              INDICATIVE RESERVE CAP (fix 2)
    // ═══════════════════════════════════════════════════════════════════════════
    //
    //  The single-step constant-liquidity estimate extrapolates in-range bucket depth to the
    //  price extreme, so for swaps large enough to exhaust the deployed buckets it would report
    //  far more output than the pool holds. The quote is capped at the effective output reserve.

    /// @dev A swap large enough to exhaust the buckets must not quote more output than the pool
    ///      can deliver: the exact-input estimate is capped at the effective output reserve.
    function test_indicativeQuote_cappedAtEffectiveReserve_exactIn() public {
        _depositAsOperator(1_000e18);
        (uint256 eff0, uint256 eff1) = hook.getEffectiveLiquidity(testPoolKey);
        assertGt(eff1, 0, "precondition: pool has reserves");

        // Huge exact-input ZF1 (output = token1) caps at the token1 reserve.
        uint256 qZF1 = hook.getIndicativeQuote(testPoolKey, true, -int256(type(int128).max), "");
        assertEq(qZF1, eff1, "ZF1 indicative caps at effective token1 reserve");

        // Huge exact-input 1F0 (output = token0) caps at the token0 reserve.
        uint256 q1F0 = hook.getIndicativeQuote(testPoolKey, false, -int256(type(int128).max), "");
        assertEq(q1F0, eff0, "1F0 indicative caps at effective token0 reserve");
    }

    /// @dev A small swap stays well below the reserve cap, so the cap is inactive and the quote is
    ///      the unmodified constant-liquidity estimate.
    function test_indicativeQuote_smallSwapUnaffectedByCap() public {
        _depositAsOperator(1_000e18);
        (, uint256 eff1) = hook.getEffectiveLiquidity(testPoolKey);

        uint256 q = hook.getIndicativeQuote(testPoolKey, true, -1e18, "");
        assertGt(q, 0, "non-zero");
        assertLt(q, eff1, "small-swap output is well below the reserve cap");
    }

    /// @dev Exact output that exceeds deliverable reserves has no honest fill, so the quote is 0;
    ///      a request within reserves still returns a positive required input.
    function test_indicativeQuote_exactOutBeyondReservesReturnsZero() public {
        _depositAsOperator(1_000e18);
        (, uint256 eff1) = hook.getEffectiveLiquidity(testPoolKey);

        uint256 qTooBig = hook.getIndicativeQuote(testPoolKey, true, int256(eff1 + 1e18), "");
        assertEq(qTooBig, 0, "exact-out beyond reserves returns 0 (no quote)");

        uint256 qOk = hook.getIndicativeQuote(testPoolKey, true, int256(1e18), "");
        assertGt(qOk, 0, "exact-out within reserves returns required input");
    }

    /// @dev The cap keeps `getIndicativeQuote` and `swapToPrice` consistent: both go through
    ///      `_simulateIndicative`, so the capped output leg matches even at the full price range.
    function test_indicativeQuote_capConsistentWithSwapToPrice() public {
        _depositAsOperator(1_000e18);
        uint160 limit = TickMath.MIN_SQRT_PRICE + 1;

        uint256 q = hook.getIndicativeQuote(testPoolKey, true, -int256(type(int128).max), "");
        (, uint256 outAmt) = hook.swapToPrice(testPoolKey, true, -int256(type(int128).max), limit, "");
        assertEq(q, outAmt, "capped getIndicativeQuote must match swapToPrice output leg");
    }

    /// @dev When the reserve cap binds, `swapToPrice` recomputes the input leg as the exact-output
    ///      cost of draining the deliverable reserve, so the returned (amountIn, amountOut) pair is
    ///      internally consistent: `amountIn` prices exactly `amountOut`. Unlike `getIndicativeQuote`,
    ///      `swapToPrice` returns the capped partial fill rather than zeroing, since the pair is the
    ///      honest maximal drain a split planner can route against.
    function test_swapToPrice_capRecomputesConsistentInputLeg() public {
        _depositAsOperator(1_000e18);
        (, uint256 eff1) = hook.getEffectiveLiquidity(testPoolKey);
        uint160 limit = TickMath.MIN_SQRT_PRICE + 1;

        // Huge exact-input ZF1: output caps at the token1 reserve, input leg recomputed for the drain.
        (uint256 ain, uint256 aout) = hook.swapToPrice(testPoolKey, true, -int256(type(int128).max), limit, "");
        assertEq(aout, eff1, "exact-input output leg caps at effective token1 reserve");
        assertGt(ain, 0, "input leg must be priced for the deliverable drain");

        // The recomputed input must equal the exact-output cost of producing the capped output.
        uint256 requiredIn = hook.getIndicativeQuote(testPoolKey, true, int256(aout), "");
        assertEq(ain, requiredIn, "swapToPrice input leg must price exactly its capped output leg");

        // Exact-output beyond reserves returns the same capped drain pair, not (0, 0).
        (uint256 ain2, uint256 aout2) = hook.swapToPrice(testPoolKey, true, int256(eff1 + 1e18), limit, "");
        assertEq(aout2, eff1, "exact-output beyond reserves returns the capped drain output");
        assertEq(ain2, ain, "exact-output drain pair matches the exact-input drain pair");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          YIELD ACCRUAL
    // ═══════════════════════════════════════════════════════════════════════════

    function test_yieldAccrual_increasesShareValue() public {
        _depositAsOperator(1_000e18);

        vault0.simulateYield(100e18);
        vault1.simulateYield(100e18);

        (uint256 amount0, uint256 amount1) = hook.previewWithdraw(testPoolKey, 1_000e18);
        // After yield: total = 1_100e18, supply = 1_000e18.
        // Withdraw rounds down: floor(1000e18 * (1100e18 + 1) / (1000e18 + 1e12)).
        uint256 expected = FixedPointMathLib.fullMulDiv(1_000e18, 1_100e18 + 1, 1_000e18 + 10 ** _OFFSET);
        assertEq(amount0, expected);
        assertEq(amount1, expected);
    }

    /// @dev Late entrants must not extract yield that accrued before they joined. Bob deposits
    ///      AFTER a yield event; he pays the post-yield (higher) share price; when he withdraws
    ///      at the same price he should break even (modulo wei-level integer rounding). Alice,
    ///      who deposited before the yield, captures her proportional share.
    function test_yield_lateEntrantBreaksEven() public {
        _depositAsOperator(1_000e18);
        vm.prank(owner);
        hook.setExternalDeposits(testPoolKey, true);

        // Alice deposits BEFORE yield (1:1 share price).
        _externalDeposit(testPoolKey, alice, 1_000e18);

        // Yield accrues — pool is now (2100, 2100) at supply 2000.
        vault0.simulateYield(100e18);
        vault1.simulateYield(100e18);

        // Bob deposits AFTER yield. The exact post-yield share price depends on alice's
        // deposit cost (which is itself diluted by the virtual offset and so isn't exactly
        // 1000e18); rather than rebuild the cascade, capture what the hook charges bob
        // and verify it exceeds the pre-yield 1:1 price.
        (uint256 bobPaid0, uint256 bobPaid1) = hook.previewDeposit(testPoolKey, 1_000e18);
        assertGt(bobPaid0, 1_000e18, "bob pays a higher share price post-yield");
        assertEq(bobPaid0, bobPaid1);
        _externalDeposit(testPoolKey, bob, 1_000e18);

        (uint256 aliceOut0, uint256 aliceOut1) = _exitAll(alice);
        (uint256 bobOut0, uint256 bobOut1) = _exitAll(bob);

        // Alice's slice of yield: 1000 / (1000 + 1000) = 50% → ~50e18 profit per side.
        // Tolerance = 2e12 wei reflects the cumulative virtual-offset dilution across four
        // deposit/withdraw cycles (alice in, bob in, alice out, bob out) at offset=12. The
        // share-of-yield ratio is exact; only the absolute wei drifts by the offset capture.
        assertGt(aliceOut0, 1_000e18, "alice profited on currency0");
        assertGt(aliceOut1, 1_000e18, "alice profited on currency1");
        assertApproxEqAbs(aliceOut0 - 1_000e18, 50e18, 2e12, "alice captured half of currency0 yield");
        assertApproxEqAbs(aliceOut1 - 1_000e18, 50e18, 2e12, "alice captured half of currency1 yield");

        // Bob breaks even within rounding: deposit rounds up, withdraw rounds down, plus
        // virtual-offset dilution. Tolerance widened from 10 wei to 2e12 wei to reflect the
        // offset=12 dilution scale.
        assertApproxEqAbs(bobOut0, bobPaid0, 2e12, "bob breaks even on currency0");
        assertApproxEqAbs(bobOut1, bobPaid1, 2e12, "bob breaks even on currency1");
    }

    /// @dev Three depositors enter at three different times, with yield accruing between each.
    ///      Each captures yield proportional to how long they were a shareholder during yield
    ///      events. With same share size for all three:
    ///        alice in -> yield Y1 -> bob in -> yield Y2 -> charlie in (no yield) -> all exit
    ///      Expected ordering: profit(alice) > profit(bob) > profit(charlie) ~ 0.
    function test_yield_proportionalToTimeOfDeposit() public {
        _depositAsOperator(1_000e18);
        vm.prank(owner);
        hook.setExternalDeposits(testPoolKey, true);

        // Alice in at 1:1.
        _externalDeposit(testPoolKey, alice, 1_000e18);

        // Yield Y1 — only alice + owner share it.
        vault0.simulateYield(100e18);
        vault1.simulateYield(100e18);

        // Bob in at the post-Y1 price.
        (uint256 bobPaid0,) = hook.previewDeposit(testPoolKey, 1_000e18);
        _externalDeposit(testPoolKey, bob, 1_000e18);

        // Yield Y2 — alice + bob + owner all share.
        vault0.simulateYield(100e18);
        vault1.simulateYield(100e18);

        // Charlie in at the post-Y2 price.
        (uint256 charliePaid0,) = hook.previewDeposit(testPoolKey, 1_000e18);
        _externalDeposit(testPoolKey, charlie, 1_000e18);

        // No further yield — charlie holds during zero yield events.

        (uint256 aliceOut0,) = _exitAll(alice);
        (uint256 bobOut0,) = _exitAll(bob);
        (uint256 charlieOut0,) = _exitAll(charlie);

        uint256 aliceProfit = aliceOut0 - 1_000e18;
        uint256 bobProfit = bobOut0 - bobPaid0;

        // Profits ordered by time-held during yield events: alice > bob > charlie ~ 0.
        assertApproxEqAbs(charlieOut0, charliePaid0, 10, "charlie breaks even (held no yield)");
        assertGt(aliceProfit, bobProfit, "alice (held longer) profits more than bob");
        assertGt(bobProfit, 10, "bob captured part of Y2");
        assertGt(aliceProfit, 50e18, "alice captured part of Y1 + Y2 (>=50e18 from Y1 alone)");
    }

    /// @dev Helper: `user` removes ALL their `testPoolKey` shares. Returns (currency0, currency1)
    ///      received this call. Advances one block to satisfy the same-block-withdraw guard so
    ///      callers can chain further deposits/withdrawals in the same test.
    function _exitAll(address user) internal returns (uint256 out0, uint256 out1) {
        uint256 shares = hook.userShares(testPoolId, user);
        uint256 t0Before = token0.balanceOf(user);
        uint256 t1Before = token1.balanceOf(user);
        vm.prank(user);
        hook.removeLiquidity(testPoolKey, shares, 0, 0, block.timestamp);
        vm.roll(block.number + 1);
        out0 = token0.balanceOf(user) - t0Before;
        out1 = token1.balanceOf(user) - t1Before;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                       CROSS-POOL ISOLATION
    // ═══════════════════════════════════════════════════════════════════════════
    //
    //  Two pools sharing currency0/currency1 must not contaminate each other.
    //  The test exercises the worst case: one pool vaulted, the other unvaulted —
    //  the unvaulted pool's tokens physically sit in the hook contract.

    function test_crossPool_swapDoesNotConsumeOtherPoolsUnvaultedERC20() public {
        // Bootstrap the primary (vaulted) pool — its tokens are in the vault, not the hook.
        _depositAsOperator(1_000e18);

        // A second unvaulted pool with 500e18 of each currency parked in the hook.
        (PoolKey memory keyB,) = _initSecondaryPool({vaulted: false, bootstrapAmount: 500e18});

        // Pool B's untracked-by-vault ERC-20 sits in the hook.
        assertEq(token0.balanceOf(address(hook)), 500e18);
        assertEq(token1.balanceOf(address(hook)), 500e18);
        (uint256 b0_before, uint256 b1_before) = hook.getReserves(keyB);
        assertEq(b0_before, 500e18);
        assertEq(b1_before, 500e18);

        // Swap on the primary pool. afterSwap → _depositAllToVaults must NOT sweep pool B's tokens.
        swap(testPoolKey, true, -10e18, "");

        (uint256 b0_after, uint256 b1_after) = hook.getReserves(keyB);
        assertEq(b0_after, 500e18, "Pool B currency0 untouched");
        assertEq(b1_after, 500e18, "Pool B currency1 untouched");
        assertEq(token0.balanceOf(address(hook)), 500e18, "Pool B's currency0 still in hook");
        assertEq(token1.balanceOf(address(hook)), 500e18, "Pool B's currency1 still in hook");
    }

    function test_crossPool_unvaultedPoolCanStillWithdrawAfterOtherPoolsSwap() public {
        _depositAsOperator(1_000e18);

        (PoolKey memory keyB, PoolId idB) = _initSecondaryPool({vaulted: false, bootstrapAmount: 500e18});

        // External LP into pool B.
        token0.mint(alice, 100e18);
        token1.mint(alice, 100e18);
        vm.startPrank(alice);
        token0.approve(address(hook), 100e18);
        token1.approve(address(hook), 100e18);
        hook.addLiquidity(keyB, 100e18, type(uint256).max, type(uint256).max, block.timestamp);
        vm.stopPrank();
        vm.roll(block.number + 1);

        // Swap on primary pool.
        swap(testPoolKey, true, -10e18, "");

        // Alice withdraws fully from pool B at proportional value.
        uint256 aliceShares = hook.userShares(idB, alice);
        assertEq(aliceShares, 100e18);
        uint256 t0_before = token0.balanceOf(alice);
        uint256 t1_before = token1.balanceOf(alice);
        vm.prank(alice);
        hook.removeLiquidity(keyB, aliceShares, 0, 0, block.timestamp);
        assertGt(token0.balanceOf(alice), t0_before);
        assertGt(token1.balanceOf(alice), t1_before);
    }

    /// @dev Worst-case interleaving: pool A is vaulted, pool B is unvaulted, both share
    ///      currency0 and currency1. Pool B's tokens physically sit in the hook contract
    ///      while pool A's are in the vault — the exact configuration where any global
    ///      `balanceOf` read in the hook would have leaked B's funds into A. This test
    ///      sequences ~12 deposits, swaps, yield events, and withdrawals across both
    ///      pools and asserts solvency after every state-changing op.
    function test_crossPool_interleavedOperations_oneVaultedOneUnvaulted() public {
        _depositAsOperator(1_000e18); // pool A (vaulted)
        (PoolKey memory keyB, PoolId idB) = _initSecondaryPool({vaulted: false, bootstrapAmount: 500e18});

        vm.prank(owner);
        hook.setExternalDeposits(testPoolKey, true);
        _assertCrossPoolSolvency(testPoolKey, keyB);
        // Hook holds only pool B's unvaulted tokens; pool A's are all in the vault.
        assertEq(token0.balanceOf(address(hook)), 500e18);
        assertEq(token1.balanceOf(address(hook)), 500e18);

        _externalDeposit(testPoolKey, alice, 200e18);
        _externalDeposit(keyB, bob, 100e18);
        _assertCrossPoolSolvency(testPoolKey, keyB);
        // Hook holds 500e18 (pool B's bootstrap, unvaulted) + bob's deposit charge.
        // Bob's deposit on B uses the virtual-offset formula: ceil(100e18 * (500e18+1) / (500e18+1e12)).
        uint256 bobPaid = FixedPointMathLib.fullMulDivUp(100e18, 500e18 + 1, 500e18 + 10 ** _OFFSET);
        assertEq(token0.balanceOf(address(hook)), 500e18 + bobPaid);
        assertEq(token1.balanceOf(address(hook)), 500e18 + bobPaid);

        // Each swap must leave the OTHER pool's reserves untouched.
        _swapAndAssertOtherPoolUnchanged(testPoolKey, keyB, true, -50e18);
        _swapAndAssertOtherPoolUnchanged(keyB, testPoolKey, false, -30e18);

        // Yield on the shared vault — pool B is unvaulted, so it must NOT bleed in.
        _accrueVaultYieldAndAssertOnlyPoolACaptures(keyB);

        // Mid-life: another deposit, then alice partially exits.
        _externalDeposit(testPoolKey, charlie, 100e18);
        _assertCrossPoolSolvency(testPoolKey, keyB);
        _partialExit(testPoolKey, alice, 2);
        _assertCrossPoolSolvency(testPoolKey, keyB);

        // Two swaps on B in opposite directions.
        swap(keyB, true, -10e18, "");
        swap(keyB, false, -10e18, "");
        _assertCrossPoolSolvency(testPoolKey, keyB);

        // Full exits.
        _fullExit(keyB, bob);
        _assertCrossPoolSolvency(testPoolKey, keyB);
        _fullExit(testPoolKey, charlie);
        _assertCrossPoolSolvency(testPoolKey, keyB);

        // One more swap on A, then alice exits her remainder.
        swap(testPoolKey, false, -25e18, "");
        _fullExit(testPoolKey, alice);
        _assertCrossPoolSolvency(testPoolKey, keyB);

        // After everyone except the owner has exited, total shares == owner shares
        // (no dead-share lock under virtual-offset inflation defense).
        assertEq(hook.totalShares(testPoolId), hook.userShares(testPoolId, owner), "pool A share supply matches owner");
        assertEq(hook.totalShares(idB), hook.userShares(idB, owner), "pool B share supply matches owner");
    }

    /// @dev Helper: swap on `subject`, assert `bystander`'s reserves are unchanged.
    function _swapAndAssertOtherPoolUnchanged(
        PoolKey memory subject,
        PoolKey memory bystander,
        bool zeroForOne,
        int256 amountSpecified
    ) internal {
        (uint256 b0_pre, uint256 b1_pre) = hook.getReserves(bystander);
        swap(subject, zeroForOne, amountSpecified, "");
        (uint256 b0_post, uint256 b1_post) = hook.getReserves(bystander);
        assertEq(b0_post, b0_pre, "bystander pool currency0 untouched");
        assertEq(b1_post, b1_pre, "bystander pool currency1 untouched");
        _assertCrossPoolSolvency(subject, bystander);
    }

    /// @dev Helper: accrue yield on the shared vault; assert pool A grew, unvaulted pool B didn't.
    function _accrueVaultYieldAndAssertOnlyPoolACaptures(PoolKey memory keyB) internal {
        (uint256 a0_pre, uint256 a1_pre) = hook.getReserves(testPoolKey);
        (uint256 b0_pre, uint256 b1_pre) = hook.getReserves(keyB);
        vault0.simulateYield(50e18);
        vault1.simulateYield(50e18);
        (uint256 a0_post, uint256 a1_post) = hook.getReserves(testPoolKey);
        (uint256 b0_post, uint256 b1_post) = hook.getReserves(keyB);
        assertGt(a0_post, a0_pre, "pool A captured currency0 yield");
        assertGt(a1_post, a1_pre, "pool A captured currency1 yield");
        assertEq(b0_post, b0_pre, "vault yield must not credit pool B");
        assertEq(b1_post, b1_pre, "vault yield must not credit pool B");
        _assertCrossPoolSolvency(testPoolKey, keyB);
    }

    /// @dev Helper: `user` removes `1/divisor` of their shares from `key`. Asserts both
    ///      tokens flowed back to the user.
    function _partialExit(PoolKey memory key, address user, uint256 divisor) internal {
        uint256 shares = hook.userShares(key.toId(), user);
        uint256 t0_before = token0.balanceOf(user);
        uint256 t1_before = token1.balanceOf(user);
        vm.prank(user);
        hook.removeLiquidity(key, shares / divisor, 0, 0, block.timestamp);
        vm.roll(block.number + 1);
        assertGt(token0.balanceOf(user), t0_before, "partial-exit returned currency0");
        assertGt(token1.balanceOf(user), t1_before, "partial-exit returned currency1");
    }

    /// @dev Helper: `user` removes ALL their shares from `key`. Asserts both tokens flowed back.
    function _fullExit(PoolKey memory key, address user) internal {
        uint256 shares = hook.userShares(key.toId(), user);
        uint256 t0_before = token0.balanceOf(user);
        uint256 t1_before = token1.balanceOf(user);
        vm.prank(user);
        hook.removeLiquidity(key, shares, 0, 0, block.timestamp);
        vm.roll(block.number + 1);
        assertGt(token0.balanceOf(user), t0_before, "full-exit returned currency0");
        assertGt(token1.balanceOf(user), t1_before, "full-exit returned currency1");
    }

    /// @dev Both pools share the SAME ERC4626 vault contracts. Tests that `_vaultShares`
    ///      isolation prevents one pool from redeeming another pool's vault stake even
    ///      though they sit in a single underlying ERC4626 supply.
    function test_crossPool_interleavedOperations_sharedVault() public {
        _depositAsOperator(1_000e18); // pool A (vaulted)
        (PoolKey memory keyB, PoolId idB) = _initSecondaryPool({vaulted: true, bootstrapAmount: 500e18});

        vm.prank(owner);
        hook.setExternalDeposits(testPoolKey, true);

        _assertCrossPoolSolvency(testPoolKey, keyB);
        // No raw ERC-20 in the hook — both pools' tokens are in the shared vault.
        assertEq(token0.balanceOf(address(hook)), 0);
        assertEq(token1.balanceOf(address(hook)), 0);

        // ─── Interleaved deposits + swaps ────────────────────────────────────────
        _externalDeposit(testPoolKey, alice, 300e18);
        _externalDeposit(keyB, bob, 200e18);
        swap(testPoolKey, true, -100e18, "");
        swap(keyB, false, -75e18, "");
        _assertCrossPoolSolvency(testPoolKey, keyB);

        // ─── Yield on shared vault — both pools must grow ────────────────────────
        _assertSharedVaultYieldDistributesToBothPools(keyB);
        _assertCrossPoolSolvency(testPoolKey, keyB);

        // ─── Alice exits A — must NOT eat into pool B's vault stake ──────────────
        _exitAndAssertNoCrossContamination(keyB);
        _assertCrossPoolSolvency(testPoolKey, keyB);

        // ─── Bob exits B fully — must succeed despite the shared vault ───────────
        vm.roll(block.number + 10);
        vm.warp(block.timestamp + 1);
        uint256 bobShares_B = hook.userShares(idB, bob);
        uint256 t0_bobBefore = token0.balanceOf(bob);
        uint256 t1_bobBefore = token1.balanceOf(bob);
        vm.prank(bob);
        hook.removeLiquidity(keyB, bobShares_B, 0, 0, block.timestamp);
        vm.roll(block.number + 1);
        assertGt(token0.balanceOf(bob), t0_bobBefore);
        assertGt(token1.balanceOf(bob), t1_bobBefore);
        _assertCrossPoolSolvency(testPoolKey, keyB);
    }

    /// @dev Helper extracted from the shared-vault test to keep the stack shallow:
    ///      simulate yield on the shared vault, assert both pools' reserves grew.
    function _assertSharedVaultYieldDistributesToBothPools(PoolKey memory keyB) internal {
        (uint256 a0_pre, uint256 a1_pre) = hook.getReserves(testPoolKey);
        (uint256 b0_pre, uint256 b1_pre) = hook.getReserves(keyB);
        vault0.simulateYield(100e18);
        vault1.simulateYield(100e18);
        (uint256 a0_post, uint256 a1_post) = hook.getReserves(testPoolKey);
        (uint256 b0_post, uint256 b1_post) = hook.getReserves(keyB);
        assertGt(a0_post, a0_pre, "pool A captured currency0 yield");
        assertGt(a1_post, a1_pre, "pool A captured currency1 yield");
        assertGt(b0_post, b0_pre, "pool B captured currency0 yield");
        assertGt(b1_post, b1_pre, "pool B captured currency1 yield");
    }

    /// @dev Helper: alice exits her pool A position; assert pool B's vault stake is intact.
    ///      Allows up to 1 wei downward rounding from `convertToAssets` integer division
    ///      after the vault's total supply/assets change — that's not contamination, just
    ///      ERC4626 share-price rounding noise.
    function _exitAndAssertNoCrossContamination(PoolKey memory keyB) internal {
        (uint256 b0_pre, uint256 b1_pre) = hook.getReserves(keyB);
        uint256 aliceShares = hook.userShares(testPoolId, alice);
        uint256 t0_aliceBefore = token0.balanceOf(alice);
        vm.prank(alice);
        hook.removeLiquidity(testPoolKey, aliceShares, 0, 0, block.timestamp);
        vm.roll(block.number + 1);
        assertGt(token0.balanceOf(alice), t0_aliceBefore, "alice received currency0");

        (uint256 b0_post, uint256 b1_post) = hook.getReserves(keyB);
        assertApproxEqAbs(b0_post, b0_pre, 1, "pool B currency0 reserves not materially eroded");
        assertApproxEqAbs(b1_post, b1_pre, 1, "pool B currency1 reserves not materially eroded");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                       TOKEN COMPATIBILITY
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Inbound transfers go through `SafeERC20.safeTransferFrom`; outbound through
    ///      `Currency.transfer`. Both tolerate USDT-style tokens that don't return a bool.
    ///      Routed through an unvaulted pool — vault implementations vary in their own
    ///      USDT compatibility (vault-selection concern, not the hook's).
    function test_supportsTokensWithNoReturnData_USDTLike() public {
        NoReturnToken usdt0 = new NoReturnToken();
        NoReturnToken usdt1 = new NoReturnToken();
        if (address(usdt0) > address(usdt1)) (usdt0, usdt1) = (usdt1, usdt0);

        PoolKey memory keyU = PoolKey({
            currency0: Currency.wrap(address(usdt0)),
            currency1: Currency.wrap(address(usdt1)),
            fee: FEE_PIPS,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });

        LiquidityBucket[] memory dist = new LiquidityBucket[](1);
        dist[0] = LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 10_000});
        DualPoolHook.PoolConfig memory cfg = DualPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            distribution: dist,
            allowExternalDeposits: false,
            vault0: IERC4626(address(0)),
            vault1: IERC4626(address(0)),
            minDepositBlocks: 0
        });

        vm.startPrank(owner);
        hook.initializePool(keyU, cfg);
        usdt0.mint(owner, 1000e18);
        usdt1.mint(owner, 1000e18);
        usdt0.approve(address(hook), 1000e18);
        usdt1.approve(address(hook), 1000e18);
        hook.bootstrap(keyU, 1000e18, 1000e18);
        vm.stopPrank();
        vm.roll(block.number + 1);

        uint256 ownerShares = hook.userShares(keyU.toId(), owner);
        uint256 t0Before = usdt0.balanceOf(owner);
        uint256 t1Before = usdt1.balanceOf(owner);
        vm.prank(owner);
        hook.removeLiquidity(keyU, ownerShares / 2, 0, 0, block.timestamp);
        assertGt(usdt0.balanceOf(owner), t0Before, "USDT-like currency0 returned");
        assertGt(usdt1.balanceOf(owner), t1Before, "USDT-like currency1 returned");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          VAULT OUTAGE
    // ═══════════════════════════════════════════════════════════════════════════
    //
    //  Pool uptime depends on vault uptime. When the vault rejects deposits or
    //  withdrawals, swaps and `removeLiquidity` revert. This is a documented
    //  operational tradeoff — the hook delegates to the vault and surfaces the
    //  failure cleanly rather than silently degrading.

    /// @dev When the vault is broken on *every* path (paused → reverts on previewRedeem,
    ///      convertToAssets, deposit, withdraw, ...), the swap fails at `_deployJIT`'s
    ///      effective-balance read in beforeSwap — long before the afterSwap deposit guard
    ///      could help. This test pins that behavior: a fully-paused vault is fatal because
    ///      sizing the JIT cycle requires reading vault state. The deposit-only failure
    ///      mode (cap reached, allocator rejection) is covered separately in
    ///      `test_swap_succeedsWhenVaultDepositCapped`.
    function test_vaultRevertOnEverything_swapFails() public {
        _depositAsOperator(1_000e18);

        PausableVault paused = new PausableVault();
        vm.etch(address(vault0), address(paused).code);
        PausableVault(address(vault0)).pause();

        // beforeSwap → _deployJIT → _effectiveAssets → vault.previewRedeem reverts → swap reverts.
        vm.expectRevert();
        swap(testPoolKey, true, -1e18, "");
    }

    /// @dev Regression for the deposit-cap bug. A real vault (Morpho VaultV2 with full
    ///      idle allocations, OZ ERC4626Cap at capacity, paused vault, etc.) reverts on
    ///      `deposit` once the cap is reached. Pre-fix, this bricked every swap on the pool
    ///      because `_afterSwap → _depositAllToVaults` propagated the revert. Post-fix the
    ///      try/catch keeps the swap live and parks the ERC-20 in `s.erc20` for retry.
    function test_swap_succeedsWhenVaultDepositCapped() public {
        // Use a dedicated pool with VaultV2-shaped mocks so we can arm the deposit shortfall.
        MockMorphoVaultV2 mv0 = new MockMorphoVaultV2(ERC20(address(token0)));
        MockMorphoVaultV2 mv1 = new MockMorphoVaultV2(ERC20(address(token1)));

        LiquidityBucket[] memory dist = new LiquidityBucket[](1);
        dist[0] = LiquidityBucket({tickLower: -60, tickUpper: 60, weightBps: 10_000});
        PoolKey memory mvKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: FEE_PIPS, tickSpacing: 60, hooks: IHooks(address(hook))
        });

        DualPoolHook.PoolConfig memory cfg = DualPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            distribution: dist,
            allowExternalDeposits: false,
            vault0: IERC4626(address(mv0)),
            vault1: IERC4626(address(mv1)),
            minDepositBlocks: 0
        });
        vm.prank(owner);
        hook.initializePool(mvKey, cfg);

        // Bootstrap; this initial deposit must succeed because shortfall isn't armed yet.
        token0.mint(owner, 1_000e18);
        token1.mint(owner, 1_000e18);
        vm.startPrank(owner);
        token0.approve(address(hook), 1_000e18);
        token1.approve(address(hook), 1_000e18);
        hook.bootstrap(mvKey, 1_000e18, 1_000e18);
        vm.stopPrank();
        vm.roll(block.number + 1);

        // Now arm both vaults to reject deposits. Subsequent swap's afterSwap re-deposit
        // will hit these reverts; the try/catch must keep the swap alive.
        mv0.setDepositShortfall(true);
        mv1.setDepositShortfall(true);

        // Swap. Pre-fix: vault.deposit revert bubbles up, swap reverts. Post-fix: swap completes.
        swap(mvKey, true, -1e18, "");

        // Sanity: reserves intact, pool still functional.
        (uint256 r0, uint256 r1) = hook.getReserves(mvKey);
        assertGt(r0 + r1, 0, "reserves intact after capped-vault swap");
    }

    function test_vaultRevertOnWithdraw_removeLiquidityFails() public {
        _depositAsOperator(1_000e18);

        PausableVault paused = new PausableVault();
        vm.etch(address(vault0), address(paused).code);
        PausableVault(address(vault0)).pause();

        uint256 ownerShares = hook.userShares(testPoolId, owner);
        vm.prank(owner);
        vm.expectRevert();
        hook.removeLiquidity(testPoolKey, ownerShares, 0, 0, block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                      REENTRANCY VIA VAULT
    // ═══════════════════════════════════════════════════════════════════════════
    //
    //  An owner-configured ERC4626 vault is an external dependency. If a malicious
    //  vault re-enters the hook from inside `vault.deposit` (called during JIT
    //  teardown), the JIT lock prevents the inner LP entry-point from succeeding.
    //
    //  `_depositAllToVault` wraps `vault.deposit` in try/catch (so a vault with a
    //  full `maxDeposit` cap doesn't brick swaps; see PoolVault), which means the
    //  inner revert is CAUGHT rather than bubbled up. The outer swap completes, the
    //  un-deposited ERC-20 stays in `s.erc20`, and a `VaultDepositSkipped` event
    //  surfaces the rejected reentry to operators. State is unchanged from the
    //  reentry attempt itself.

    function test_vaultReentryIntoAddLiquidity_caughtByDepositGuard() public {
        _depositAsOperator(1_000e18);
        vm.prank(owner);
        hook.setExternalDeposits(testPoolKey, true);

        ReentrantVault evil = new ReentrantVault();
        vm.etch(address(vault0), address(evil).code);
        ReentrantVault(address(vault0)).configure(address(hook), testPoolKey);

        uint256 sharesBefore = hook.totalShares(testPoolId);

        // Swap → afterSwap → vault.deposit → reentrant addLiquidity → JIT-lock revert
        // → CAUGHT by `_depositAllToVault` try/catch. Swap succeeds; no inner state change.
        swap(testPoolKey, true, -1e18, "");

        // Inner addLiquidity never minted shares, proving the JIT lock blocked the reentry.
        assertEq(hook.totalShares(testPoolId), sharesBefore, "no shares minted by reentry attempt");
    }

    function test_vaultReentryIntoSetDistribution_caughtByDepositGuard() public {
        _depositAsOperator(1_000e18);
        uint256 bucketsBefore = hook.getDistribution(testPoolId).length;

        ReentrantVault evil = new ReentrantVault();
        vm.etch(address(vault0), address(evil).code);
        ReentrantVault(address(vault0)).configureSetDistribution(address(hook), testPoolKey);

        // Same flow: inner setDistribution rejected by JIT lock, the revert is caught by the
        // deposit guard, outer swap completes without state corruption.
        swap(testPoolKey, true, -1e18, "");

        // Distribution unchanged; the reentry's attempted overwrite (would have shrunk to a
        // single bucket per ReentrantVault.configureSetDistribution) never landed.
        assertEq(hook.getDistribution(testPoolId).length, bucketsBefore, "distribution not overwritten by reentry");
    }

    /// @dev Closes the same-pool reentrancy variant: a malicious vault re-enters via
    ///      `manager.swap(samePool)` from inside `withdraw` (called during `_deployJIT`).
    ///      The inner `_beforeSwap` would otherwise corrupt the JIT lifecycle by clearing
    ///      the per-pool lock while the outer cycle is still in flight, orphaning LPs.
    function test_vaultReentryIntoSamePoolSwap_revertsJITInProgress() public {
        // Use a distinct pool key (different tickSpacing) so we can install the malicious
        // vault from the start; testPoolKey is already initialized in setUp() with a normal vault.
        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: FEE_PIPS, tickSpacing: 11, hooks: IHooks(address(hook))
        });
        LiquidityBucket[] memory dist = new LiquidityBucket[](1);
        dist[0] = LiquidityBucket({tickLower: -11, tickUpper: 11, weightBps: 10_000});

        SwapReentrantVault evilVault1 = new SwapReentrantVault();
        // Pre-configure so `initializePool`'s `vault.asset() == currency` check passes and the
        // malicious `withdraw` is wired to swap on this pool.
        evilVault1.configure(Currency.unwrap(currency1), address(manager), key);

        DualPoolHook.PoolConfig memory cfg = DualPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            distribution: dist,
            allowExternalDeposits: false,
            // currency0 = uncapped MockERC4626 (vault0 from setUp), currency1 = malicious.
            vault0: IERC4626(address(vault0)),
            vault1: IERC4626(address(evilVault1)),
            minDepositBlocks: 0
        });
        vm.prank(owner);
        hook.initializePool(key, cfg);

        // Bootstrap and step a block.
        token0.mint(owner, 1_000e18);
        token1.mint(owner, 1_000e18);
        vm.startPrank(owner);
        token0.approve(address(hook), 1_000e18);
        token1.approve(address(hook), 1_000e18);
        hook.bootstrap(key, 1_000e18, 1_000e18);
        vm.stopPrank();
        vm.roll(block.number + 1);

        // ZF1 swap drives `_withdrawFromVault(currency1)` -> evilVault1.withdraw -> reentrant
        // `manager.swap(key)` -> inner `_beforeSwap` reverts on `_isJITLocked`.
        vm.expectRevert();
        swap(key, true, -1e18, "");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                       LIVENESS
    // ═══════════════════════════════════════════════════════════════════════════
    //
    //  Pool fees are static (`PoolKey.fee`) and immutable post-init. Owner has only
    //  a per-pool liveness flag (`livePools`) for emergency pause/resume.

    /// @dev `initializePool` no longer flips the live flag -- it stays false until the
    ///      first `bootstrap`. This closes the post-init pre-bootstrap window in which a
    ///      swapper could shift slot0's price against zero JIT liquidity.
    function test_livePool_initializePool_leavesPoolNotLive() public view {
        assertFalse(hook.livePools(testPoolId));
    }

    /// @dev Bootstrap is the sole flip-to-live trigger. After init the pool is paused;
    ///      a successful first `bootstrap` enables swaps.
    function test_livePool_bootstrap_flipsLiveOn() public {
        assertFalse(hook.livePools(testPoolId), "pre-bootstrap: not live");
        _depositAsOperator(1_000e18);
        assertTrue(hook.livePools(testPoolId), "post-bootstrap: live");
    }

    function test_livePool_setPoolLiveFalse_clearsLiveFlag() public {
        vm.prank(owner);
        hook.setPoolLive(testPoolKey, false);
        assertFalse(hook.livePools(testPoolId));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_previewAddLiquidity_revertsBeforeBootstrap() public {
        // Fresh pool that hasn't been bootstrapped.
        (PoolKey memory key,) = _initSecondaryPool({vaulted: false, bootstrapAmount: 0});
        vm.expectRevert(VaultNotBootstrapped.selector);
        hook.previewDeposit(key, 500e18);
    }

    function test_previewAddLiquidity_proportionalAfterBootstrap() public {
        _depositAsOperator(1_000e18);
        (uint256 a0, uint256 a1) = hook.previewDeposit(testPoolKey, 500e18);
        // total0 = total1 = 1000e18, supply = 1000e18, virtual offset = 1e12.
        // Deposit rounds up: ceil(500e18 * (1000e18 + 1) / (1000e18 + 1e12)).
        uint256 expected = FixedPointMathLib.fullMulDivUp(500e18, 1000e18 + 1, 1000e18 + 10 ** _OFFSET);
        assertEq(a0, expected);
        assertEq(a1, expected);
    }

    function test_sharesOf() public {
        _depositAsOperator(1_000e18);
        assertEq(hook.sharesOf(testPoolKey, owner), 1_000e18);
        assertEq(hook.sharesOf(testPoolKey, alice), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                   QUOTE / EXECUTION FIDELITY
    // ═══════════════════════════════════════════════════════════════════════════
    //
    //  Validates `getIndicativeQuote` stays close to actual swap execution across
    //  multi-range distributions, both directions, exact-input vs exact-output, and
    //  after price movements. The deployed hook uses a compact current-liquidity
    //  quote, not the removed full virtual tick-walk simulator.

    function test_quoteFidelity_smallSwap_zeroForOne() public {
        _depositAsOperator(10_000e18);
        _useMultiBucketDistribution();
        _assertQuoteFidelity(true, -100e18);
    }

    function test_quoteFidelity_mediumSwap_zeroForOne() public {
        _depositAsOperator(10_000e18);
        _useMultiBucketDistribution();
        _assertQuoteFidelity(true, -3_000e18);
    }

    function test_quoteFidelity_largeSwap_zeroForOne() public {
        _depositAsOperator(10_000e18);
        _useMultiBucketDistribution();
        _assertQuoteFidelity(true, -8_000e18);
    }

    function test_quoteFidelity_veryLargeSwap_zeroForOne() public {
        _depositAsOperator(10_000e18);
        _useMultiBucketDistribution();
        _assertQuoteFidelity(true, -9_500e18);
    }

    function test_quoteFidelity_smallSwap_oneForZero() public {
        _depositAsOperator(10_000e18);
        _useMultiBucketDistribution();
        _assertQuoteFidelity(false, -100e18);
    }

    function test_quoteFidelity_mediumSwap_oneForZero() public {
        _depositAsOperator(10_000e18);
        _useMultiBucketDistribution();
        _assertQuoteFidelity(false, -3_000e18);
    }

    function test_quoteFidelity_exactOutput_zeroForOne() public {
        _depositAsOperator(10_000e18);
        _useMultiBucketDistribution();
        _assertQuoteFidelity(true, 100e18);
    }

    function test_quoteFidelity_exactOutput_oneForZero() public {
        _depositAsOperator(10_000e18);
        _useMultiBucketDistribution();
        _assertQuoteFidelity(false, 100e18);
    }

    /// @dev Asymmetric distribution: 50% in [-60,-10], 30% in [-10,10], 20% in [10,60].
    function test_quoteFidelity_asymmetricDistribution() public {
        _depositAsOperator(10_000e18);

        LiquidityBucket[] memory dist = new LiquidityBucket[](3);
        dist[0] = LiquidityBucket({tickLower: -60, tickUpper: -10, weightBps: 5000});
        dist[1] = LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 3000});
        dist[2] = LiquidityBucket({tickLower: 10, tickUpper: 60, weightBps: 2000});
        vm.prank(owner);
        hook.setDistribution(testPoolKey, dist);

        uint256 snap = vm.snapshotState();

        _assertQuoteFidelity(true, -100e18);
        vm.revertToState(snap);

        _assertQuoteFidelity(true, -3_000e18);
        vm.revertToState(snap);

        _assertQuoteFidelity(false, -100e18);
        vm.revertToState(snap);

        _assertQuoteFidelity(false, -3_000e18);
    }

    function test_quoteFidelity_afterPriceMovement() public {
        _depositAsOperator(10_000e18);
        _useMultiBucketDistribution();

        // Move price with a large zeroForOne swap.
        swap(testPoolKey, true, -5_000e18, "");
        (, int24 tickAfter,,) = manager.getSlot0(testPoolId);
        assertLt(tickAfter, -5, "price should have moved");

        uint256 snap = vm.snapshotState();
        _assertQuoteFidelity(true, -500e18);
        vm.revertToState(snap);
        _assertQuoteFidelity(false, -500e18);
    }

    /// @dev Single-bucket distribution — the simplest possible JIT shape.
    function test_quoteFidelity_singleBucket_zeroForOne() public {
        _depositAsOperator(10_000e18);
        // Default config is already a single bucket [-10, 10] @ 10_000 bps; no setDistribution.
        _assertQuoteFidelity(true, -100e18);
    }

    function test_quoteFidelity_singleBucket_oneForZero() public {
        _depositAsOperator(10_000e18);
        _assertQuoteFidelity(false, -100e18);
    }

    /// @dev Adjacent buckets sharing a tick boundary.
    function test_quoteFidelity_tickBoundary_sharedAtZero() public {
        _depositAsOperator(10_000e18);

        LiquidityBucket[] memory dist = new LiquidityBucket[](2);
        dist[0] = LiquidityBucket({tickLower: -10, tickUpper: 0, weightBps: 5000});
        dist[1] = LiquidityBucket({tickLower: 0, tickUpper: 10, weightBps: 5000});
        vm.prank(owner);
        hook.setDistribution(testPoolKey, dist);

        uint256 snap = vm.snapshotState();
        // Small swap (stays well inside the bucket): exercises base case.
        _assertQuoteFidelity(true, -100e18);
        vm.revertToState(snap);

        // Large swap that crosses the shared tick boundary at 0.
        _assertQuoteFidelity(true, -2_000e18);
        vm.revertToState(snap);

        _assertQuoteFidelity(false, -2_000e18);
    }

    /// @dev MAX_BUCKETS = 8 distribution. Exercises the upper bound on distribution
    ///      iteration and validates indicative quotes for a multi-bucket shape.
    function test_quoteFidelity_maxBuckets() public {
        _depositAsOperator(10_000e18);

        LiquidityBucket[] memory dist = new LiquidityBucket[](8);
        dist[0] = LiquidityBucket({tickLower: -80, tickUpper: -60, weightBps: 1250});
        dist[1] = LiquidityBucket({tickLower: -60, tickUpper: -40, weightBps: 1250});
        dist[2] = LiquidityBucket({tickLower: -40, tickUpper: -20, weightBps: 1250});
        dist[3] = LiquidityBucket({tickLower: -20, tickUpper: 0, weightBps: 1250});
        dist[4] = LiquidityBucket({tickLower: 0, tickUpper: 20, weightBps: 1250});
        dist[5] = LiquidityBucket({tickLower: 20, tickUpper: 40, weightBps: 1250});
        dist[6] = LiquidityBucket({tickLower: 40, tickUpper: 60, weightBps: 1250});
        dist[7] = LiquidityBucket({tickLower: 60, tickUpper: 80, weightBps: 1250});
        vm.prank(owner);
        hook.setDistribution(testPoolKey, dist);

        uint256 snap = vm.snapshotState();
        _assertQuoteFidelity(true, -100e18); // small, stays inside bucket [0, 20]
        vm.revertToState(snap);
        _assertQuoteFidelity(true, -3_000e18); // medium, crosses several boundaries
        vm.revertToState(snap);
        _assertQuoteFidelity(false, -100e18);
        vm.revertToState(snap);
        _assertQuoteFidelity(false, -3_000e18);
    }

    /// @dev Asymmetric-decimal pair (6-decimal USDC-like + 18-decimal WETH-like). The bootstrap
    ///      math (`sqrt(amount0 * amount1)`), `_convertToAmounts` (Solady `fullMulDiv`), and the
    ///      tick-schedule allocation are all unit-agnostic — verify they remain so under
    ///      realistic decimal asymmetry.
    function test_quoteFidelity_asymmetricDecimals() public {
        // Deploy USDC-like (6 decimals) and WETH-like (18 decimals); order by address so they
        // map to currency0/currency1 cleanly without fighting PoolKey ordering rules.
        MockERC20 stable = new MockERC20("USDC", "USDC", 6);
        MockERC20 weth = new MockERC20("WETH", "WETH", 18);

        (Currency c0, Currency c1, MockERC20 t0, MockERC20 t1) = address(stable) < address(weth)
            ? (Currency.wrap(address(stable)), Currency.wrap(address(weth)), stable, weth)
            : (Currency.wrap(address(weth)), Currency.wrap(address(stable)), weth, stable);

        MockERC4626 v0 = new MockERC4626(ERC20(address(t0)));
        MockERC4626 v1 = new MockERC4626(ERC20(address(t1)));

        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: FEE_PIPS, tickSpacing: 10, hooks: IHooks(address(hook))});

        LiquidityBucket[] memory dist = new LiquidityBucket[](1);
        dist[0] = LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 10_000});

        DualPoolHook.PoolConfig memory cfg = DualPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            distribution: dist,
            allowExternalDeposits: false,
            vault0: IERC4626(address(v0)),
            vault1: IERC4626(address(v1)),
            minDepositBlocks: 0
        });

        vm.prank(owner);
        hook.initializePool(key, cfg);

        // Bootstrap with realistic units, scaled above the BootstrapTooSmall floor
        // (`S >= 100 * 10**12 = 1e14`). 100k stable @ 1e6 = 1e11; 100 WETH @ 1e18 = 1e20;
        // sqrt(1e11 * 1e20) ≈ 3.16e15, comfortably above the 1e14 floor.
        uint256 amtStable = 100_000e6;
        uint256 amtWeth = 100e18;
        (uint256 amt0, uint256 amt1) = address(t0) == address(stable) ? (amtStable, amtWeth) : (amtWeth, amtStable);

        t0.mint(owner, amt0);
        t1.mint(owner, amt1);
        vm.startPrank(owner);
        t0.approve(address(hook), amt0);
        t1.approve(address(hook), amt1);
        hook.bootstrap(key, amt0, amt1);
        vm.stopPrank();
        vm.roll(block.number + 1);

        // Approve swap router for the new tokens (deployed by Deployers in setUp).
        t0.mint(address(this), 1e18);
        t1.mint(address(this), 1e18);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);

        // Direct fidelity assertion — `_assertQuoteFidelity` is hard-coded to `testPoolKey`,
        // so this test inlines the comparison for the asymmetric-decimal pool.
        // Use a tiny exact-input swap so the swap stays well inside the [-10, 10] bucket
        // regardless of which side has 6 vs 18 decimals.
        int256 amountSpecified = -1e6;
        uint256 quoted = hook.getIndicativeQuote(key, true, amountSpecified, "");
        assertGt(quoted, 0, "Quote should be non-zero for asymmetric-decimal pool");

        BalanceDelta delta = swap(key, true, amountSpecified, "");
        uint256 actual = uint256(int256(delta.amount1()));

        assertApproxEqAbs(quoted, actual, ABS_TOLERANCE, "asymmetric-decimal quote/exec mismatch");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                  QUOTE / SLIPPAGE / VALIDATION GUARDS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev For exact-output, `getIndicativeQuote` returns required INPUT, not output.
    function test_exactOutputQuote_returnsRequiredInput() public {
        _depositAsOperator(10_000e18);

        int256 amountSpecified = 100e18; // exact output
        uint256 quoted = hook.getIndicativeQuote(testPoolKey, true, amountSpecified, "");
        BalanceDelta delta = swap(testPoolKey, true, amountSpecified, "");

        uint256 actualInput = uint256(-int256(delta.amount0()));
        uint256 actualOutput = uint256(int256(delta.amount1()));

        assertApproxEqAbs(quoted, actualInput, ABS_TOLERANCE, "exact-output quote should equal input");
        assertGt(actualInput, actualOutput, "input should exceed output (fees + spread)");
    }

    /// @dev `getEffectiveLiquidity` sizes vault contribution via `maxWithdraw(hook)` (clamped to
    ///      the pool's share value); `getReserves` reports the gross `convertToAssets` value.
    ///      When the vault caps atomic withdrawals below the pool's stake, the two views
    ///      diverge -- `getEffectiveLiquidity` drops, `getReserves` does not. Routers and the
    ///      JIT cycle MUST plan against the smaller number to avoid mid-swap reverts.
    function test_effectiveLiquidity_reflectsMaxWithdrawCap() public {
        _depositAsOperator(10_000e18);

        // With healthy vault: effective == reserves.
        (uint256 r0, uint256 r1) = hook.getReserves(testPoolKey);
        (uint256 e0, uint256 e1) = hook.getEffectiveLiquidity(testPoolKey);
        assertEq(e0, r0, "healthy vault: effective0 == reserves0");
        assertEq(e1, r1, "healthy vault: effective1 == reserves1");

        // Mock the live vault0's maxWithdraw to report half the pool's stake as atomically
        // withdrawable, simulating a vault with most capital deployed. Reserves stay put (LP
        // economic stake is unchanged); effective drops to the cap.
        uint256 vaultShares = vault0.balanceOf(address(hook));
        vm.mockCall(
            address(vault0),
            abi.encodeWithSelector(IERC4626.maxWithdraw.selector, address(hook)),
            abi.encode(vaultShares / 2)
        );

        (uint256 r0_after,) = hook.getReserves(testPoolKey);
        (uint256 e0_after,) = hook.getEffectiveLiquidity(testPoolKey);
        assertEq(r0_after, r0, "reserves unaffected by maxWithdraw mock");
        assertLt(e0_after, r0, "effective drops to the maxWithdraw-capped value");
    }

    /// @dev `addLiquidity` reverts when actual amount exceeds `maxAmount{0,1}` bound.
    function test_addLiquidity_revertsOnSlippageExceeded() public {
        _depositAsOperator(1_000e18);
        vm.prank(owner);
        hook.setExternalDeposits(testPoolKey, true);

        (uint256 want0, uint256 want1) = hook.previewDeposit(testPoolKey, 100e18);
        token0.mint(alice, want0);
        token1.mint(alice, want1);
        vm.startPrank(alice);
        token0.approve(address(hook), want0);
        token1.approve(address(hook), want1);
        // Set max < actual required → revert.
        vm.expectRevert(DualPoolHook.SlippageExceeded.selector);
        hook.addLiquidity(testPoolKey, 100e18, want0 - 1, want1, block.timestamp);
        vm.stopPrank();
    }

    /// @dev `addLiquidity` reverts when `block.timestamp > deadline`.
    function test_addLiquidity_revertsOnDeadlineExpired() public {
        _depositAsOperator(1_000e18);
        vm.prank(owner);
        hook.setExternalDeposits(testPoolKey, true);

        token0.mint(alice, 100e18);
        token1.mint(alice, 100e18);
        vm.startPrank(alice);
        token0.approve(address(hook), 100e18);
        token1.approve(address(hook), 100e18);
        vm.expectRevert(DualPoolHook.DeadlineExpired.selector);
        hook.addLiquidity(testPoolKey, 100e18, type(uint256).max, type(uint256).max, block.timestamp - 1);
        vm.stopPrank();
    }

    /// @dev `removeLiquidity` reverts when actual amount falls below `minAmount{0,1}` bound.
    function test_removeLiquidity_revertsOnSlippageExceeded() public {
        _depositAsOperator(1_000e18);
        uint256 ownerShares = hook.sharesOf(testPoolKey, owner);
        (uint256 expect0, uint256 expect1) = hook.previewWithdraw(testPoolKey, ownerShares);

        vm.prank(owner);
        // Require strictly more than will be returned → revert.
        vm.expectRevert(DualPoolHook.SlippageExceeded.selector);
        hook.removeLiquidity(testPoolKey, ownerShares, expect0 + 1, expect1, block.timestamp);
    }

    /// @dev `initializePool` reverts if `vault.asset() != currency`.
    function test_initializePool_revertsOnVaultAssetMismatch() public {
        // Vault wrapping token1 paired with currency0 — mismatch.
        MockERC4626 wrongVault = new MockERC4626(ERC20(address(token1)));
        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: FEE_PIPS, tickSpacing: 60, hooks: IHooks(address(hook))
        });
        LiquidityBucket[] memory dist = new LiquidityBucket[](1);
        dist[0] = LiquidityBucket({tickLower: -60, tickUpper: 60, weightBps: 10_000});

        vm.prank(owner);
        vm.expectRevert(DualPoolHook.VaultAssetMismatch.selector);
        hook.initializePool(
            key,
            DualPoolHook.PoolConfig({
                sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
                distribution: dist,
                allowExternalDeposits: false,
                vault0: IERC4626(address(wrongVault)),
                vault1: IERC4626(address(vault1)),
                minDepositBlocks: 0
            })
        );
    }

    /// @dev `setDistribution` reverts when a tick is outside `[MIN_TICK, MAX_TICK]`.
    function test_setDistribution_revertsOnTickOutOfRange() public {
        // tickLower below MIN_TICK with valid spacing alignment.
        int24 belowMin = ((TickMath.MIN_TICK - 100) / 10) * 10; // aligned to tickSpacing 10
        LiquidityBucket[] memory bad = new LiquidityBucket[](1);
        bad[0] = LiquidityBucket({tickLower: belowMin, tickUpper: 10, weightBps: 10_000});
        vm.prank(owner);
        vm.expectRevert(bytes4(keccak256("InvalidTickRange()")));
        hook.setDistribution(testPoolKey, bad);

        // tickUpper above MAX_TICK.
        int24 aboveMax = ((TickMath.MAX_TICK + 100) / 10) * 10;
        LiquidityBucket[] memory bad2 = new LiquidityBucket[](1);
        bad2[0] = LiquidityBucket({tickLower: -10, tickUpper: aboveMax, weightBps: 10_000});
        vm.prank(owner);
        vm.expectRevert(bytes4(keccak256("InvalidTickRange()")));
        hook.setDistribution(testPoolKey, bad2);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//                                  MOCKS
// ═══════════════════════════════════════════════════════════════════════════════

/// @dev USDT-style ERC-20 — `transfer`, `transferFrom`, `approve` return nothing.
///      Standard `IERC20` callers fail to ABI-decode the empty returndata; SafeERC20
///      tolerates it.
contract NoReturnToken {
    string public name = "No Return USDT-like";
    string public symbol = "NRT";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
    }
}

/// @dev ERC4626-shaped vault that always reverts when paused. Used to simulate vault
///      outage scenarios (deposit/withdraw failures bricking the pool).
contract PausableVault {
    bool public paused;

    function pause() external {
        paused = true;
    }

    function deposit(uint256, address) external view returns (uint256) {
        if (paused) revert("vault paused");
        return 0;
    }

    function withdraw(uint256, address, address) external view returns (uint256) {
        if (paused) revert("vault paused");
        return 0;
    }

    function redeem(uint256, address, address) external view returns (uint256) {
        if (paused) revert("vault paused");
        return 0;
    }

    function maxWithdraw(address) external view returns (uint256) {
        if (paused) revert("vault paused");
        return 0;
    }

    function maxRedeem(address) external view returns (uint256) {
        if (paused) revert("vault paused");
        return 0;
    }

    function previewWithdraw(uint256) external view returns (uint256) {
        if (paused) revert("vault paused");
        return 0;
    }

    function convertToAssets(uint256) external view returns (uint256) {
        if (paused) revert("vault paused");
        return 0;
    }

    function previewRedeem(uint256) external view returns (uint256) {
        if (paused) revert("vault paused");
        return 0;
    }

    function previewDeposit(uint256) external view returns (uint256) {
        if (paused) revert("vault paused");
        return 0;
    }

    function convertToShares(uint256) external view returns (uint256) {
        if (paused) revert("vault paused");
        return 0;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }
}

/// @dev ERC4626-shaped vault that re-enters the hook from inside `deposit`. Configurable
///      to call `addLiquidity` or `setDistribution` for testing the JIT lock.
contract ReentrantVault {
    address public targetHook;
    PoolKey public targetKey;
    bytes4 public mode; // 0xaaaaaaaa = addLiquidity, 0xbbbbbbbb = setDistribution

    function configure(address hook, PoolKey calldata key) external {
        targetHook = hook;
        targetKey = key;
        mode = 0xaaaaaaaa;
    }

    function configureSetDistribution(address hook, PoolKey calldata key) external {
        targetHook = hook;
        targetKey = key;
        mode = 0xbbbbbbbb;
    }

    function deposit(uint256, address) external returns (uint256) {
        if (mode == 0xaaaaaaaa) {
            DualPoolHook(targetHook).addLiquidity(targetKey, 1, type(uint256).max, type(uint256).max, type(uint256).max);
        } else if (mode == 0xbbbbbbbb) {
            LiquidityBucket[] memory dist = new LiquidityBucket[](1);
            dist[0] = LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 10_000});
            DualPoolHook(targetHook).setDistribution(targetKey, dist);
        }
        return 0;
    }

    function withdraw(uint256, address, address) external pure returns (uint256) {
        return 0;
    }

    function redeem(uint256, address, address) external pure returns (uint256) {
        return 0;
    }

    function maxWithdraw(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function maxRedeem(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function previewWithdraw(uint256 a) external pure returns (uint256) {
        return a;
    }

    function previewRedeem(uint256 s) external pure returns (uint256) {
        return s;
    }

    function convertToAssets(uint256 s) external pure returns (uint256) {
        return s;
    }

    function convertToShares(uint256 a) external pure returns (uint256) {
        return a;
    }

    function previewDeposit(uint256 a) external pure returns (uint256) {
        return a;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }
}

/// @dev ERC-4626-like mock that reports a fixed `maxWithdraw` cap regardless of share balance.
///      Used to validate that `getEffectiveLiquidity` is bounded by `maxWithdraw` while
///      `getReserves` reports the full `convertToAssets` total.
contract CappedVault {
    ERC20 public asset;
    uint256 public cap;
    mapping(address => uint256) public balanceOf;

    constructor(ERC20 _asset, uint256 _cap) {
        asset = _asset;
        cap = _cap;
    }

    function setCap(uint256 _cap) external {
        cap = _cap;
    }

    function maxWithdraw(address) external view returns (uint256) {
        return cap;
    }

    function maxRedeem(address owner_) external view returns (uint256) {
        return balanceOf[owner_];
    }

    function convertToAssets(uint256 s) external pure returns (uint256) {
        return s;
    }

    function convertToShares(uint256 a) external pure returns (uint256) {
        return a;
    }

    function previewWithdraw(uint256 a) external pure returns (uint256) {
        return a;
    }

    function previewRedeem(uint256 s) external pure returns (uint256) {
        return s;
    }

    function deposit(uint256, address) external pure returns (uint256) {
        return 0;
    }

    function withdraw(uint256, address, address) external pure returns (uint256) {
        return 0;
    }

    function redeem(uint256, address, address) external pure returns (uint256) {
        return 0;
    }

    function previewDeposit(uint256 a) external pure returns (uint256) {
        return a;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }
}

/// @dev ERC-4626-shaped vault that re-enters the hook via `manager.swap(samePool)` from
///      inside `withdraw`. Validates that `_beforeSwap` rejects reentrant invocation on a
///      pool whose JIT cycle is already in flight.
contract SwapReentrantVault {
    address public asset;
    IPoolManager public manager;
    PoolKey public targetKey;

    function configure(address _asset, address _manager, PoolKey calldata _key) external {
        asset = _asset;
        manager = IPoolManager(_manager);
        targetKey = _key;
    }

    function deposit(uint256 assets, address) external returns (uint256) {
        // Pull underlying from the hook so the JIT cycle's `safeTransferFrom` settles, but
        // skip share bookkeeping -- the test only needs `withdraw` to re-enter.
        if (asset != address(0)) {
            (bool ok,) = asset.call(
                abi.encodeWithSignature("transferFrom(address,address,uint256)", msg.sender, address(this), assets)
            );
            require(ok, "transferFrom failed");
        }
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address) external returns (uint256) {
        // Re-enter on the same pool; PM dispatches to `hook._beforeSwap`, which should revert
        // because the outer JIT lock is still set.
        manager.swap(
            targetKey,
            SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ""
        );
        // Unreachable in the success-failure test; included so non-attacking flows work too.
        (bool ok,) = asset.call(abi.encodeWithSignature("transfer(address,uint256)", receiver, assets));
        require(ok, "transfer failed");
        return assets;
    }

    function maxWithdraw(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function convertToShares(uint256 a) external pure returns (uint256) {
        return a;
    }

    function convertToAssets(uint256 s) external pure returns (uint256) {
        return s;
    }

    function previewRedeem(uint256 s) external pure returns (uint256) {
        return s;
    }

    function previewDeposit(uint256 a) external pure returns (uint256) {
        return a;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }
}
