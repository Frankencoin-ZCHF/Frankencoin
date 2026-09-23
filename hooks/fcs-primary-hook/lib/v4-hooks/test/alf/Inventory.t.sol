// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {Inventory, InsufficientPoolBalance} from "../../src/alf/types/Inventory.sol";
import {InventoryLib} from "../../src/alf/libraries/InventoryLib.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";
import {MockMorphoVaultV2} from "./mocks/MockMorphoVaultV2.sol";
import {MockSparkVault} from "./mocks/MockSparkVault.sol";

/// @notice Harness holding a real `Inventory` storage value and exposing both halves of the
///         capability as external calls. The context-free free functions (accessors, balance
///         views, claim accounting) and the context-bound `InventoryLib` operations (vault
///         deposit/withdraw/redeem, allowance management) are both invoked uniformly as
///         `_inv.method(...)`. The `InventoryLib` functions inline into this harness, so
///         `address(this)` (the token custodian and vault depositor) resolves to the harness:
///         that is exactly why they live in the library and why isolated coverage of them is
///         possible without standing up a full hook.
contract InventoryHarness {
    using InventoryLib for Inventory;

    Inventory internal _inv;

    /// @dev Mirror of `PoolVault._partition`: `keccak256(abi.encode(poolId, currency))` derived in
    ///      the scratch region. The harness keys directly on `(bytes32 poolId, Currency currency)`
    ///      so callers compose arbitrary partitions without a PoolKey.
    function partitionOf(bytes32 poolId, Currency currency) public pure returns (bytes32 partition) {
        assembly ("memory-safe") {
            mstore(0x00, poolId)
            mstore(0x20, currency)
            partition := keccak256(0x00, 0x40)
        }
    }

    // ─── Free-function accessors / views ──────────────────────────────────────────────────────

    function vaultOf(bytes32 partition) external view returns (IERC4626) {
        return _inv.vaultOf(partition);
    }

    function setVault(bytes32 partition, IERC4626 vault) external {
        _inv.setVault(partition, vault);
    }

    function sharesOf(bytes32 partition) external view returns (uint256) {
        return _inv.sharesOf(partition);
    }

    function erc20Of(bytes32 partition) external view returns (uint256) {
        return _inv.erc20Of(partition);
    }

    function claimsOf(bytes32 partition) external view returns (uint256) {
        return _inv.claimsOf(partition);
    }

    function assetBalance(bytes32 partition) external view returns (uint256) {
        return _inv.assetBalance(partition);
    }

    function effectiveBalance(bytes32 partition) external view returns (uint256) {
        return _inv.effectiveBalance(partition);
    }

    function unbackedClaims(bytes32 partition, Currency currency, IPoolManager pm) external view returns (uint256) {
        return _inv.unbackedClaims(partition, currency, pm);
    }

    function recordClaims(bytes32 partition, uint256 amount) external {
        _inv.recordClaims(partition, amount);
    }

    function debitERC20(bytes32 partition, uint256 amount) external {
        _inv.debitERC20(partition, amount);
    }

    // ─── InventoryLib context-bound ops ─────────────────────────────────────────────────────────

    function depositToVault(bytes32 partition, Currency currency, uint256 amount) external {
        _inv.depositToVault(partition, currency, amount);
    }

    function withdrawFromVault(bytes32 partition, uint256 amount) external {
        _inv.withdrawFromVault(partition, amount);
    }

    function ensureERC20(bytes32 partition, uint256 amount) external {
        _inv.ensureERC20(partition, amount);
    }

    function tryDepositAll(bytes32 partition) external returns (uint256 amount, bool ok, bytes memory reason) {
        return _inv.tryDepositAll(partition);
    }

    function tryDrain(bytes32 partition)
        external
        returns (uint256 shares, uint256 assets, bool ok, bytes memory reason)
    {
        return _inv.tryDrain(partition);
    }

    function requireFeelessVault(IERC4626 vault) external view {
        InventoryLib.requireFeelessVault(vault);
    }

    function approveVault(Currency currency, address vault) external {
        InventoryLib.approveVault(currency, vault);
    }

    /// @dev Seed the partition's raw ERC-20 counter without going through a vault. Mirrors the
    ///      no-vault `depositToVault` credit path so tests can stage a raw balance directly.
    function creditERC20(bytes32 partition, Currency currency, uint256 amount) external {
        _inv.depositToVault(partition, currency, amount);
    }
}

