// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, stdError} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {
    VaultAlreadyBootstrapped,
    InsufficientBootstrap,
    BootstrapTooSmall,
    VaultNotBootstrapped,
    InsufficientShares,
    DepositLocked
} from "../../src/alf/types/Shares.sol";
import {PoolVault} from "../../src/alf/base/PoolVault.sol";
import {InventoryLib} from "../../src/alf/libraries/InventoryLib.sol";
import {InsufficientPoolBalance} from "../../src/alf/types/Inventory.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";
import {MockMorphoVaultV2} from "./mocks/MockMorphoVaultV2.sol";
import {MockSparkVault} from "./mocks/MockSparkVault.sol";

/// @dev Concrete test harness that exposes PoolVault's internal functions as external calls.
contract MockPoolVault is PoolVault {
    using PoolIdLibrary for PoolKey;

    IPoolManager private _pm;

    constructor(IPoolManager pm) {
        _pm = pm;
    }

    function _poolManager() internal view override returns (IPoolManager) {
        return _pm;
    }

    function bootstrap(PoolKey calldata key, address from, address to, uint256 amount0, uint256 amount1)
        external
        returns (uint256 shares)
    {
        return _bootstrap(key, from, to, amount0, amount1);
    }

    function deposit(PoolKey calldata key, address from, address to, uint256 shares)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        return _deposit(key, from, to, shares);
    }

    function withdraw(PoolKey calldata key, address from, address to, uint256 shares)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        return _withdraw(key, from, to, shares);
    }

    function depositToVault(PoolId poolId, Currency currency, uint256 amount) external {
        _depositToVault(poolId, currency, amount);
    }

    function depositAllToVault(PoolId poolId, Currency currency) external {
        _depositAllToVault(poolId, currency);
    }

    function ensureERC20(PoolId poolId, Currency currency, uint256 amount) external {
        _ensureERC20(poolId, currency, amount);
    }

    function recordClaims(PoolId poolId, Currency currency, uint256 amount) external {
        _recordClaims(poolId, currency, amount);
    }

    function setVault(PoolId poolId, Currency currency, IERC4626 vault) external {
        _setVault(poolId, currency, vault);
        // Mirror production's init-time approval so hot-path deposits don't need a
        // runtime allowance read.
        _approveVault(currency, address(vault));
    }

    function setMinDepositBlocks(PoolId poolId, uint64 blocks) external {
        minDepositBlocks[poolId] = blocks;
    }

    function withdrawFromVault(PoolId poolId, Currency currency, uint256 amount) external {
        _withdrawFromVault(poolId, currency, amount);
    }

    function drainVaultBestEffort(PoolId poolId, Currency currency) external {
        _drainVaultBestEffort(poolId, currency);
    }

    function debitPoolERC20(PoolId poolId, Currency currency, uint256 amount) external {
        _debitPoolERC20(poolId, currency, amount);
    }

    function getVaultShares(PoolId poolId, Currency currency) external view returns (uint256) {
        return _vaultSharesOf(poolId, currency);
    }

    function getClaims(PoolId poolId, Currency currency) external view returns (uint256) {
        return _claimsOf(poolId, currency);
    }

    function getERC20(PoolId poolId, Currency currency) external view returns (uint256) {
        return _erc20Of(poolId, currency);
    }

    function effectiveBalance(PoolId poolId, Currency currency) external view returns (uint256) {
        return _inventory.effectiveBalance(_partition(poolId, currency));
    }
}

