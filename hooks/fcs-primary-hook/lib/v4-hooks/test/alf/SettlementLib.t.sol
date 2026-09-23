// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SettlementLib} from "../../src/alf/libraries/SettlementLib.sol";
import {Inventory, InsufficientPoolBalance} from "../../src/alf/types/Inventory.sol";

/// @dev Concrete consumer that drives `SettlementLib.resolveCurrency` directly, mirroring the way
///      `DualPoolHook._resolveNetDelta` calls it (single net-delta authority, one resolve per
///      currency, inside a `poolManager.unlock`). Internal library functions inline into this
///      contract, so `address(this)` and token custody resolve to the harness exactly as they
///      would resolve to the production hook.
///
///      Each test asks the harness to (1) manufacture a real v4 `currencyDelta` against the
///      PoolManager via a primitive (`take` for a debit, `settle` for a credit, or nothing for the
///      zero case), then (2) call `resolveCurrency`. Because v4 flash accounting requires every
///      delta to net to zero before the `unlock` returns, each `(manufacture, resolve)` pair is
///      constructed to leave the harness delta at exactly zero:
///        - DEBIT_ERC20 / DEBIT_NATIVE: `take(owed)` => delta -owed; `resolveCurrency` settles
///          `owed` => delta 0.
///        - CREDIT: overpay-settle of `+amt` => delta +amt; `resolveCurrency` mints `amt` claims,
///          which accounts -amt => delta 0.
///        - NONE: no manufacture; `resolveCurrency` is a no-op => delta 0.
contract SettlementLibHarness is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;

    enum Action {
        NONE, // delta == 0 no-op
        DEBIT_ERC20, // negative delta, ERC-20 currency
        DEBIT_NATIVE, // negative delta, native ETH (the DualPool-unreachable leg)
        CREDIT // positive delta -> mint claims
    }

    IPoolManager internal immutable _poolManager;
    Inventory internal _inv;

    /// @dev Net delta the harness observed for the resolved currency immediately AFTER
    ///      `resolveCurrency` ran, snapshotted so the test can assert the unlock closed clean.
    int256 public deltaAfterResolve;

    constructor(IPoolManager pm) {
        _poolManager = pm;
    }

    /// @dev Accept ETH so a native `take` can pay the harness, and so the test can fund the
    ///      harness for the `settle{value}` leg.
    receive() external payable {}

    // ───────────────────────── Inventory seeding (test setup only) ─────────────────────────

    /// @dev Seed the partition's raw ERC-20 ledger so the negative-delta path's `debitERC20` has
    ///      something to debit. This is the only writer of `state[partition].erc20` available to the
    ///      test without running a full LP deposit; it mirrors the post-condition of a deposit or a
    ///      claim redemption that leaves raw ERC-20 attributed to the partition.
    function seedPartitionERC20(bytes32 partition, uint256 amount) external {
        _inv.recordRawForTest(partition, amount);
    }

    function partitionERC20(bytes32 partition) external view returns (uint256) {
        return _inv.erc20Of(partition);
    }

    function partitionClaims(bytes32 partition) external view returns (uint256) {
        return _inv.claimsOf(partition);
    }

    function vaultSharesOf(bytes32 partition) external view returns (uint256) {
        return _inv.sharesOf(partition);
    }

    // ─────────────────────────────── Drive resolveCurrency ───────────────────────────────

    /// @dev Entry point: open an unlock, manufacture the requested delta, and resolve it. The
    ///      heavy lifting happens in {unlockCallback} because every delta-touching primitive
    ///      (`take`, `settle`, `mint`) is `onlyWhenUnlocked`.
    function run(Action action, bytes32 partition, Currency currency, uint256 amount) external {
        _poolManager.unlock(abi.encode(action, partition, currency, amount));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(_poolManager), "only PM");
        (Action action, bytes32 partition, Currency currency, uint256 amount) =
            abi.decode(data, (Action, bytes32, Currency, uint256));

        if (action == Action.DEBIT_ERC20 || action == Action.DEBIT_NATIVE) {
            // Pull `amount` out of the PoolManager. `take` accounts a NEGATIVE delta on the
            // harness (we now owe the PM `amount`), which is exactly the negative-delta branch.
            _poolManager.take(currency, address(this), amount);
        } else if (action == Action.CREDIT) {
            // Overpay the PoolManager `amount` with no offsetting swap, leaving a POSITIVE delta
            // (the PM owes us `amount`). This is the shape `afterSwap` leaves behind: a credit the
            // swapper has not settled, so `resolveCurrency` mints claims rather than `take`-ing.
            if (currency.isAddressZero()) {
                _poolManager.settle{value: amount}();
            } else {
                _poolManager.sync(currency);
                currency.transfer(address(_poolManager), amount);
                _poolManager.settle();
            }
        }
        // Action.NONE: manufacture nothing; the resolve below must be a clean no-op.

        SettlementLib.resolveCurrency(_inv, _poolManager, partition, currency);

        // Snapshot the post-resolve delta. For a correct resolve this is always 0; the unlock
        // would revert with CurrencyNotSettled otherwise, so a non-zero read here can only surface
        // if v4 ever stops requiring a clean close.
        deltaAfterResolve = _poolManager.currencyDelta(address(this), currency);
        return "";
    }
}