/// @title InventoryTest
/// @notice Isolated unit tests for the `Inventory` capability type and `InventoryLib`, targeting
///         the revert / event / view branches a full PoolVault integration test does not exercise
///         directly. The harness holds the storage value; `InventoryLib` ops run in its context.
contract InventoryTest is Test {
    InventoryHarness internal h;

    MockERC20 internal token;
    MockERC4626 internal vault;

    bytes32 internal partition;
    Currency internal currency;

    /// @dev Local mirror of the `VaultBound` event declared at file scope in Inventory.sol. A local
    ///      declaration (rather than importing the symbol) gives `vm.expectEmit` a definition to
    ///      `emit` against; the topic/data layout is identical, which is what `expectEmit` matches.
    event VaultBound(bytes32 indexed partition, IERC4626 vault);

    function setUp() public {
        h = new InventoryHarness();
        token = new MockERC20("Token", "TKN", 18);
        vault = new MockERC4626(ERC20(address(token)));
        currency = Currency.wrap(address(token));
        partition = h.partitionOf(bytes32(uint256(0xABCD)), currency);
    }

    // ─── helpers ────────────────────────────────────────────────────────────────────────────────

    /// @dev Bind `vault` to `partition` and grant it max allowance, mirroring the production
    ///      bind-time approval so deposits do not trip on allowance.
    function _bindVault(IERC4626 v) internal {
        h.setVault(partition, v);
        h.approveVault(currency, address(v));
    }

    /// @dev Fund the harness with `amount` underlying so it can deposit into a vault.
    function _fundHarness(uint256 amount) internal {
        token.mint(address(h), amount);
    }

    /// @dev Leading 4-byte selector of captured revert data. A direct `bytes4(bytes memory)` cast
    ///      is not valid Solidity, so read the first word from the data region and truncate.
    function _selector(bytes memory data) internal pure returns (bytes4 sel) {
        require(data.length >= 4, "reason too short");
        assembly {
            sel := mload(add(data, 0x20))
        }
    }

    // ══════════════════════════════════════════════════════════
    //  debitERC20
    // ══════════════════════════════════════════════════════════

    function test_debitERC20_revertsWhenAmountExceedsPartitionBalance() public {
        // Stage 100 raw ERC-20 in the partition (no vault bound -> raw credit).
        _fundHarness(100);
        h.creditERC20(partition, currency, 100);
        assertEq(h.erc20Of(partition), 100, "raw ERC-20 staged");

        // Debiting one wei past the tracked balance reverts; the partition's global balance is the
        // source of truth, not the contract's `balanceOf`.
        vm.expectRevert(InsufficientPoolBalance.selector);
        h.debitERC20(partition, 101);
    }

    function test_debitERC20_revertsWhenPartitionEmpty() public {
        // An untouched partition has zero raw; any non-zero debit reverts.
        vm.expectRevert(InsufficientPoolBalance.selector);
        h.debitERC20(partition, 1);
    }

    function test_debitERC20_succeedsUpToExactBalance() public {
        _fundHarness(100);
        h.creditERC20(partition, currency, 100);

        h.debitERC20(partition, 60);
        assertEq(h.erc20Of(partition), 40, "partial debit");

        // Exact-balance debit drains to zero and must not revert.
        h.debitERC20(partition, 40);
        assertEq(h.erc20Of(partition), 0, "exact-balance debit drains partition");
    }

    function test_debitERC20_zeroAmountIsNoop_evenOnEmptyPartition() public {
        // The `amount == 0` early-return runs before the balance check, so a zero debit on an
        // empty partition must NOT revert.
        h.debitERC20(partition, 0);
        assertEq(h.erc20Of(partition), 0, "zero debit leaves partition untouched");
    }

    function test_debitERC20_zeroAmount_leavesNonZeroBalanceUntouched() public {
        _fundHarness(50);
        h.creditERC20(partition, currency, 50);

        h.debitERC20(partition, 0);
        assertEq(h.erc20Of(partition), 50, "zero debit is a true no-op");
    }

    // ══════════════════════════════════════════════════════════
    //  recordClaims
    // ══════════════════════════════════════════════════════════

    function test_recordClaims_accumulates() public {
        assertEq(h.claimsOf(partition), 0, "fresh partition has no claims");

        h.recordClaims(partition, 100e18);
        assertEq(h.claimsOf(partition), 100e18, "first record");

        h.recordClaims(partition, 50e18);
        assertEq(h.claimsOf(partition), 150e18, "second record accumulates");

        // A zero record is a harmless no-op (the cast of `x + 0` is well-defined).
        h.recordClaims(partition, 0);
        assertEq(h.claimsOf(partition), 150e18, "zero record is a no-op");
    }

    function test_recordClaims_atUint128Max() public {
        // The field is uint128; recording exactly the max must succeed and round-trip.
        h.recordClaims(partition, type(uint128).max);
        assertEq(h.claimsOf(partition), type(uint128).max, "exactly uint128 max fits");
    }

    function test_recordClaims_revertsOnUint128Overflow() public {
        // First record the max, then one more wei must trip the SafeCast.toUint128 guard:
        // (uint256(claims) + amount) > type(uint128).max.
        h.recordClaims(partition, type(uint128).max);

        // SafeCast.toUint128 reverts with the library's SafeCastOverflow selector. Match the
        // revert without binding to the exact selector so the test stays robust to the SafeCast
        // implementation; the accumulation that triggers it is the load-bearing branch.
        vm.expectRevert();
        h.recordClaims(partition, 1);
    }

    function test_recordClaims_overflowFromSplitAmounts() public {
        // Overflow on accumulation, not on a single oversized record: half the max plus more than
        // half overflows the uint128 sum.
        uint256 half = uint256(type(uint128).max) / 2 + 1;
        h.recordClaims(partition, half);
        vm.expectRevert();
        h.recordClaims(partition, half);
    }

    // ══════════════════════════════════════════════════════════
    //  unbackedClaims
    // ══════════════════════════════════════════════════════════

    /// @dev `unbackedClaims` reads ONLY `currency.balanceOf(address(pm))`, so the `pm` argument can
    ///      be any address holding the underlying. We use a labelled EOA cast to `IPoolManager` and
    ///      seed its ERC-20 balance to model the PoolManager's backing without standing up a real
    ///      PoolManager (the burn/take redemption path in `redeemClaims` is exercised by the
    ///      PoolVault integration suite, which has a live manager inside an unlock).
    function _pm() internal returns (IPoolManager) {
        return IPoolManager(makeAddr("poolManagerStub"));
    }

    function test_unbackedClaims_zeroWhenNoClaims() public {
        IPoolManager pm = _pm();
        // No claims recorded -> early return 0, regardless of PM balance.
        assertEq(h.unbackedClaims(partition, currency, pm), 0, "no claims -> nothing unbacked");
    }

    function test_unbackedClaims_zeroWhenFullyBacked() public {
        IPoolManager pm = _pm();
        h.recordClaims(partition, 100e18);
        // PM holds exactly the claimed amount: fully backed.
        token.mint(address(pm), 100e18);
        assertEq(h.unbackedClaims(partition, currency, pm), 0, "claims == backing -> fully backed");
    }

    function test_unbackedClaims_zeroWhenOverBacked() public {
        IPoolManager pm = _pm();
        h.recordClaims(partition, 100e18);
        // PM holds more than the claims (e.g. other partitions' backing): still zero unbacked.
        token.mint(address(pm), 250e18);
        assertEq(h.unbackedClaims(partition, currency, pm), 0, "backing > claims -> fully backed");
    }

    function test_unbackedClaims_nonZeroWhenPartiallyBacked() public {
        IPoolManager pm = _pm();
        h.recordClaims(partition, 100e18);
        // PM holds only 40 of the 100 claimed: 60 is unbacked (settle still pending).
        token.mint(address(pm), 40e18);
        assertEq(h.unbackedClaims(partition, currency, pm), 60e18, "claims - available is unbacked");
    }

    function test_unbackedClaims_fullyUnbackedWhenPMEmpty() public {
        IPoolManager pm = _pm();
        h.recordClaims(partition, 100e18);
        // PM holds nothing: the entire claim is unbacked.
        assertEq(h.unbackedClaims(partition, currency, pm), 100e18, "no backing -> all claims unbacked");
    }

    // ══════════════════════════════════════════════════════════
    //  setVault event
    // ══════════════════════════════════════════════════════════

    function test_setVault_emitsVaultBound() public {
        vm.expectEmit(true, false, false, true, address(h));
        emit VaultBound(partition, IERC4626(address(vault)));
        h.setVault(partition, IERC4626(address(vault)));

        assertEq(address(h.vaultOf(partition)), address(vault), "vault bound");
    }

    function test_setVault_emitsVaultBound_onUnbindToZero() public {
        h.setVault(partition, IERC4626(address(vault)));

        // Unbinding back to raw ERC-20 binds address(0) and still emits.
        vm.expectEmit(true, false, false, true, address(h));
        emit VaultBound(partition, IERC4626(address(0)));
        h.setVault(partition, IERC4626(address(0)));

        assertEq(address(h.vaultOf(partition)), address(0), "unbound to raw ERC-20");
    }

    // ══════════════════════════════════════════════════════════
    //  assetBalance vs effectiveBalance
    // ══════════════════════════════════════════════════════════

    function test_balances_agree_withoutVault() public {
        // Raw + claims only; both views read the same fields, no vault leg.
        _fundHarness(300);
        h.creditERC20(partition, currency, 300);
        h.recordClaims(partition, 200);

        assertEq(h.assetBalance(partition), 500, "raw + claims");
        assertEq(h.effectiveBalance(partition), 500, "raw + claims (effective)");
    }

    function test_balances_agree_feelessVault() public {
        // A plain 1:1 MockERC4626 has no exit fee: convertToAssets == previewRedeem, so the two
        // views agree exactly.
        _bindVault(IERC4626(address(vault)));
        _fundHarness(1_000e18);
        h.depositToVault(partition, currency, 1_000e18);

        uint256 asset = h.assetBalance(partition);
        uint256 effective = h.effectiveBalance(partition);
        assertEq(asset, 1_000e18, "assetBalance via convertToAssets");
        assertEq(effective, asset, "no exit fee -> views agree");
    }

    function test_balances_diverge_underExitFee() public {
        // VaultV2-shaped vault: convertToAssets is unchanged by the exit fee, previewRedeem shrinks.
        // assetBalance (convertToAssets, LP economic stake) MUST stay above effectiveBalance
        // (previewRedeem, realizable-now) by exactly the fee delta.
        MockMorphoVaultV2 vv2 = new MockMorphoVaultV2(ERC20(address(token)));
        _bindVault(IERC4626(address(vv2)));
        _fundHarness(1_000e18);
        h.depositToVault(partition, currency, 1_000e18);

        // Before any fee the two views agree.
        assertEq(h.assetBalance(partition), h.effectiveBalance(partition), "agree before fee");

        // Apply a 5% exit fee.
        vv2.setExitFeeBps(500);

        uint256 asset = h.assetBalance(partition);
        uint256 effective = h.effectiveBalance(partition);
        assertEq(asset, 1_000e18, "assetBalance ignores exit fee (convertToAssets)");
        assertEq(effective, 950e18, "effectiveBalance reflects 5% exit fee (previewRedeem)");
        assertLt(effective, asset, "effective < gross under exit fee");
    }

    function test_balances_includeRawAndClaims_alongsideVaultLeg() public {
        // Cover the claims + vault-leg addition for both views. Once a vault is bound,
        // `depositToVault` routes everything into shares, so the non-vault leg here is supplied by
        // recorded claims. With a feeless vault the convertToAssets/previewRedeem legs are equal.
        _bindVault(IERC4626(address(vault)));
        _fundHarness(700e18);
        h.depositToVault(partition, currency, 700e18);
        h.recordClaims(partition, 300e18);

        // assetBalance = claims(300) + convertToAssets(shares for 700) = 1000.
        assertEq(h.assetBalance(partition), 1_000e18, "claims + vault leg");
        assertEq(h.effectiveBalance(partition), 1_000e18, "claims + vault leg (effective, no fee)");
    }

    function test_assetBalance_zeroShares_skipsVaultLeg() public {
        // Vault bound but no shares: the `shares > 0` guard skips the vault call, leaving raw+claims.
        _bindVault(IERC4626(address(vault)));
        h.recordClaims(partition, 42e18);
        assertEq(h.assetBalance(partition), 42e18, "no shares -> claims only");
        assertEq(h.effectiveBalance(partition), 42e18, "no shares -> claims only (effective)");
    }

    // ══════════════════════════════════════════════════════════
    //  effectiveBalance: liquidity-gated vaults (SparkVault)
    // ══════════════════════════════════════════════════════════

    /// @dev The partner-reported scenario: position value exceeds the vault's idle liquidity
    ///      (the vault's normal state once capital is deployed). SparkVault's `previewRedeem`
    ///      reverts in that state, so a previewRedeem-primary sizing bricked every read.
    ///      `maxWithdraw`-primary sizing reports the idle-capped figure instead.
    function test_effectiveBalance_sparkVault_capsAtIdleLiquidity() public {
        MockSparkVault spark = new MockSparkVault(ERC20(address(token)));
        _bindVault(IERC4626(address(spark)));
        _fundHarness(1_000e18);
        h.depositToVault(partition, currency, 1_000e18);

        // Deploy 600 out of the vault: totalAssets stays 1000, idle drops to 400.
        spark.allocate(makeAddr("sparkAllocator"), 600e18);

        // previewRedeem on the full position reverts; effectiveBalance must not.
        uint256 fullPosition = spark.balanceOf(address(h));
        vm.expectRevert("SparkVault/insufficient-liquidity");
        spark.previewRedeem(fullPosition);

        assertEq(h.effectiveBalance(partition), 400e18, "vault leg capped at idle liquidity");
        assertEq(h.assetBalance(partition), 1_000e18, "gross economic stake unaffected");
    }

    /// @dev With zero idle liquidity both `maxWithdraw` (returns 0) and `previewRedeem`
    ///      (reverts) are exhausted; the vault leg is honestly zero and raw + claims remain.
    function test_effectiveBalance_sparkVault_zeroIdle_returnsRawPlusClaims() public {
        MockSparkVault spark = new MockSparkVault(ERC20(address(token)));
        _bindVault(IERC4626(address(spark)));
        _fundHarness(1_000e18);
        h.depositToVault(partition, currency, 1_000e18);
        h.recordClaims(partition, 25e18);

        spark.allocate(makeAddr("sparkAllocator"), 1_000e18);

        assertEq(h.effectiveBalance(partition), 25e18, "zero idle -> claims only, no revert");
    }

    /// @dev `maxWithdraw` is owner-scoped: on a vault shared by two partitions it counts both
    ///      positions, so a non-zero cap must be clamped to each partition's own share value.
    function test_effectiveBalance_sharedVault_clampsToPartitionValue() public {
        MockSparkVault spark = new MockSparkVault(ERC20(address(token)));
        bytes32 partitionB = h.partitionOf(bytes32(uint256(0xBEEF)), currency);
        _bindVault(IERC4626(address(spark)));
        h.setVault(partitionB, IERC4626(address(spark)));

        _fundHarness(1_000e18);
        h.depositToVault(partition, currency, 600e18);
        h.depositToVault(partitionB, currency, 400e18);

        // Fully liquid: maxWithdraw(harness) reports the combined 1000, but each partition
        // must see only its own stake.
        assertEq(h.effectiveBalance(partition), 600e18, "partition A clamped to own value");
        assertEq(h.effectiveBalance(partitionB), 400e18, "partition B clamped to own value");

        // Partially deployed: idle 300 binds both partitions below their stake.
        spark.allocate(makeAddr("sparkAllocator"), 700e18);
        assertEq(h.effectiveBalance(partition), 300e18, "partition A capped at idle");
        assertEq(h.effectiveBalance(partitionB), 300e18, "partition B capped at idle");
    }

    /// @dev A vault whose `maxWithdraw` itself reverts (non-conformant; ERC-4626 forbids it)
    ///      degrades to the `previewRedeem` fallback instead of bricking the read.
    function test_effectiveBalance_maxWithdrawReverts_fallsBackToPreviewRedeem() public {
        _bindVault(IERC4626(address(vault)));
        _fundHarness(1_000e18);
        h.depositToVault(partition, currency, 1_000e18);

        vm.mockCallRevert(
            address(vault), abi.encodeWithSelector(IERC4626.maxWithdraw.selector, address(h)), "unsupported"
        );

        assertEq(h.effectiveBalance(partition), 1_000e18, "falls back to previewRedeem");
    }

    /// @dev Execution-path sanity for the sizing change: a withdrawal sized within the reported
    ///      effective balance clears SparkVault's idle-liquidity gate; one sized above it still
    ///      bubbles the vault's own revert (the optimistic-withdraw contract is unchanged).
    function test_withdrawFromVault_sparkVault_honorsIdleCap() public {
        MockSparkVault spark = new MockSparkVault(ERC20(address(token)));
        _bindVault(IERC4626(address(spark)));
        _fundHarness(1_000e18);
        h.depositToVault(partition, currency, 1_000e18);
        spark.allocate(makeAddr("sparkAllocator"), 600e18);

        uint256 effective = h.effectiveBalance(partition);
        assertEq(effective, 400e18, "sized to idle");

        h.withdrawFromVault(partition, effective);
        assertEq(h.erc20Of(partition), 400e18, "withdrawal within idle succeeds");

        vm.expectRevert("SparkVault/insufficient-liquidity");
        h.withdrawFromVault(partition, 1);
    }

    // ══════════════════════════════════════════════════════════
    //  InventoryLib.tryDepositAll
    // ══════════════════════════════════════════════════════════

    function test_tryDepositAll_noVault_isNoopOk() public {
        // No vault bound -> (0, true, "").
        _fundHarness(500);
        h.creditERC20(partition, currency, 500);
        (uint256 amount, bool ok, bytes memory reason) = h.tryDepositAll(partition);
        assertEq(amount, 0, "no-vault no-op reports zero amount");
        assertTrue(ok, "no-vault no-op is ok");
        assertEq(reason.length, 0, "no reason on no-op");
        assertEq(h.erc20Of(partition), 500, "raw untouched");
    }

    function test_tryDepositAll_zeroRaw_isNoopOk() public {
        // Vault bound but the partition holds no raw -> (0, true, "").
        _bindVault(IERC4626(address(vault)));
        (uint256 amount, bool ok, bytes memory reason) = h.tryDepositAll(partition);
        assertEq(amount, 0, "zero-raw no-op reports zero amount");
        assertTrue(ok, "zero-raw no-op is ok");
        assertEq(reason.length, 0, "no reason on no-op");
    }

    function test_tryDepositAll_success_sweepsRawIntoVault() public {
        // Bind a vault but stage raw ERC-20 directly (bypassing the vault) so tryDepositAll has a
        // raw balance to sweep. We do this by binding AFTER crediting raw.
        _fundHarness(1_000e18);
        h.creditERC20(partition, currency, 1_000e18); // no vault yet -> raw credit
        _bindVault(IERC4626(address(vault)));

        (uint256 amount, bool ok, bytes memory reason) = h.tryDepositAll(partition);
        assertEq(amount, 1_000e18, "swept the full raw balance");
        assertTrue(ok, "deposit succeeded");
        assertEq(reason.length, 0, "no reason on success");
        assertEq(h.erc20Of(partition), 0, "raw zeroed after sweep");
        assertGt(h.sharesOf(partition), 0, "shares credited");
    }

    function test_tryDepositAll_catchesRevertingVault() public {
        // VaultV2 armed to revert on deposit. tryDepositAll must catch and report ok=false with a
        // non-empty reason, leaving the raw balance intact for a later retry.
        MockMorphoVaultV2 vv2 = new MockMorphoVaultV2(ERC20(address(token)));
        _fundHarness(1_000e18);
        h.creditERC20(partition, currency, 1_000e18); // raw credit before binding
        _bindVault(IERC4626(address(vv2)));
        vv2.setDepositShortfall(true);

        (uint256 amount, bool ok, bytes memory reason) = h.tryDepositAll(partition);
        assertEq(amount, 1_000e18, "attempted the full raw balance");
        assertFalse(ok, "vault revert -> ok false");
        assertGt(reason.length, 0, "revert reason captured");
        assertEq(
            _selector(reason), MockMorphoVaultV2.DepositShortfall.selector, "reason is the vault's revert selector"
        );
        assertEq(h.erc20Of(partition), 1_000e18, "raw preserved on failed deposit");
        assertEq(h.sharesOf(partition), 0, "no shares minted on failure");
    }

    // ══════════════════════════════════════════════════════════
    //  InventoryLib.tryDrain
    // ══════════════════════════════════════════════════════════

    function test_tryDrain_noVault_earlyReturnsNotOk() public {
        // No vault configured -> (0, 0, false, ""). Note: unlike tryDepositAll, the no-vault path
        // returns ok=false (there is nothing to drain and no vault to drain from).
        (uint256 shares, uint256 assets, bool ok, bytes memory reason) = h.tryDrain(partition);
        assertEq(shares, 0, "no shares");
        assertEq(assets, 0, "no assets");
        assertFalse(ok, "no-vault drain is not ok");
        assertEq(reason.length, 0, "no reason");
    }

    function test_tryDrain_zeroShares_earlyReturnsNotOk() public {
        // Vault bound but no shares owned -> (0, 0, false, "").
        _bindVault(IERC4626(address(vault)));
        (uint256 shares, uint256 assets, bool ok, bytes memory reason) = h.tryDrain(partition);
        assertEq(shares, 0, "no shares");
        assertEq(assets, 0, "no assets");
        assertFalse(ok, "zero-shares drain is not ok");
        assertEq(reason.length, 0, "no reason");
    }

    function test_tryDrain_success_redeemsToRaw() public {
        _bindVault(IERC4626(address(vault)));
        _fundHarness(1_000e18);
        h.depositToVault(partition, currency, 1_000e18);
        uint256 sharesBefore = h.sharesOf(partition);
        assertGt(sharesBefore, 0, "shares present pre-drain");

        (uint256 shares, uint256 assets, bool ok, bytes memory reason) = h.tryDrain(partition);
        assertEq(shares, sharesBefore, "drained the partition's own shares");
        assertEq(assets, 1_000e18, "redeemed assets at 1:1");
        assertTrue(ok, "redeem succeeded");
        assertEq(reason.length, 0, "no reason on success");
        assertEq(h.sharesOf(partition), 0, "shares zeroed");
        assertEq(h.erc20Of(partition), 1_000e18, "assets credited to raw");
    }

    function test_tryDrain_catchesRevertingVault() public {
        // Deposit into a healthy VaultV2 first, then arm the withdraw/redeem shortfall so the
        // redeem reverts; tryDrain must catch it and preserve the shares.
        MockMorphoVaultV2 vv2 = new MockMorphoVaultV2(ERC20(address(token)));
        _bindVault(IERC4626(address(vv2)));
        _fundHarness(1_000e18);
        h.depositToVault(partition, currency, 1_000e18);
        uint256 sharesBefore = h.sharesOf(partition);

        vv2.setWithdrawShortfall(true); // redeem() reverts WithdrawShortfall

        (uint256 shares, uint256 assets, bool ok, bytes memory reason) = h.tryDrain(partition);
        assertEq(shares, sharesBefore, "drain operated on the partition's shares");
        assertEq(assets, 0, "no assets received on failure");
        assertFalse(ok, "vault revert -> ok false");
        assertGt(reason.length, 0, "revert reason captured");
        assertEq(
            _selector(reason), MockMorphoVaultV2.WithdrawShortfall.selector, "reason is the vault's revert selector"
        );
        assertEq(h.sharesOf(partition), sharesBefore, "shares preserved on failed drain");
    }

    // ══════════════════════════════════════════════════════════
    //  InventoryLib.requireFeelessVault
    // ══════════════════════════════════════════════════════════

    function test_requireFeelessVault_passesForZeroVault() public view {
        // address(0) vault is a no-op (raw-ERC20 partition).
        h.requireFeelessVault(IERC4626(address(0)));
    }

    function test_requireFeelessVault_passesForFeelessVault() public view {
        // Plain MockERC4626: previewDeposit == convertToShares and previewRedeem == convertToAssets.
        h.requireFeelessVault(IERC4626(address(vault)));
    }

    function test_requireFeelessVault_revertsOnEntryFee() public {
        MockMorphoVaultV2 vv2 = new MockMorphoVaultV2(ERC20(address(token)));
        vv2.setEntryFeeBps(100); // previewDeposit < convertToShares
        vm.expectRevert(InventoryLib.VaultChargesEntryFee.selector);
        h.requireFeelessVault(IERC4626(address(vv2)));
    }

    function test_requireFeelessVault_revertsOnExitFee() public {
        MockMorphoVaultV2 vv2 = new MockMorphoVaultV2(ERC20(address(token)));
        vv2.setExitFeeBps(100); // previewRedeem < convertToAssets, entry side clean
        vm.expectRevert(InventoryLib.VaultChargesExitFee.selector);
        h.requireFeelessVault(IERC4626(address(vv2)));
    }

    /// @dev A liquidity-gated `previewRedeem` (SparkVault with idle below the probe amount)
    ///      reverts as a liquidity report, not a fee disclosure. The exit-side probe is skipped
    ///      instead of bricking pool initialization.
    function test_requireFeelessVault_skipsExitProbe_whenPreviewRedeemReverts() public {
        MockSparkVault spark = new MockSparkVault(ERC20(address(token)));

        // Fresh vault: zero idle, so previewRedeem(probe) reverts.
        uint256 probe = 10 ** uint256(spark.decimals());
        vm.expectRevert("SparkVault/insufficient-liquidity");
        spark.previewRedeem(probe);

        h.requireFeelessVault(IERC4626(address(spark)));
    }

    /// @dev With idle liquidity covering the probe, SparkVault's previews run and pass the
    ///      feeless comparison normally.
    function test_requireFeelessVault_passesForLiquidSparkVault() public {
        MockSparkVault spark = new MockSparkVault(ERC20(address(token)));
        _bindVault(IERC4626(address(spark)));
        _fundHarness(5e18);
        h.depositToVault(partition, currency, 5e18);

        h.requireFeelessVault(IERC4626(address(spark)));
    }

    // ══════════════════════════════════════════════════════════
    //  InventoryLib.depositToVault / withdrawFromVault / ensureERC20 (supporting paths)
    // ══════════════════════════════════════════════════════════

    function test_depositToVault_noVault_creditsRaw() public {
        // No vault bound -> raw ERC-20 credit, no token movement required.
        h.depositToVault(partition, currency, 250e18);
        assertEq(h.erc20Of(partition), 250e18, "credited raw");
        assertEq(h.sharesOf(partition), 0, "no shares");
    }

    function test_depositToVault_zeroAmount_isNoop() public {
        _bindVault(IERC4626(address(vault)));
        h.depositToVault(partition, currency, 0);
        assertEq(h.sharesOf(partition), 0, "zero deposit mints nothing");
        assertEq(h.erc20Of(partition), 0, "zero deposit credits nothing");
    }

    function test_withdrawFromVault_noVault_isNoop() public {
        // No vault bound -> withdrawFromVault returns without touching state.
        _fundHarness(100e18);
        h.creditERC20(partition, currency, 100e18);
        h.withdrawFromVault(partition, 50e18);
        assertEq(h.erc20Of(partition), 100e18, "raw untouched, no vault to withdraw from");
    }

    function test_withdrawFromVault_zeroAmount_isNoop() public {
        _bindVault(IERC4626(address(vault)));
        _fundHarness(100e18);
        h.depositToVault(partition, currency, 100e18);
        uint256 sharesBefore = h.sharesOf(partition);
        h.withdrawFromVault(partition, 0);
        assertEq(h.sharesOf(partition), sharesBefore, "zero withdraw is a no-op");
    }

    function test_withdrawFromVault_movesVaultedToRaw() public {
        _bindVault(IERC4626(address(vault)));
        _fundHarness(100e18);
        h.depositToVault(partition, currency, 100e18);

        h.withdrawFromVault(partition, 40e18);
        assertEq(h.erc20Of(partition), 40e18, "withdrawn amount credited to raw");
        assertGt(h.sharesOf(partition), 0, "shares remain for the unwithdrawn portion");
    }

    function test_ensureERC20_sufficientRaw_debitsWithoutVault() public {
        // bal >= amount path: debit straight from raw.
        _fundHarness(100e18);
        h.creditERC20(partition, currency, 100e18);
        h.ensureERC20(partition, 60e18);
        assertEq(h.erc20Of(partition), 40e18, "raw debited, no vault touched");
    }

    function test_ensureERC20_zeroAmount_isNoop() public {
        _fundHarness(10e18);
        h.creditERC20(partition, currency, 10e18);
        h.ensureERC20(partition, 0);
        assertEq(h.erc20Of(partition), 10e18, "zero ensure is a no-op");
    }

    function test_ensureERC20_vaultedShortfall_withdrawsAndNetsToZero() public {
        // No raw, fully vaulted: ensuring `amount` withdraws exactly `amount` (bal == 0) and the
        // partition nets to zero (the documented literal-zero result).
        _bindVault(IERC4626(address(vault)));
        _fundHarness(100e18);
        h.depositToVault(partition, currency, 100e18);
        assertEq(h.erc20Of(partition), 0, "all vaulted, no raw");

        h.ensureERC20(partition, 30e18);
        assertEq(h.erc20Of(partition), 0, "partition nets to zero: withdrew exactly the shortfall, then debited it");
        assertGt(h.sharesOf(partition), 0, "remaining shares for the unspent 70");
    }
}