contract PoolVaultTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    MockPoolVault public vault;
    MockERC4626 public vault0;
    MockERC4626 public vault1;

    MockERC20 token0;
    MockERC20 token1;

    PoolKey poolKeyA; // vaulted
    PoolId poolIdA;

    PoolKey poolKeyB; // unvaulted (same currencies)
    PoolId poolIdB;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    /// @dev Mirror of `PoolVault._decimalsOffset()` so test expectations can be computed
    ///      with the same formula the contract uses.
    uint8 internal constant _OFFSET = 12;

    function setUp() public {
        deployFreshManagerAndRouters();

        token0 = new MockERC20("Token0", "T0", 18);
        token1 = new MockERC20("Token1", "T1", 18);
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        vault0 = new MockERC4626(ERC20(address(token0)));
        vault1 = new MockERC4626(ERC20(address(token1)));

        vault = new MockPoolVault(manager);

        poolKeyA = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });
        poolIdA = poolKeyA.toId();

        poolKeyB = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        poolIdB = poolKeyB.toId();

        vault.setVault(poolIdA, poolKeyA.currency0, IERC4626(address(vault0)));
        vault.setVault(poolIdA, poolKeyA.currency1, IERC4626(address(vault1)));
    }

    // ══════════════════════════════════════════════════════════
    //  Helpers
    // ══════════════════════════════════════════════════════════

    /// @dev Bootstrap pool A with `(amount, amount)` from `user`. Returns total shares.
    function _bootstrap(address user, uint256 amount) internal returns (uint256 shares) {
        token0.mint(user, amount);
        token1.mint(user, amount);
        vm.startPrank(user);
        token0.approve(address(vault), amount);
        token1.approve(address(vault), amount);
        shares = vault.bootstrap(poolKeyA, user, user, amount, amount);
        vm.stopPrank();
        vm.roll(block.number + 1); // skip same-block-withdraw guard for tests
    }

    function _bootstrapPool(PoolKey memory key, address user, uint256 amount) internal returns (uint256 shares) {
        token0.mint(user, amount);
        token1.mint(user, amount);
        vm.startPrank(user);
        token0.approve(address(vault), amount);
        token1.approve(address(vault), amount);
        shares = vault.bootstrap(key, user, user, amount, amount);
        vm.stopPrank();
        vm.roll(block.number + 1);
    }

    /// @dev Mint, approve, and deposit `shares` worth into pool A as `user`.
    function _depositA(address user, uint256 shares) internal returns (uint256 a0, uint256 a1) {
        (uint256 need0, uint256 need1) = vault.previewDeposit(poolKeyA, shares);
        token0.mint(user, need0);
        token1.mint(user, need1);
        vm.startPrank(user);
        token0.approve(address(vault), need0);
        token1.approve(address(vault), need1);
        (a0, a1) = vault.deposit(poolKeyA, user, user, shares);
        vm.stopPrank();
        vm.roll(block.number + 1);
    }

    // ══════════════════════════════════════════════════════════
    //  Bootstrap
    // ══════════════════════════════════════════════════════════

    function test_bootstrap_mintsSqrtSharesToBootstrapper() public {
        uint256 shares = _bootstrap(alice, 1000e18);

        // sqrt(1000e18 * 1000e18) = 1000e18, all credited to alice. No address(0) lock --
        // inflation defense is virtual-shares offsets in `_convertToAmounts` (see PoolVault).
        assertEq(shares, 1000e18, "shares = sqrt(a0 * a1)");
        assertEq(vault.totalShares(poolIdA), 1000e18);
        assertEq(vault.userShares(poolIdA, alice), 1000e18, "alice gets the full bootstrap mint");
        assertEq(vault.userShares(poolIdA, address(0)), 0, "no dead-share lock");
    }

    function test_bootstrap_revertsWhenAlreadyBootstrapped() public {
        _bootstrap(alice, 1000e18);

        token0.mint(bob, 1e18);
        token1.mint(bob, 1e18);
        vm.startPrank(bob);
        token0.approve(address(vault), 1e18);
        token1.approve(address(vault), 1e18);
        vm.expectRevert(VaultAlreadyBootstrapped.selector);
        vault.bootstrap(poolKeyA, bob, bob, 1e18, 1e18);
        vm.stopPrank();
    }

    function test_bootstrap_revertsOnZeroAmounts() public {
        token0.mint(alice, 100);
        token1.mint(alice, 100);
        vm.startPrank(alice);
        token0.approve(address(vault), 100);
        token1.approve(address(vault), 100);

        vm.expectRevert(InsufficientBootstrap.selector);
        vault.bootstrap(poolKeyA, alice, alice, 0, 100);

        vm.expectRevert(InsufficientBootstrap.selector);
        vault.bootstrap(poolKeyA, alice, alice, 100, 0);
        vm.stopPrank();
    }

    function test_bootstrap_revertsBelowVirtualSharesFloor() public {
        // Tiny bootstraps that produce shares below `100 * 10**_decimalsOffset()`
        // permanently dilute the bootstrapper into the virtual position. The runtime check
        // rejects them with `BootstrapTooSmall` so operators can't accidentally lose
        // their seed capital.
        //
        // With default offset = 12, the floor is `100 * 1e12 = 1e14` shares. A `(1, 1)`
        // bootstrap produces `sqrt(1) = 1` share — well below the floor.
        token0.mint(alice, 1);
        token1.mint(alice, 1);
        vm.startPrank(alice);
        token0.approve(address(vault), 1);
        token1.approve(address(vault), 1);
        vm.expectRevert(abi.encodeWithSelector(BootstrapTooSmall.selector, 1, 1e14));
        vault.bootstrap(poolKeyA, alice, alice, 1, 1);
        vm.stopPrank();
    }

    function test_addLiquidity_revertsIfNotBootstrapped() public {
        vm.expectRevert(VaultNotBootstrapped.selector);
        vault.deposit(poolKeyA, alice, alice, 100e18);
    }

    function test_previewDeposit_revertsIfNotBootstrapped() public {
        vm.expectRevert(VaultNotBootstrapped.selector);
        vault.previewDeposit(poolKeyA, 100e18);
    }

    // ══════════════════════════════════════════════════════════
    //  Subsequent deposit (post-bootstrap)
    // ══════════════════════════════════════════════════════════

    function test_subsequentDeposit_proportional() public {
        _bootstrap(alice, 1000e18);

        (uint256 a0, uint256 a1) = _depositA(bob, 500e18);

        // After bootstrap: total0 = total1 = 1000e18, supply = 1000e18.
        // Deposit rounds UP per `_convertToAmounts(roundUp=true)`:
        //   ceil(500e18 * (1000e18 + 1) / (1000e18 + 10**_decimalsOffset()))
        // The +1 virtual asset and +10^offset virtual shares are the EIP-4626 inflation
        // defense; they bias every conversion by ~1 ppb at the default offset of 12.
        uint256 expected = FixedPointMathLib.fullMulDivUp(500e18, 1000e18 + 1, 1000e18 + 10 ** _OFFSET);
        assertEq(a0, expected);
        assertEq(a1, expected);
        assertEq(vault.userShares(poolIdA, bob), 500e18);
        assertEq(vault.totalShares(poolIdA), 1500e18);
    }

    function test_previewDeposit_roundsUp() public {
        _bootstrap(alice, 3e18);

        // Yield creates a non-trivial ratio so rounding matters.
        vault0.simulateYield(1);
        vault1.simulateYield(1);

        (uint256 up0, uint256 up1) = vault.previewDeposit(poolKeyA, 1e18);
        (uint256 down0, uint256 down1) = vault.previewWithdraw(poolKeyA, 1e18);

        assertGe(up0, down0, "deposit rounds up vs withdraw");
        assertGe(up1, down1);
    }

    // ══════════════════════════════════════════════════════════
    //  Withdraw
    // ══════════════════════════════════════════════════════════

    function test_withdraw_burnsSharesSendsTokens() public {
        _bootstrap(alice, 1000e18);

        uint256 aliceShares = vault.userShares(poolIdA, alice);
        uint256 bal0Before = token0.balanceOf(bob);
        uint256 bal1Before = token1.balanceOf(bob);

        // Alice withdraws half, sends to Bob.
        uint256 burnShares = aliceShares / 2;
        (uint256 a0, uint256 a1) = vault.withdraw(poolKeyA, alice, bob, burnShares);

        // No dead-share lock; aliceShares == 1000e18. Withdraw rounds DOWN:
        //   floor(500e18 * (1000e18 + 1) / (1000e18 + 10**_decimalsOffset()))
        uint256 expected = FixedPointMathLib.fullMulDiv(burnShares, 1000e18 + 1, 1000e18 + 10 ** _OFFSET);
        assertEq(a0, expected);
        assertEq(a1, expected);
        assertEq(vault.userShares(poolIdA, alice), aliceShares - burnShares);
        assertEq(token0.balanceOf(bob) - bal0Before, a0);
        assertEq(token1.balanceOf(bob) - bal1Before, a1);
    }

    function test_withdraw_revertsInsufficientShares() public {
        _bootstrap(alice, 1000e18);
        uint256 aliceShares = vault.userShares(poolIdA, alice);

        vm.expectRevert(InsufficientShares.selector);
        vault.withdraw(poolKeyA, alice, alice, aliceShares + 1);
    }

    function test_withdraw_revertsBeforeUnlockBlock() public {
        // Configure a non-trivial 5-block lock so the test covers the general case, not just
        // the same-block-ban degenerate.
        vault.setMinDepositBlocks(poolIdA, 5);
        _bootstrap(alice, 1000e18);

        // Bob deposits subsequent shares, attempts withdraw before the unlock block.
        (uint256 need0, uint256 need1) = vault.previewDeposit(poolKeyA, 100e18);
        token0.mint(bob, need0);
        token1.mint(bob, need1);
        vm.startPrank(bob);
        token0.approve(address(vault), need0);
        token1.approve(address(vault), need1);
        vault.deposit(poolKeyA, bob, bob, 100e18);
        uint256 unlockBlock = block.number + 5;
        // Roll just below the unlock block.
        vm.roll(unlockBlock - 1);
        vm.expectRevert(abi.encodeWithSelector(DepositLocked.selector, unlockBlock));
        vault.withdraw(poolKeyA, bob, bob, 100e18);
        vm.stopPrank();
    }

    function test_withdraw_succeedsAtUnlockBlock() public {
        vault.setMinDepositBlocks(poolIdA, 5);
        _bootstrap(alice, 1000e18);

        (uint256 need0, uint256 need1) = vault.previewDeposit(poolKeyA, 100e18);
        token0.mint(bob, need0);
        token1.mint(bob, need1);
        vm.startPrank(bob);
        token0.approve(address(vault), need0);
        token1.approve(address(vault), need1);
        vault.deposit(poolKeyA, bob, bob, 100e18);
        vm.stopPrank();
        // Roll exactly to the unlock block; lock should clear.
        vm.roll(block.number + 5);
        vault.withdraw(poolKeyA, bob, bob, 100e18);
    }

    /// @notice Regression: `minDepositBlocks: 0` permits same-block withdraw. This is a
    ///         deliberate semantic change from the legacy unconditional same-block ban; the
    ///         test locks the new semantics into CI so anyone tightening the default in the
    ///         future is forced to update it.
    function test_withdraw_succeedsWhenMinDepositBlocksIsZero() public {
        // Default minDepositBlocks for poolIdA is 0 (no setter call). Bootstrap and immediately
        // withdraw in the same block.
        token0.mint(alice, 1000e18);
        token1.mint(alice, 1000e18);
        vm.startPrank(alice);
        token0.approve(address(vault), 1000e18);
        token1.approve(address(vault), 1000e18);
        vault.bootstrap(poolKeyA, alice, alice, 1000e18, 1000e18);
        // No vm.roll -- same block as the deposit. The lock-of-zero permits this.
        vault.withdraw(poolKeyA, alice, alice, 500e18);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════
    //  totalAssets
    // ══════════════════════════════════════════════════════════

    function test_totalAssets_includesAllSources() public {
        _bootstrap(alice, 1000e18);

        (uint256 a0, uint256 a1) = vault.totalAssets(poolKeyA);
        assertEq(a0, 1000e18);
        assertEq(a1, 1000e18);

        // Add claims (per-pool record)
        vault.recordClaims(poolIdA, poolKeyA.currency0, 50e18);
        (a0,) = vault.totalAssets(poolKeyA);
        assertEq(a0, 1050e18);

        // Vault yield
        vault0.simulateYield(100e18);
        (a0,) = vault.totalAssets(poolKeyA);
        assertEq(a0, 1150e18);
    }

    function test_totalAssets_unvaultedPool_usesERC20() public {
        _bootstrapPool(poolKeyB, alice, 500e18);

        (uint256 a0, uint256 a1) = vault.totalAssets(poolKeyB);
        assertEq(a0, 500e18);
        assertEq(a1, 500e18);
    }

    // ══════════════════════════════════════════════════════════
    //  CROSS-POOL ISOLATION
    // ══════════════════════════════════════════════════════════

    /// @notice Confirms a swap-cycle's `_depositAllToVault` on Pool A does not sweep Pool B's
    ///         unvaulted ERC-20.
    function test_depositAllToVault_doesNotSweepOtherPoolsERC20() public {
        // Pool B (unvaulted) holds 500 of token0
        _bootstrapPool(poolKeyB, bob, 500e18);
        assertEq(vault.getERC20(poolIdB, poolKeyB.currency0), 500e18);
        assertEq(token0.balanceOf(address(vault)), 500e18);

        // Bootstrap pool A (vaulted) — its tokens go to vault0, not the hook ERC-20 balance.
        _bootstrap(alice, 1000e18);
        // Hook still holds Pool B's 500e18 of token0
        assertEq(token0.balanceOf(address(vault)), 500e18);

        // Trigger pool A's `_depositAllToVault` for currency0.
        // It reads `_erc20[A][token0] == 0` and is a no-op.
        uint256 aSharesBefore = vault.getVaultShares(poolIdA, poolKeyA.currency0);
        vault.depositAllToVault(poolIdA, poolKeyA.currency0);
        uint256 aSharesAfter = vault.getVaultShares(poolIdA, poolKeyA.currency0);

        assertEq(aSharesAfter, aSharesBefore, "Pool A should not have swept Pool B's tokens");
        assertEq(vault.getERC20(poolIdB, poolKeyB.currency0), 500e18, "Pool B's ledger intact");
        assertEq(token0.balanceOf(address(vault)), 500e18, "Pool B's tokens still in hook");
    }

    /// @notice Confirms `_ensureERC20` does not short-circuit using another pool's ERC-20.
    function test_ensureERC20_doesNotConsumeOtherPoolsERC20() public {
        _bootstrap(alice, 1000e18); // vaulted, _erc20[A] = 0
        _bootstrapPool(poolKeyB, bob, 500e18); // unvaulted, _erc20[B] = 500

        // Pool A needs 100 — should redeem from vault A, not consume pool B's 500e18.
        // It sees `_erc20[A] == 0`, so it redeems 100 from vault A.
        uint256 aVaultSharesBefore = vault.getVaultShares(poolIdA, poolKeyA.currency0);
        vault.ensureERC20(poolIdA, poolKeyA.currency0, 100e18);
        uint256 aVaultSharesAfter = vault.getVaultShares(poolIdA, poolKeyA.currency0);

        assertLt(aVaultSharesAfter, aVaultSharesBefore, "vault redemption MUST occur");
        assertEq(vault.getERC20(poolIdB, poolKeyB.currency0), 500e18, "Pool B unaffected");
    }

    function test_assetSolvency_acrossTwoPoolsSharingCurrency() public {
        _bootstrap(alice, 1000e18);
        _bootstrapPool(poolKeyB, bob, 500e18);

        // Each pool's totalAssets matches its own deposit, regardless of the global token balance.
        (uint256 a0, uint256 a1) = vault.totalAssets(poolKeyA);
        (uint256 b0, uint256 b1) = vault.totalAssets(poolKeyB);

        assertEq(a0, 1000e18, "Pool A asset0 = its own bootstrap");
        assertEq(a1, 1000e18);
        assertEq(b0, 500e18, "Pool B asset0 = its own bootstrap");
        assertEq(b1, 500e18);

        // Sum of per-pool asset claims for each currency does NOT exceed available backing.
        uint256 sum0 = a0 + b0;
        uint256 sum1 = a1 + b1;
        uint256 backing0 = token0.balanceOf(address(vault)) + vault0.convertToAssets(vault0.balanceOf(address(vault)));
        uint256 backing1 = token1.balanceOf(address(vault)) + vault1.convertToAssets(vault1.balanceOf(address(vault)));
        assertLe(sum0, backing0, "asset solvency, currency0");
        assertLe(sum1, backing1, "asset solvency, currency1");
    }

    // ══════════════════════════════════════════════════════════
    //  Vault routing
    // ══════════════════════════════════════════════════════════

    function test_deposit_routesToVault_whenConfigured() public {
        _bootstrap(alice, 1000e18);
        assertEq(token0.balanceOf(address(vault)), 0, "no raw ERC-20 when vaulted");
        assertGt(vault.getVaultShares(poolIdA, poolKeyA.currency0), 0);
    }

    function test_deposit_tracksERC20_whenNoVault() public {
        _bootstrapPool(poolKeyB, alice, 1000e18);
        assertEq(vault.getERC20(poolIdB, poolKeyB.currency0), 1000e18);
        assertEq(vault.getVaultShares(poolIdB, poolKeyB.currency0), 0);
    }

    // ══════════════════════════════════════════════════════════
    //  Multi-pool independence
    // ══════════════════════════════════════════════════════════

    function test_multiPool_sharesIsolated() public {
        // Alice in pool A, Bob in pool B.
        _bootstrap(alice, 1000e18);
        _bootstrapPool(poolKeyB, bob, 500e18);

        assertEq(vault.totalShares(poolIdA), 1000e18);
        assertEq(vault.totalShares(poolIdB), 500e18);
        assertEq(vault.userShares(poolIdA, alice), 1000e18);
        assertEq(vault.userShares(poolIdB, bob), 500e18);
        assertEq(vault.userShares(poolIdA, bob), 0);
        assertEq(vault.userShares(poolIdB, alice), 0);
    }

    function test_recordClaims_perPoolIsolation() public {
        vault.recordClaims(poolIdA, poolKeyA.currency0, 100e18);
        vault.recordClaims(poolIdB, poolKeyB.currency0, 50e18);

        assertEq(vault.getClaims(poolIdA, poolKeyA.currency0), 100e18);
        assertEq(vault.getClaims(poolIdB, poolKeyB.currency0), 50e18);
    }

    // ══════════════════════════════════════════════════════════
    //  Just-in-time vault allowance refresh
    // ══════════════════════════════════════════════════════════

    /// @dev Simulates a USDT-style decrement on the hook's vault allowance: the test prank-
    ///      calls `approve` from the hook to lower its vault allowance below the next
    ///      deposit amount. Without the just-in-time check, `_depositToVault`'s subsequent
    ///      `vault.deposit` would revert on insufficient allowance, bricking the pool. With
    ///      the check, the allowance is refreshed to `type(uint256).max` before the deposit.
    function test_depositToVault_refreshesAllowance_whenBelowAmount() public {
        _bootstrap(alice, 1_000e18);

        // Simulate USDT-style allowance decrement: hook's allowance drops below next deposit.
        vm.prank(address(vault));
        token0.approve(address(vault0), 100); // 100 wei is far below any realistic deposit

        // Fund the pool's tracked ERC-20 ledger so `_depositAllToVault` has something to push.
        // This also requires bypassing share-math (we want a raw ERC-20 → vault flow for the
        // allowance test), so we use `ensureERC20` to populate ERC-20 from a vault-shares
        // withdrawal first, then re-deposit.
        token0.mint(address(vault), 5_000e18);
        // Direct push of `5_000e18` into the vault — without the JIT check, this reverts on
        // allowance.
        vault.depositToVault(poolIdA, poolKeyA.currency0, 5_000e18);

        // Verify allowance was refreshed to max (the post-condition of the JIT check).
        assertEq(token0.allowance(address(vault), address(vault0)), type(uint256).max);
    }

    /// @dev Same-currency-and-vault but the allowance is already comfortably above the deposit.
    ///      The JIT check should NOT issue a redundant `forceApprove` (gas conservation), but
    ///      the post-deposit allowance must still be sufficient for future ops.
    function test_depositToVault_doesNotRefresh_whenAllowanceSufficient() public {
        _bootstrap(alice, 1_000e18);

        // Allowance is already type(uint256).max from `_approveVault` at setVault time.
        uint256 beforeAllowance = token0.allowance(address(vault), address(vault0));
        assertEq(beforeAllowance, type(uint256).max);

        // Trigger another deposit that's small enough to leave plenty of headroom.
        token0.mint(address(vault), 1_000e18);
        vault.depositToVault(poolIdA, poolKeyA.currency0, 1_000e18);

        // For non-decrementing tokens, allowance stays at max — no forceApprove needed.
        // For USDT-style (which solmate's MockERC20 doesn't simulate), this assertion would
        // hold trivially because `forceApprove` would have raised it back to max anyway.
        assertEq(token0.allowance(address(vault), address(vault0)), type(uint256).max);
    }

    // ══════════════════════════════════════════════════════════
    //  Per-pool effective sizing (maxWithdraw primary, previewRedeem fallback)
    // ══════════════════════════════════════════════════════════

    /// @dev `effectiveBalance` sizes the vault leg via `maxWithdraw(hook)` clamped to the pool's
    ///      own share value. Two pools sharing the same vault each see their own stake; the
    ///      owner-scoped `maxWithdraw` cap binds only when it drops below a pool's value.
    function test_effectiveBalance_maxWithdrawPrimary_perPoolClamp() public {
        _bootstrap(alice, 1_000e18);
        vault.setVault(poolIdB, poolKeyB.currency0, IERC4626(address(vault0)));
        vault.setVault(poolIdB, poolKeyB.currency1, IERC4626(address(vault1)));
        _bootstrapPool(poolKeyB, bob, 4_000e18);

        // Pool A owns 1000 vault shares; pool B owns 4000. The fully liquid MockERC4626 reports
        // maxWithdraw(hook) = 5000 (owner-scoped, both pools combined); each pool must be
        // clamped to its own share value.
        uint256 effA = vault.effectiveBalance(poolIdA, poolKeyA.currency0);
        uint256 effB = vault.effectiveBalance(poolIdB, poolKeyB.currency0);
        assertEq(effA, 1_000e18, "pool A clamped to its own share value");
        assertEq(effB, 4_000e18, "pool B clamped to its own share value");

        // Constrain the owner-scoped cap below pool B's value: A stays at its own value, B is
        // capped at what the vault says the hook can withdraw atomically.
        vm.mockCall(
            address(vault0), abi.encodeWithSelector(IERC4626.maxWithdraw.selector, address(vault)), abi.encode(2_500e18)
        );
        assertEq(vault.effectiveBalance(poolIdA, poolKeyA.currency0), 1_000e18, "pool A below the cap");
        assertEq(vault.effectiveBalance(poolIdB, poolKeyB.currency0), 2_500e18, "pool B capped by maxWithdraw");
    }

    /// @dev With `maxWithdraw` at the `0` sentinel, sizing falls back to the per-pool
    ///      `previewRedeem(shares)` value (the pre-change behavior for VaultV2-style vaults).
    ///      Each pool reflects its own share count through the mocked per-share figure.
    function test_effectiveBalance_zeroMaxWithdraw_fallsBackToPreviewRedeemPerShare() public {
        _bootstrap(alice, 1_000e18);
        vault.setVault(poolIdB, poolKeyB.currency0, IERC4626(address(vault0)));
        vault.setVault(poolIdB, poolKeyB.currency1, IERC4626(address(vault1)));
        _bootstrapPool(poolKeyB, bob, 4_000e18);

        vm.mockCall(
            address(vault0), abi.encodeWithSelector(IERC4626.maxWithdraw.selector, address(vault)), abi.encode(0)
        );
        vm.mockCall(
            address(vault0),
            abi.encodeWithSelector(IERC4626.previewRedeem.selector, uint256(1_000e18)),
            abi.encode(500e18)
        );
        vm.mockCall(
            address(vault0),
            abi.encodeWithSelector(IERC4626.previewRedeem.selector, uint256(4_000e18)),
            abi.encode(2_000e18)
        );

        assertEq(vault.effectiveBalance(poolIdA, poolKeyA.currency0), 500e18, "pool A reflects mocked previewRedeem");
        assertEq(vault.effectiveBalance(poolIdB, poolKeyB.currency0), 2_000e18, "pool B reflects mocked previewRedeem");
    }

    /// @dev The partner-reported SparkVault scenario: the pool's position value exceeds the
    ///      vault's idle liquidity (capital deployed), where `previewRedeem` reverts. Sizing
    ///      reports the idle-capped figure, and a withdrawal sized to that figure clears the
    ///      vault's liquidity gate.
    function test_effectiveBalance_sparkVault_idleCapped() public {
        MockSparkVault spark0 = new MockSparkVault(ERC20(address(token0)));
        vault.setVault(poolIdB, poolKeyB.currency0, IERC4626(address(spark0)));
        _bootstrapPool(poolKeyB, bob, 1_000e18);

        // Deploy 600 of the vault's 1000 idle: previewRedeem on the pool's full position now
        // reverts, so a previewRedeem-primary sizing would revert every read.
        spark0.allocate(makeAddr("sparkAllocator"), 600e18);
        uint256 fullPosition = spark0.balanceOf(address(vault));
        vm.expectRevert("SparkVault/insufficient-liquidity");
        spark0.previewRedeem(fullPosition);

        assertEq(vault.effectiveBalance(poolIdB, poolKeyB.currency0), 400e18, "sized to idle liquidity");

        vault.withdrawFromVault(poolIdB, poolKeyB.currency0, 400e18);
        assertEq(vault.getERC20(poolIdB, poolKeyB.currency0), 400e18, "withdrawal within idle succeeds");
        assertEq(vault.effectiveBalance(poolIdB, poolKeyB.currency0), 400e18, "post-withdraw: raw ERC-20 leg");
    }

    // ══════════════════════════════════════════════════════════
    //  Morpho VaultV2 compatibility (maxWithdraw == 0 vaults)
    // ══════════════════════════════════════════════════════════

    /// @dev With a VaultV2-shaped vault (`maxWithdraw == 0`), `effectiveBalance` MUST still
    ///      reflect the pool's share-redemption value via `previewRedeem`. A pre-change
    ///      `maxWithdraw`-based sizing would have returned 0 here, silently degrading every
    ///      VaultV2 pool to zero deployable liquidity.
    function test_effectiveBalance_zeroMaxWithdraw_usesPreviewRedeem() public {
        MockMorphoVaultV2 vv2 = new MockMorphoVaultV2(ERC20(address(token0)));
        vault.setVault(poolIdA, poolKeyA.currency0, IERC4626(address(vv2)));
        // vault1 is untouched (still vault1).

        _bootstrap(alice, 1_000e18);

        uint256 mwd = vv2.maxWithdraw(address(vault));
        assertEq(mwd, 0, "VaultV2 mock: maxWithdraw is hard-zero");

        uint256 eff = vault.effectiveBalance(poolIdA, poolKeyA.currency0);
        assertGt(eff, 0, "effective balance must be non-zero despite maxWithdraw == 0");
    }

    /// @dev When the vault reverts on `withdraw` (Morpho's NotEnoughLiquidity, paused, etc.),
    ///      the revert bubbles up through `_ensureERC20` to the caller -- there is no longer
    ///      a uniform PoolVault sentinel sitting in the way.
    function test_ensureERC20_bubblesVaultRevert() public {
        MockMorphoVaultV2 vv2 = new MockMorphoVaultV2(ERC20(address(token0)));
        vault.setVault(poolIdA, poolKeyA.currency0, IERC4626(address(vv2)));

        _bootstrap(alice, 1_000e18);
        vv2.setWithdrawShortfall(true);

        // The pool's tracked ERC-20 is zero (all in vault); ensureERC20(100) must call
        // vault.withdraw and surface the vault's revert.
        vm.expectRevert(MockMorphoVaultV2.WithdrawShortfall.selector);
        vault.ensureERC20(poolIdA, poolKeyA.currency0, 100e18);
    }

    /// @dev `_withdrawFromVault` also bubbles vault reverts now that the maxWithdraw
    ///      pre-flight cap is gone.
    function test_withdrawFromVault_bubblesVaultRevert() public {
        MockMorphoVaultV2 vv2 = new MockMorphoVaultV2(ERC20(address(token0)));
        vault.setVault(poolIdA, poolKeyA.currency0, IERC4626(address(vv2)));

        _bootstrap(alice, 1_000e18);
        vv2.setWithdrawShortfall(true);

        vm.expectRevert(MockMorphoVaultV2.WithdrawShortfall.selector);
        vault.withdrawFromVault(poolIdA, poolKeyA.currency0, 100e18);
    }

    /// @dev Deposits MUST proceed when `maxWithdraw == 0` -- the deposit path does not read
    ///      it. Regression for the VaultV2 onboarding flow.
    function test_addLiquidity_proceedsWhenMaxWithdrawIsZero() public {
        MockMorphoVaultV2 vv2 = new MockMorphoVaultV2(ERC20(address(token0)));
        vault.setVault(poolIdA, poolKeyA.currency0, IERC4626(address(vv2)));
        _bootstrap(alice, 1_000e18);
        vm.roll(block.number + 1);

        // Bob deposits subsequent shares; the deposit path must not read maxWithdraw.
        (uint256 a0, uint256 a1) = _depositA(bob, 100e18);
        assertGt(a0, 0);
        assertGt(a1, 0);
        assertEq(vault.userShares(poolIdA, bob), 100e18);
    }

    // ══════════════════════════════════════════════════════════
    //  Asymmetry: totalAssets vs effectiveBalance under exit fees
    // ══════════════════════════════════════════════════════════

    /// @dev Verifies the deliberate asymmetry between `totalAssets` (uses `convertToAssets`,
    ///      reflects LP economic stake) and `effectiveBalance` (uses `previewRedeem`, reflects
    ///      the realizable-now value). On a vault that charges a withdrawal fee, the two views
    ///      MUST diverge; LP share math must NOT shrink by the exit-fee delta.
    function test_totalAssets_vs_effectiveBalance_withExitFee() public {
        MockMorphoVaultV2 vv2 = new MockMorphoVaultV2(ERC20(address(token0)));
        vault.setVault(poolIdA, poolKeyA.currency0, IERC4626(address(vv2)));

        _bootstrap(alice, 1_000e18);

        // Snapshot: total assets and per-share previewWithdraw BEFORE any exit fee.
        (uint256 totalBefore,) = vault.totalAssets(poolKeyA);
        (uint256 perShareBefore,) = vault.previewWithdraw(poolKeyA, 100e18);

        // Apply a 5% exit fee on the vault. `previewRedeem` shrinks by 5%; `convertToAssets`
        // is unchanged -- exactly the asymmetry the contract relies on.
        vv2.setExitFeeBps(500);

        (uint256 totalAfter,) = vault.totalAssets(poolKeyA);
        (uint256 perShareAfter,) = vault.previewWithdraw(poolKeyA, 100e18);

        assertEq(totalBefore, totalAfter, "(a) LP share math unaffected by exit-fee change");
        assertEq(perShareBefore, perShareAfter, "(a) LP per-share withdraw amount unaffected by exit-fee change");

        // (b) `effectiveBalance` reflects the post-fee realizable value.
        uint256 effective = vault.effectiveBalance(poolIdA, poolKeyA.currency0);
        // Bootstrap deposited 1000e18 vault shares at 1:1, so previewRedeem = 1000 * (1 - 5%) = 950.
        assertEq(effective, 950e18, "(b) effectiveBalance reflects previewRedeem net of exit fee");
        assertLt(effective, totalAfter, "(b) effective < totalAssets when exit fee is active");
    }

    // ══════════════════════════════════════════════════════════
    //  Zero-amount lifecycle edges
    // ══════════════════════════════════════════════════════════

    /// @dev A zero-share deposit converts to zero token amounts on both legs, so the pull path's
    ///      `want == 0` early return fires and no transfer occurs. Locks in that the degenerate
    ///      call is a harmless no-op rather than a revert or a spurious 1-wei round-up pull.
    function test_deposit_zeroShares_pullsNothing() public {
        _bootstrap(alice, 1000e18);

        uint256 supplyBefore = vault.totalShares(poolIdA);
        uint256 balBefore = token0.balanceOf(bob);

        vm.prank(bob);
        (uint256 a0, uint256 a1) = vault.deposit(poolKeyA, bob, bob, 0);

        assertEq(a0, 0, "no asset0 pulled for zero shares");
        assertEq(a1, 0, "no asset1 pulled for zero shares");
        assertEq(vault.totalShares(poolIdA), supplyBefore, "supply unchanged");
        assertEq(vault.userShares(poolIdA, bob), 0, "no shares minted");
        assertEq(token0.balanceOf(bob), balBefore, "no tokens moved");
    }

    /// @dev A zero-share withdraw converts to zero token amounts, so the push path's
    ///      `amount == 0` early return fires: no vault interaction, no transfer.
    function test_withdraw_zeroShares_pushesNothing() public {
        _bootstrap(alice, 1000e18);

        uint256 sharesBefore = vault.userShares(poolIdA, alice);
        uint256 vaultSharesBefore = vault.getVaultShares(poolIdA, poolKeyA.currency0);

        (uint256 a0, uint256 a1) = vault.withdraw(poolKeyA, alice, alice, 0);

        assertEq(a0, 0, "no asset0 pushed for zero shares");
        assertEq(a1, 0, "no asset1 pushed for zero shares");
        assertEq(vault.userShares(poolIdA, alice), sharesBefore, "share balance unchanged");
        assertEq(vault.getVaultShares(poolIdA, poolKeyA.currency0), vaultSharesBefore, "vault untouched");
    }

    // ══════════════════════════════════════════════════════════
    //  Non-vaulted shortfall + cross-pool share-leak guards
    // ══════════════════════════════════════════════════════════

    /// @dev For a non-vaulted pool with insufficient raw ERC-20, `_ensureERC20`'s
    ///      `bal - amount` underflows and panics: there is deliberately no sentinel revert
    ///      (see InventoryLib.ensureERC20 NatSpec). Locks the documented failure mode in.
    function test_ensureERC20_nonVaultedShortfall_panics() public {
        _bootstrapPool(poolKeyB, alice, 500e18); // unvaulted: _erc20[B] = 500e18

        vm.expectRevert(stdError.arithmeticError);
        vault.ensureERC20(poolIdB, poolKeyB.currency0, 500e18 + 1);
    }

    /// @dev `CrossPoolShareLeak` fires when a vault redemption consumes more shares than the
    ///      partition owns. Real vaults cannot normally do this; mock the vault's `withdraw`
    ///      return to simulate a corrupted/adversarial share consumption.
    function test_withdrawFromVault_revertsOnCrossPoolShareLeak() public {
        _bootstrap(alice, 1000e18); // partition owns 1000e18 vault0 shares (1:1)

        uint256 poolShares = vault.getVaultShares(poolIdA, poolKeyA.currency0);
        vm.mockCall(
            address(vault0),
            abi.encodeWithSelector(IERC4626.withdraw.selector, 100e18, address(vault), address(vault)),
            abi.encode(poolShares + 1)
        );

        vm.expectRevert(InventoryLib.CrossPoolShareLeak.selector);
        vault.withdrawFromVault(poolIdA, poolKeyA.currency0, 100e18);
    }

    /// @dev Same guard on the `_ensureERC20` vaulted-shortfall path.
    function test_ensureERC20_revertsOnCrossPoolShareLeak() public {
        _bootstrap(alice, 1000e18);

        uint256 poolShares = vault.getVaultShares(poolIdA, poolKeyA.currency0);
        vm.mockCall(
            address(vault0),
            abi.encodeWithSelector(IERC4626.withdraw.selector, 100e18, address(vault), address(vault)),
            abi.encode(poolShares + 1)
        );

        vm.expectRevert(InventoryLib.CrossPoolShareLeak.selector);
        vault.ensureERC20(poolIdA, poolKeyA.currency0, 100e18);
    }

    // ══════════════════════════════════════════════════════════
    //  Best-effort vault deposit (afterSwap re-deposit semantics)
    // ══════════════════════════════════════════════════════════

    /// @dev When the vault rejects the afterSwap-style re-deposit, `_depositAllToVault`
    ///      soft-fails: the raw ERC-20 stays on the pool's ledger, vault shares are untouched,
    ///      and `VaultDepositSkipped` carries the vault's raw revert data for diagnostics.
    function test_depositAllToVault_skipsAndEmitsOnVaultRejection() public {
        MockMorphoVaultV2 vv2 = new MockMorphoVaultV2(ERC20(address(token0)));
        vault.setVault(poolIdA, poolKeyA.currency0, IERC4626(address(vv2)));
        _bootstrap(alice, 1000e18);

        // Pull 100 back to the raw ledger so the sweep has something to push.
        vault.withdrawFromVault(poolIdA, poolKeyA.currency0, 100e18);
        assertEq(vault.getERC20(poolIdA, poolKeyA.currency0), 100e18);

        vv2.setDepositShortfall(true);
        uint256 sharesBefore = vault.getVaultShares(poolIdA, poolKeyA.currency0);

        vm.expectEmit(true, true, false, true, address(vault));
        emit PoolVault.VaultDepositSkipped(
            poolIdA, poolKeyA.currency0, 100e18, abi.encodeWithSelector(MockMorphoVaultV2.DepositShortfall.selector)
        );
        vault.depositAllToVault(poolIdA, poolKeyA.currency0);

        assertEq(vault.getERC20(poolIdA, poolKeyA.currency0), 100e18, "raw ledger intact after skip");
        assertEq(vault.getVaultShares(poolIdA, poolKeyA.currency0), sharesBefore, "vault shares untouched");
    }

    // ══════════════════════════════════════════════════════════
    //  Best-effort vault drain (emergency rescue leg)
    // ══════════════════════════════════════════════════════════

    /// @dev Cooperative vault: the full position redeems back to the raw ledger and
    ///      `VaultDrained` reports shares and assets.
    function test_drainVaultBestEffort_cooperativeVault_drainsToERC20() public {
        _bootstrap(alice, 1000e18);
        uint256 shares = vault.getVaultShares(poolIdA, poolKeyA.currency0);
        assertGt(shares, 0);

        vm.expectEmit(true, true, false, true, address(vault));
        emit PoolVault.VaultDrained(poolIdA, poolKeyA.currency0, shares, 1000e18);
        vault.drainVaultBestEffort(poolIdA, poolKeyA.currency0);

        assertEq(vault.getVaultShares(poolIdA, poolKeyA.currency0), 0, "position fully redeemed");
        assertEq(vault.getERC20(poolIdA, poolKeyA.currency0), 1000e18, "assets credited to raw ledger");
    }

    /// @dev Bricked vault: the redeem reverts, the drain is skipped (shares intact, no raw
    ///      credit), and `VaultDrainSkipped` carries the vault's revert data. The surrounding
    ///      emergency action must not be blocked by the failed rescue.
    function test_drainVaultBestEffort_brickedVault_skipsAndKeepsShares() public {
        MockMorphoVaultV2 vv2 = new MockMorphoVaultV2(ERC20(address(token0)));
        vault.setVault(poolIdA, poolKeyA.currency0, IERC4626(address(vv2)));
        _bootstrap(alice, 1000e18);

        uint256 shares = vault.getVaultShares(poolIdA, poolKeyA.currency0);
        vv2.setWithdrawShortfall(true);

        vm.expectEmit(true, true, false, true, address(vault));
        emit PoolVault.VaultDrainSkipped(
            poolIdA, poolKeyA.currency0, shares, abi.encodeWithSelector(MockMorphoVaultV2.WithdrawShortfall.selector)
        );
        vault.drainVaultBestEffort(poolIdA, poolKeyA.currency0);

        assertEq(vault.getVaultShares(poolIdA, poolKeyA.currency0), shares, "shares intact after skipped drain");
        assertEq(vault.getERC20(poolIdA, poolKeyA.currency0), 0, "no raw credit on failed drain");
    }

    /// @dev Nothing to drain (no vault shares): silent no-op, no event.
    function test_drainVaultBestEffort_noPosition_isNoOp() public {
        _bootstrapPool(poolKeyB, alice, 500e18); // unvaulted pool

        vm.recordLogs();
        vault.drainVaultBestEffort(poolIdB, poolKeyB.currency0);

        assertEq(vm.getRecordedLogs().length, 0, "no events for an empty drain");
        assertEq(vault.getERC20(poolIdB, poolKeyB.currency0), 500e18, "raw ledger untouched");
    }

    // ══════════════════════════════════════════════════════════
    //  Per-pool ERC-20 debit (post-settlement bookkeeping)
    // ══════════════════════════════════════════════════════════

    function test_debitPoolERC20_debitsLedger() public {
        _bootstrapPool(poolKeyB, alice, 500e18);

        vault.debitPoolERC20(poolIdB, poolKeyB.currency0, 200e18);
        assertEq(vault.getERC20(poolIdB, poolKeyB.currency0), 300e18);

        // Zero-amount debit is a no-op.
        vault.debitPoolERC20(poolIdB, poolKeyB.currency0, 0);
        assertEq(vault.getERC20(poolIdB, poolKeyB.currency0), 300e18);
    }

    function test_debitPoolERC20_revertsWhenLedgerShort() public {
        _bootstrapPool(poolKeyB, alice, 500e18);

        vm.expectRevert(InsufficientPoolBalance.selector);
        vault.debitPoolERC20(poolIdB, poolKeyB.currency0, 500e18 + 1);
    }
}