/// @dev `Inventory` exposes no public raw-ERC-20 writer (only `debitERC20`, which subtracts). The
///      negative-delta branch needs the partition pre-funded, so this library adds an internal
///      test-only credit that writes `state[partition].erc20` directly. It lives in a separate library
///      (not the harness) so it can attach to `Inventory storage` via `using ... for`.
library InventoryTestLib {
    function recordRawForTest(Inventory storage self, bytes32 partition, uint256 amount) internal {
        self.state[partition].erc20 = uint128(amount);
    }
}

using InventoryTestLib for Inventory;

/// @notice Direct branch-coverage suite for `SettlementLib.resolveCurrency`.
///
///         `DualPoolHook` rejects native-ETH pools, so the `currency.isAddressZero()` /
///         `settle{value}` leg of the negative-delta branch is dead through that hook and the
///         integration suites can never reach it (the review flagged this as the 40%-branch gap).
///         Driving the library through a purpose-built harness is the only way to exercise it, so
///         this suite manufactures each branch's delta in isolation against a real PoolManager.
contract SettlementLibTest is Test, Deployers {
    using CurrencyLibrary for Currency;

    SettlementLibHarness internal harness;

    MockERC20 internal token;
    Currency internal erc20Currency;
    Currency internal nativeCurrency;

    bytes32 internal constant PARTITION = keccak256("partition");

    function setUp() public {
        // Real PoolManager (+ routers) from the canonical v4 test deployer.
        deployFreshManagerAndRouters();

        token = new MockERC20("Token", "TKN", 18);
        erc20Currency = Currency.wrap(address(token));
        nativeCurrency = CurrencyLibrary.ADDRESS_ZERO;

        harness = new SettlementLibHarness(manager);
    }

    // ══════════════════════════════════════════════════════════
    //  Negative delta, ERC-20: settle to PM + debit partition
    // ══════════════════════════════════════════════════════════

    /// @notice A negative ERC-20 delta settles the owed amount to the PoolManager (sync, transfer,
    ///         settle) and debits the partition's raw ERC-20 ledger by the same amount.
    function test_resolveCurrency_negativeDelta_erc20_settlesAndDebits() public {
        uint256 owed = 100e18;

        // Give the PoolManager real reserves so the harness's `take` can transfer tokens out;
        // the harness then settles those same tokens straight back, netting the cycle to zero.
        token.mint(address(manager), owed);
        // The partition must already track `owed` of raw ERC-20 for `debitERC20` to succeed (the
        // ledger field is independent of the harness's actual token balance).
        harness.seedPartitionERC20(PARTITION, owed);

        uint256 pmBalBefore = token.balanceOf(address(manager));
        uint256 harnessBalBefore = token.balanceOf(address(harness));

        harness.run(SettlementLibHarness.Action.DEBIT_ERC20, PARTITION, erc20Currency, owed);

        // Partition ERC-20 ledger debited to zero.
        assertEq(harness.partitionERC20(PARTITION), 0, "partition raw ERC-20 debited by owed");
        // Claims untouched on the negative branch.
        assertEq(harness.partitionClaims(PARTITION), 0, "no claims on negative branch");
        // Conservation: the harness received `owed` via take and settled it straight back, so its
        // net token balance is unchanged across the cycle.
        assertEq(token.balanceOf(address(harness)), harnessBalBefore, "harness net token movement zero");
        // PM balance is conserved: it lent `owed` via take and received `owed` via settle.
        assertEq(token.balanceOf(address(manager)), pmBalBefore, "PM balance conserved");
        // Delta closed clean.
        assertEq(harness.deltaAfterResolve(), 0, "ERC-20 delta resolved to zero");
    }

    // ══════════════════════════════════════════════════════════
    //  Negative delta, NATIVE: settle{value} leg
    //  (dead-through-DualPoolHook — the flagged 40% branch)
    // ══════════════════════════════════════════════════════════

    /// @notice A negative NATIVE delta resolves through `settle{value: owed}()` — the
    ///         `currency.isAddressZero()` leg DualPoolHook can never reach because it rejects
    ///         native pools. The partition's raw ledger is debited identically to the ERC-20 leg.
    function test_resolveCurrency_negativeDelta_native_settlesWithValue() public {
        uint256 owed = 3 ether;

        // PoolManager needs ETH so the harness's `take` can hand it over; the harness needs ETH so
        // its `settle{value}` can pay it back. (In production the swapper funds the PM; here we
        // manufacture both sides.)
        vm.deal(address(manager), owed);
        vm.deal(address(harness), owed);
        harness.seedPartitionERC20(PARTITION, owed);

        uint256 harnessEthBefore = address(harness).balance;
        uint256 pmEthBefore = address(manager).balance;

        harness.run(SettlementLibHarness.Action.DEBIT_NATIVE, PARTITION, nativeCurrency, owed);

        assertEq(harness.partitionERC20(PARTITION), 0, "partition raw ledger debited by owed (native)");
        assertEq(harness.partitionClaims(PARTITION), 0, "no claims on negative native branch");
        // The harness received `owed` via take and paid `owed` via settle{value}; its balance is
        // conserved across the cycle, proving the value-bearing settle executed.
        assertEq(address(harness).balance, harnessEthBefore, "harness ETH conserved across take+settle");
        assertEq(address(manager).balance, pmEthBefore, "PM ETH conserved across take+settle");
        assertEq(harness.deltaAfterResolve(), 0, "native delta resolved to zero");
    }

    /// @notice The native branch reverts on a short partition exactly like the ERC-20 branch: the
    ///         `settle{value}` succeeds against the PM but `debitERC20` reverts
    ///         `InsufficientPoolBalance` because the partition ledger does not cover `owed`. Locks in
    ///         that the native leg shares the same per-partition solvency check.
    function test_resolveCurrency_negativeDelta_native_revertsWhenPartitionShort() public {
        uint256 owed = 2 ether;

        vm.deal(address(manager), owed);
        vm.deal(address(harness), owed);
        // Partition only tracks `owed - 1` -> debitERC20 must revert.
        harness.seedPartitionERC20(PARTITION, owed - 1);

        vm.expectRevert(InsufficientPoolBalance.selector);
        harness.run(SettlementLibHarness.Action.DEBIT_NATIVE, PARTITION, nativeCurrency, owed);
    }

    // ══════════════════════════════════════════════════════════
    //  Positive delta: mint ERC-6909 claims + record on partition
    // ══════════════════════════════════════════════════════════

    /// @notice A positive delta mints ERC-6909 claims to the harness (not `take`, since the
    ///         swapper's input is unsettled) and records them on the partition.
    function test_resolveCurrency_positiveDelta_mintsClaimsAndRecords() public {
        uint256 credit = 250e18;

        // Manufacture the positive delta by overpaying the PM: the harness transfers `credit` in
        // and settles, leaving the PM owing it back.
        token.mint(address(harness), credit);

        uint256 claimsBefore = harness.partitionClaims(PARTITION);
        uint256 pmClaimBalBefore = manager.balanceOf(address(harness), erc20Currency.toId());

        harness.run(SettlementLibHarness.Action.CREDIT, PARTITION, erc20Currency, credit);

        // ERC-6909 claims minted to the harness on the PoolManager.
        uint256 pmClaimBalAfter = manager.balanceOf(address(harness), erc20Currency.toId());
        assertEq(pmClaimBalAfter - pmClaimBalBefore, credit, "PM minted `credit` ERC-6909 claims to harness");
        // Partition claim ledger recorded the mint.
        assertEq(harness.partitionClaims(PARTITION) - claimsBefore, credit, "partition claims recorded");
        // No raw ERC-20 attributed; the positive branch never touches the raw ledger.
        assertEq(harness.partitionERC20(PARTITION), 0, "raw ledger untouched on positive branch");
        assertEq(harness.deltaAfterResolve(), 0, "positive delta resolved to zero (mint offsets it)");
    }

    // ══════════════════════════════════════════════════════════
    //  Zero delta: no-op
    // ══════════════════════════════════════════════════════════

    /// @notice `delta == 0` is a no-op: no settle, no mint, no partition mutation. Seed the partition
    ///         with raw + claims and assert both survive untouched.
    function test_resolveCurrency_zeroDelta_isNoOp() public {
        uint256 seededRaw = 42e18;
        harness.seedPartitionERC20(PARTITION, seededRaw);

        uint256 rawBefore = harness.partitionERC20(PARTITION);
        uint256 claimsBefore = harness.partitionClaims(PARTITION);
        uint256 sharesBefore = harness.vaultSharesOf(PARTITION);
        uint256 pmClaimBalBefore = manager.balanceOf(address(harness), erc20Currency.toId());
        uint256 harnessBalBefore = token.balanceOf(address(harness));

        // No delta manufactured; resolveCurrency reads delta == 0 and must touch nothing.
        harness.run(SettlementLibHarness.Action.NONE, PARTITION, erc20Currency, 0);

        assertEq(harness.partitionERC20(PARTITION), rawBefore, "raw ledger unchanged");
        assertEq(harness.partitionClaims(PARTITION), claimsBefore, "claims unchanged");
        assertEq(harness.vaultSharesOf(PARTITION), sharesBefore, "vault shares unchanged");
        assertEq(
            manager.balanceOf(address(harness), erc20Currency.toId()),
            pmClaimBalBefore,
            "no ERC-6909 minted on zero delta"
        );
        assertEq(token.balanceOf(address(harness)), harnessBalBefore, "no tokens moved on zero delta");
        assertEq(harness.deltaAfterResolve(), 0, "zero delta stays zero");
    }

    /// @notice The same zero-delta no-op holds for the native currency: nothing settles, no value
    ///         leaves the harness, and the partition is untouched.
    function test_resolveCurrency_zeroDelta_native_isNoOp() public {
        vm.deal(address(harness), 1 ether);
        harness.seedPartitionERC20(PARTITION, 7 ether);

        uint256 rawBefore = harness.partitionERC20(PARTITION);
        uint256 harnessEthBefore = address(harness).balance;

        harness.run(SettlementLibHarness.Action.NONE, PARTITION, nativeCurrency, 0);

        assertEq(harness.partitionERC20(PARTITION), rawBefore, "native zero-delta leaves partition untouched");
        assertEq(address(harness).balance, harnessEthBefore, "no ETH moved on native zero delta");
        assertEq(harness.deltaAfterResolve(), 0, "native zero delta stays zero");
    }
}
