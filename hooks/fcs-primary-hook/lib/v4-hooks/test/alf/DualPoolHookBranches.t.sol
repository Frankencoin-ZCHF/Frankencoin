// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {DualPoolHook} from "../../src/alf/DualPoolHook.sol";
import {LiquidityBucket} from "../../src/alf/types/Distribution.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";
import {MockMorphoVaultV2} from "./mocks/MockMorphoVaultV2.sol";

/// @dev Token with no `decimals()` implementation at all: any call to it reverts, so
///      `PoolVault._tokenDecimals` must fall back to the assumed 18. Deliberately
///      empty: no functions, no fallback.
contract NoDecimalsToken {}

/// @notice Branch-coverage suite for `DualPoolHook` guard reverts and degenerate JIT-cycle
///         states that the main suite's happy paths never reach: wrong-hook init, the
///         no-vault admin no-ops, blocked external LP removal, zero-quote regimes, and a
///         swap over a pool whose effective balances are zero.
contract DualPoolHookBranchesTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    DualPoolHook hook;
    MockERC4626 vault0;
    MockERC4626 vault1;
    MockERC20 token0;
    MockERC20 token1;

    address owner = makeAddr("owner");

    PoolId poolId;

    uint256 constant BOOTSTRAP = 1e22;

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
        deployCodeTo("DualPoolHook", abi.encode(manager, uint32(100_000), owner, type(uint64).max), address(hook));

        key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 1_000, tickSpacing: 10, hooks: IHooks(address(hook))
        });
        poolId = key.toId();

        vm.prank(owner);
        hook.initializePool(key, _config(IERC4626(address(vault0)), IERC4626(address(vault1))));

        token0.mint(owner, BOOTSTRAP * 10);
        token1.mint(owner, BOOTSTRAP * 10);
        vm.startPrank(owner);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    function _config(IERC4626 v0, IERC4626 v1) internal pure returns (DualPoolHook.PoolConfig memory) {
        LiquidityBucket[] memory dist = new LiquidityBucket[](1);
        dist[0] = LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 10_000});
        return DualPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            distribution: dist,
            allowExternalDeposits: true,
            vault0: v0,
            vault1: v1,
            minDepositBlocks: 0
        });
    }

    function _bootstrap() internal {
        vm.prank(owner);
        hook.bootstrap(key, BOOTSTRAP, BOOTSTRAP);
    }

    // ══════════════════════════════════════════════════════════
    //  initializePool guards
    // ══════════════════════════════════════════════════════════

    function test_initializePool_revertsOnWrongHookAddress() public {
        PoolKey memory foreign = PoolKey({
            currency0: currency0, currency1: currency1, fee: 500, tickSpacing: 10, hooks: IHooks(address(0xBEEF))
        });
        vm.prank(owner);
        vm.expectRevert(DualPoolHook.InvalidHookAddress.selector);
        hook.initializePool(foreign, _config(IERC4626(address(0)), IERC4626(address(0))));
    }

    // ══════════════════════════════════════════════════════════
    //  refreshVaultApproval
    // ══════════════════════════════════════════════════════════

    function test_refreshVaultApproval_restoresMaxAllowance() public {
        // Simulate an unexpectedly consumed/reset allowance (USDT-style decrement).
        vm.prank(address(hook));
        token0.approve(address(vault0), 1);
        assertEq(token0.allowance(address(hook), address(vault0)), 1);

        vm.prank(owner);
        hook.refreshVaultApproval(key, currency0);
        assertEq(token0.allowance(address(hook), address(vault0)), type(uint256).max, "allowance re-armed to max");
    }

    function test_refreshVaultApproval_noVault_isNoOp() public {
        // A second pool holding both currencies as raw ERC-20 (no vaults).
        PoolKey memory rawKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 500, tickSpacing: 10, hooks: IHooks(address(hook))
        });
        vm.prank(owner);
        hook.initializePool(rawKey, _config(IERC4626(address(0)), IERC4626(address(0))));

        // No vault bound for the currency: the refresh returns without touching any allowance.
        vm.prank(owner);
        hook.refreshVaultApproval(rawKey, currency0);
    }

    // ══════════════════════════════════════════════════════════
    //  External LP removal blocked (mirror of the add-side test)
    // ══════════════════════════════════════════════════════════

    function test_externalLP_removeBlocked() public {
        _bootstrap();

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeRemoveLiquidity.selector,
                abi.encodeWithSelector(DualPoolHook.LiquidityNotAllowed.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -10, tickUpper: 10, liquidityDelta: -1e18, salt: 0}), ""
        );
    }

    // ══════════════════════════════════════════════════════════
    //  Indicative-quote zero regimes
    // ══════════════════════════════════════════════════════════

    function test_indicativeQuote_zeroAmount_returnsZero() public {
        _bootstrap();
        assertEq(hook.getIndicativeQuote(key, true, 0, ""), 0, "zero amount cannot be priced");
    }

    /// @dev When both effective balances read zero (here: vaults whose full exit value is
    ///      consumed by a 100% exit fee), the quote path must return 0 instead of pricing
    ///      liquidity the JIT cycle could never source.
    function test_indicativeQuote_zeroEffectiveBalances_returnsZero() public {
        MockMorphoVaultV2 vv0 = new MockMorphoVaultV2(ERC20(address(token0)));
        MockMorphoVaultV2 vv1 = new MockMorphoVaultV2(ERC20(address(token1)));
        PoolKey memory vvKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 500, tickSpacing: 10, hooks: IHooks(address(hook))
        });
        vm.prank(owner);
        hook.initializePool(vvKey, _config(IERC4626(address(vv0)), IERC4626(address(vv1))));
        vm.prank(owner);
        hook.bootstrap(vvKey, BOOTSTRAP, BOOTSTRAP);

        // Sanity: quotable while the vaults are healthy.
        assertGt(hook.getIndicativeQuote(vvKey, true, -1e18, ""), 0);

        // 100% exit fee: previewRedeem == 0 on both sides, so effective balances are zero.
        vv0.setExitFeeBps(10_000);
        vv1.setExitFeeBps(10_000);
        assertEq(hook.getIndicativeQuote(vvKey, true, -1e18, ""), 0, "unsourceable liquidity quotes zero");
    }

    /// @dev Same zero-effective-balance regime through the swap path: `_deployJIT` sizes
    ///      against zero and deploys nothing, so the swap crosses a zero-liquidity pool and
    ///      nets to zero rather than reverting the whole transaction.
    function test_swap_zeroEffectiveBalances_deploysNothingAndNetsToZero() public {
        MockMorphoVaultV2 vv0 = new MockMorphoVaultV2(ERC20(address(token0)));
        MockMorphoVaultV2 vv1 = new MockMorphoVaultV2(ERC20(address(token1)));
        PoolKey memory vvKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 500, tickSpacing: 10, hooks: IHooks(address(hook))
        });
        vm.prank(owner);
        hook.initializePool(vvKey, _config(IERC4626(address(vv0)), IERC4626(address(vv1))));
        vm.prank(owner);
        hook.bootstrap(vvKey, BOOTSTRAP, BOOTSTRAP);

        vv0.setExitFeeBps(10_000);
        vv1.setExitFeeBps(10_000);

        BalanceDelta delta = swap(vvKey, true, -1e18, "");
        assertEq(delta.amount0(), 0, "nothing consumed against zero deployed liquidity");
        assertEq(delta.amount1(), 0, "nothing delivered against zero deployed liquidity");
    }

    // ══════════════════════════════════════════════════════════
    //  Decimals fallback
    // ══════════════════════════════════════════════════════════

    /// @dev A token with no `decimals()` implementation falls back to the assumed 18, so a
    ///      pair of them derives the default offset of 12.
    function test_initializePool_noDecimalsToken_fallsBackTo18() public {
        address a = address(new NoDecimalsToken());
        address b = address(new NoDecimalsToken());
        if (a > b) (a, b) = (b, a);

        PoolKey memory ndKey = PoolKey({
            currency0: Currency.wrap(a),
            currency1: Currency.wrap(b),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });
        vm.prank(owner);
        hook.initializePool(ndKey, _config(IERC4626(address(0)), IERC4626(address(0))));

        assertEq(hook.decimalsOffset(ndKey.toId()), 12, "18/18 fallback maps to the default offset");
    }

    // ══════════════════════════════════════════════════════════
    //  emergencyRevokeVault on an unvaulted pool
    // ══════════════════════════════════════════════════════════

    /// @dev With no vault bound there is no allowance to zero and no position to drain: the
    ///      emergency action still pauses the pool and closes the deposit gate, and the drain
    ///      leg is a silent no-op (no VaultDrained/VaultDrainSkipped events).
    function test_emergencyRevokeVault_unvaultedPool_pausesWithoutDrainEvents() public {
        PoolKey memory rawKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 500, tickSpacing: 10, hooks: IHooks(address(hook))
        });
        PoolId rawId = rawKey.toId();
        vm.prank(owner);
        hook.initializePool(rawKey, _config(IERC4626(address(0)), IERC4626(address(0))));
        vm.prank(owner);
        hook.bootstrap(rawKey, BOOTSTRAP, BOOTSTRAP);
        assertTrue(hook.livePools(rawId));

        vm.recordLogs();
        vm.prank(owner);
        hook.emergencyRevokeVault(rawKey);

        assertFalse(hook.livePools(rawId), "pool paused");
        assertFalse(hook.externalDepositsEnabled(rawId), "deposit gate closed");
        // Liveness + gate + EmergencyVaultRevoked events only; no drain events for a pool
        // with nothing in a vault.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 drained = keccak256("VaultDrained(bytes32,address,uint256,uint256)");
        bytes32 drainSkipped = keccak256("VaultDrainSkipped(bytes32,address,uint256,bytes)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != drained, "no VaultDrained");
            assertTrue(logs[i].topics[0] != drainSkipped, "no VaultDrainSkipped");
        }
    }
}
