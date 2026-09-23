// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {OwnedALFHook} from "./base/OwnedALFHook.sol";
import {PoolVault} from "./base/PoolVault.sol";
import {SettlementLib} from "./libraries/SettlementLib.sol";
import {FeeLib} from "./libraries/FeeLib.sol";
import {
    Distribution,
    LiquidityBucket,
    MAX_BUCKETS,
    computeAllocations,
    activeLiquidity
} from "./types/Distribution.sol";
import {ActiveLiquidity, activeLiquidityFor} from "./types/ActiveLiquidity.sol";
import {DepositGate} from "./types/DepositGate.sol";
import {JITLock, jitLockFor, requireJITNotInProgress} from "./types/JITLock.sol";

/// @title DualPoolHook
/// @author Uniswap Labs
/// @notice JIT quoter with ERC4626 vault rehypothecation and multi-range liquidity
///         distribution. Pricing is fully static: pool fees are set at deploy time via
///         `PoolKey.fee` and never change.
///
///         Assets are deployed across multiple tick ranges ("buckets") during each JIT cycle,
///         with owner-configured weights that control capital concentration. Token allocation
///         across buckets uses `getLiquidityForAmounts` at the current price so that no capital
///         sits idle, even when the price has drifted and ranges are asymmetric.
///
///         Example: 75% at [-10,10], 15% at [-30,30], 10% at [-60,60] concentrates most
///         liquidity around the peg while maintaining depth for larger price moves.
///
///         ## JIT Lifecycle
///
///           beforeSwap:
///             1. Set the JIT lock (blocks reentrant addLiquidity/removeLiquidity/setDistribution)
///             2. Compute per-bucket liquidity from current assets and weights
///             3. Compute exact token amounts needed via SqrtPriceMath
///             4. Redeem claims, withdraw only the shortfall from vaults
///             5. Deploy each bucket as a concentrated LP position
///
///           [pool executes swap against the deployed LP with fee override]
///
///           afterSwap:
///             1. Remove all bucket positions
///             2. Settle net deltas (negative → ERC-20 to PM, positive → mint claims),
///                debiting per-pool ERC-20 tracking on settle
///             3. Re-deposit remaining per-pool ERC-20 to vaults
///             4. Clear the JIT lock
///
///         ## Pricing
///
///         The pool's LP fee is read from `PoolKey.fee` and charged natively by v4 on every
///         swap. The fee is fixed at pool-creation time and cannot be changed afterwards. The
///         owner has only a per-pool liveness flag (`setPoolLive`) for emergency pause; the
///         hook intentionally ignores hookData on swaps.
///
///         ## Share Accounting
///
///         Inherited from PoolVault. Pools are seeded by the owner via `bootstrap`, which mints
///         `sqrt(amount0 * amount1)` shares (Uniswap V2 style). Inflation defense uses
///         EIP-4626 virtual-shares offsets in the conversion math (see PoolVault). After
///         bootstrap, anyone with deposit auth may call `addLiquidity` for proportional
///         shares. LPs hold proportional shares of the pool's total assets (vault shares +
///         claims + per-pool ERC-20).
///
///         ## Reentrancy
///
///         User-facing entry points (`bootstrap`, `addLiquidity`, `removeLiquidity`) carry the
///         OZ `nonReentrant` transient guard. PM-driven callbacks (`_beforeSwap`, `_afterSwap`)
///         are not eligible for that guard (no fresh entry point), so they manage the `JITLock`
///         transient slots and the LP entries reject calls (via `whenJITNotInProgress`) while a
///         cycle is in flight. This blocks an owner-configured ERC4626 vault from re-entering LP
///         entry points mid-JIT.
/// @custom:security-contact security@uniswap.org
contract DualPoolHook is OwnedALFHook, PoolVault, ReentrancyGuardTransient, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;
    using SafeCast for uint256;

    /// @notice Salt for the hook's LP positions in the PoolManager, distinguishing them
    ///         from positions created by other hooks or LPs on the same pool.
    bytes32 private constant LP_SALT = bytes32(uint256(0x4455414C)); // "DUAL"

    // ═══════════════════════════════════════════════════════════════════════════
    //                              TYPES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Configuration for initializing a new pool. Passed to `initializePool`.
    /// @param sqrtPriceX96         Initial sqrt price (Q64.96) for the v4 pool.
    /// @param distribution         Liquidity distribution buckets (weights must sum to 10_000).
    /// @param allowExternalDeposits Whether non-owner addresses may call `addLiquidity`.
    /// @param vault0               ERC4626 vault for currency0 (address(0) to hold as ERC-20).
    /// @param vault1               ERC4626 vault for currency1 (address(0) to hold as ERC-20).
    /// @param minDepositBlocks     Per-pool deposit lock duration. `0` (default) means no lock
    ///                             and same-block deposit-then-withdraw is allowed. Must be
    ///                             `<= maxMinDepositBlocks`. Immutable after `initializePool`.
    struct PoolConfig {
        uint160 sqrtPriceX96;
        LiquidityBucket[] distribution;
        bool allowExternalDeposits;
        IERC4626 vault0;
        IERC4626 vault1;
        uint64 minDepositBlocks;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              STATE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Per-pool gate for non-owner deposits, as a type-driven `DepositGate`. Set at
    ///      initialization via `initializePool`, toggled via `setExternalDeposits` /
    ///      `emergencyRevokeVault`, and read by `_requireDepositAuth`. Re-exposed through the
    ///      `externalDepositsEnabled` getter.
    DepositGate internal _depositGate;

    /// @dev Per-pool liquidity distribution (tick ranges and weights), as a type-driven
    ///      `Distribution`. Set at initialization via `initializePool`, updatable via
    ///      `setDistribution`, and read by the JIT cycle through `_distribution.get(poolId)`.
    Distribution internal _distribution;

    // ═══════════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Emitted when a new pool is initialized via `initializePool`.
    /// @param poolId The pool that was created.
    event PoolCreated(PoolId indexed poolId);

    /// @notice Emitted when the liquidity distribution is replaced via `setDistribution`.
    /// @param poolId The pool whose distribution was updated.
    event DistributionUpdated(PoolId indexed poolId);

    /// @notice Emitted when the owner triggers `emergencyRevokeVault`: the pool is paused,
    ///         external deposits are disabled, and both vault token allowances are zeroed in a
    ///         single action. A monitoring signal that a vault incident response is in progress.
    /// @param poolId The pool whose vault exposure was revoked.
    event EmergencyVaultRevoked(PoolId indexed poolId);

    // ═══════════════════════════════════════════════════════════════════════════
    //                              ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev External address attempted to add or remove v4 pool liquidity directly.
    ///      Only the hook itself may modify LP positions (during JIT cycles).
    error LiquidityNotAllowed();

    /// @dev The PoolKey's hooks address does not match this contract.
    error InvalidHookAddress();

    /// @dev Pool initialization rejected because one of the currencies is native ETH
    ///      (`address(0)`). PoolVault uses `IERC20.safeTransferFrom` which cannot operate on
    ///      `address(0)`, and the hook lacks a `receive() payable` function. Operators must
    ///      use a wrapped-ETH variant (e.g., WETH9) instead.
    error NativeNotSupported();

    /// @dev Configured ERC-4626 vault's `asset()` does not match the pool's currency. Vault
    ///      addresses are immutable post-init, so this fails fast instead of producing a
    ///      pool that silently mis-accounts.
    error VaultAssetMismatch();

    /// @dev `block.timestamp` exceeded the caller-supplied `deadline` for an LP operation.
    error DeadlineExpired();

    /// @dev `addLiquidity` would have transferred more than `maxAmount0`/`maxAmount1` from the
    ///      caller, or `removeLiquidity` would have transferred less than
    ///      `minAmount0`/`minAmount1` to the caller. Caller's slippage bounds were violated.
    error SlippageExceeded();

    /// @dev Caller is not authorized for this entry point. Used by `_requireDepositAuth`
    ///      and `_beforeInitialize`. Owner gating is handled by OZ Ownable's
    ///      `OwnableUnauthorizedAccount`.
    error Unauthorized();

    /// @dev Operator-supplied `PoolConfig.minDepositBlocks` exceeds the per-deployment upper
    ///      bound (`maxMinDepositBlocks`).
    /// @param supplied The value the operator provided in `PoolConfig`.
    /// @param max      The deployment-wide ceiling set at construction.
    error MinDepositBlocksTooLarge(uint64 supplied, uint64 max);

    /// @dev `unlockCallback` was invoked by an address other than the PoolManager. The callback
    ///      reads encoded arguments and triggers an LP withdraw; only the PoolManager (acting on
    ///      behalf of our own `poolManager.unlock` call) may invoke it.
    error UnauthorizedCallback();

    /// @dev `key.fee` carries the `LPFeeLibrary.DYNAMIC_FEE_FLAG` (0x800000). DualPool is
    ///      designed around a static fee fixed at pool creation; dynamic-fee pools would
    ///      require the hook to maintain its own fee state and route every swap through a
    ///      fee-update callback, which the contract is explicitly not built for. Use a
    ///      concrete `uint24` fee value below `MAX_LP_FEE` instead.
    error DynamicFeeNotSupported();

    // ═══════════════════════════════════════════════════════════════════════════
    //                              IMMUTABLES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Per-deployment upper bound on `PoolConfig.minDepositBlocks`, in
    ///         `BlockNumberish`-clock blocks. Set at construction so each chain deployment
    ///         can pick a chain-appropriate ceiling at deployment, immutable thereafter.
    uint64 public immutable maxMinDepositBlocks;

    /// @notice The contract that deployed this hook. Canonical deployments go through the
    ///         `AllowlistedFactory`, so aggregators and third-party routers can verify a hook's
    ///         provenance by checking `factory()` against the known factory address (or asking
    ///         the factory via `isFromFactory`) and can discover new hooks from the factory's
    ///         `Deployed` events. A hook deployed outside the factory reports whatever address
    ///         created it.
    address public immutable factory;

    // ═══════════════════════════════════════════════════════════════════════════
    //                              CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    /// @param _pm                 The Uniswap v4 PoolManager.
    /// @param maxGas_             Gas budget declared for `getIndicativeQuote` staticcalls.
    /// @param owner_              Initial contract owner. Transferable post-deployment via OZ
    ///                            `Ownable2Step` (`transferOwnership` + `acceptOwnership`);
    ///                            `renounceOwnership` is disabled (see {OwnedALFHook}). Key
    ///                            loss without a pending transfer is unrecoverable.
    /// @param _maxMinDepositBlocks Per-deployment upper bound on `PoolConfig.minDepositBlocks`.
    constructor(IPoolManager _pm, uint32 maxGas_, address owner_, uint64 _maxMinDepositBlocks)
        OwnedALFHook(_pm, maxGas_, owner_)
    {
        maxMinDepositBlocks = _maxMinDepositBlocks;
        factory = msg.sender;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Reverts {JITInProgress} if any pool served by this hook has a JIT cycle in flight.
    ///      Thin delegate over {requireJITNotInProgress}: the lock state and logic live in the
    ///      `JITLock` type, while the modifier keeps the guard visible in each entry point's
    ///      signature and hard to omit.
    modifier whenJITNotInProgress() {
        requireJITNotInProgress();
        _;
    }

    /// @dev Reverts {DeadlineExpired} if the caller-supplied `deadline` has passed. Hoisted out of
    ///      the LP entry points so the precondition stays visible in each signature.
    /// @dev Mixed-clock by design: deadlines compare against `block.timestamp` because they are
    ///      wall-clock UX bounds, whereas the deposit lock (`minDepositBlocks`) and rewards accrual
    ///      run on the block-based `BlockNumberish` clock as anti-MEV timing.
    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: POOL INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Initialize a new pool with vaults and liquidity distribution.
    /// @dev    Calls `poolManager.initialize` internally. The pool's LP fee is taken from
    ///         `key.fee` and is static: it cannot be changed post-deployment. The vault
    ///         binding is permanent (set at creation and cannot be changed), but the standing
    ///         token allowance granted to each vault is revocable in an emergency via
    ///         `emergencyRevokeVault`. The distribution can be updated later via
    ///         `setDistribution`.
    ///         Native ETH (currency `address(0)`) is rejected; wrap as WETH instead.
    ///         The pool is created not live: swaps revert with `PoolNotLive` until the
    ///         owner calls `bootstrap`, which mints the first shares and flips liveness on.
    ///         This closes the post-init, pre-bootstrap window in which a swapper could
    ///         shift `slot0.sqrtPriceX96` against a zero-liquidity pool. After bootstrap,
    ///         the owner can pause/unpause via `setPoolLive`.
    ///
    ///         `config.minDepositBlocks` is recorded once and immutable thereafter. Its unit
    ///         is defined as blocks; this works consistently across chains by way of the
    ///         `BlockNumberish` library which returns the L2 sequencer's local block number
    ///         on Arbitrum and `block.number` elsewhere. A value of `0` means no lock applies
    ///         and same-block deposit-then-withdraw is allowed; for a same-block ban set `1`.
    ///         Values above `maxMinDepositBlocks` are disallowed.
    /// @param key    The PoolKey (must reference this hook). `key.fee` is the static LP fee;
    ///               pools with the `LPFeeLibrary.DYNAMIC_FEE_FLAG` set are rejected.
    /// @param config Pool configuration including distribution, vaults, permissions, and
    ///               the deposit-lock duration.
    /// @return tick  The initial tick assigned by the PoolManager.
    function initializePool(PoolKey calldata key, PoolConfig calldata config) external onlyOwner returns (int24 tick) {
        if (key.hooks != IHooks(address(this))) revert InvalidHookAddress();
        if (key.currency0.isAddressZero() || key.currency1.isAddressZero()) revert NativeNotSupported();
        // DualPool enforces a static fee that is fixed at pool creation. Reject dynamic-fee
        // pools at init so the contract-level invariant ("pricing is fully static, set at
        // deploy time via PoolKey.fee") is enforced at the boundary instead of merely
        // documented. See contract-level NatSpec.
        if (key.fee.isDynamicFee()) revert DynamicFeeNotSupported();

        // Vaults are immutable per (pool, currency) post-init. Verify the configured ERC-4626
        // vault wraps the same underlying as the currency before storing; a mismatch would
        // otherwise brick bootstrap/deposit/swap silently or, worse, account shares against an
        // unexpected underlying.
        _requireVaultMatchesCurrency(config.vault0, key.currency0);
        _requireVaultMatchesCurrency(config.vault1, key.currency1);

        // Reject ERC-4626 vaults that apply entry/exit fees. Such vaults are structurally
        // incompatible with the JIT-cycle (per-swap round-trip drag) and with the
        // gross-balance share math (first-out-wins, last-out-loses). See PoolVault's
        // `Vault Compatibility` NatSpec for the full rationale.
        _requireFeelessVault(config.vault0);
        _requireFeelessVault(config.vault1);

        if (config.minDepositBlocks > maxMinDepositBlocks) {
            revert MinDepositBlocksTooLarge(config.minDepositBlocks, maxMinDepositBlocks);
        }

        PoolId poolId = key.toId();
        _depositGate.setOpen(poolId, config.allowExternalDeposits);
        _setVault(poolId, key.currency0, config.vault0);
        _setVault(poolId, key.currency1, config.vault1);
        minDepositBlocks[poolId] = config.minDepositBlocks;

        // Derive the virtual-shares offset from the pair's decimals so the bootstrap floor stays
        // a realistic seed for low-decimal pairs (e.g. ~100 USDC for a 6/6 pool instead of the
        // ~100M the hardcoded default would require). Immutable once set. See
        // {PoolVault._decimalsOffset}.
        _initDecimalsOffset(poolId, key.currency0, key.currency1);

        // Approve once at init time so JIT-cycle vault deposits can skip the runtime
        // allowance read. Allowance set to `type(uint256).max` is never decremented by
        // `vault.deposit`, so a single approval is durable for the (currency, vault) pair.
        // Vault-trust trade-off: see PoolVault `_depositToVault` NatSpec and K-05.
        _approveVault(key.currency0, address(config.vault0));
        _approveVault(key.currency1, address(config.vault1));

        _distribution.set(poolId, config.distribution, key.tickSpacing);

        tick = poolManager.initialize(key, config.sqrtPriceX96);
        // Pool starts not live: liveness is gated on `bootstrap` so the post-init,
        // pre-bootstrap window cannot be swapped through. Without this, a swap in that
        // window would deploy zero JIT liquidity yet may still shift slot0's
        // `sqrtPriceX96`, letting an attacker push the price away from the intended
        // bootstrap value before the owner's bootstrap transaction lands. `bootstrap` flips
        // liveness to true after the first deposit succeeds.
        emit PoolCreated(poolId);
        _onPoolInitialized(key);
    }

    /// @notice Seam fired at the end of {initializePool}, after the pool exists. Lets a derived
    ///         capability observe or veto a newly-initialized pool (e.g. to keep reward-token
    ///         custody disjoint from every pool currency). The base implementation is a no-op.
    /// @param key The pool that was just initialized.
    function _onPoolInitialized(PoolKey calldata key) internal virtual {}

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: LP DEPOSIT / WITHDRAW
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Seed a pool with the first deposit. Mints `sqrt(amount0 * amount1)` shares
    ///         to the owner and flips the pool to live, enabling swaps for the first time.
    /// @dev    Only the owner may bootstrap. The owner-supplied amounts set the initial
    ///         share/asset ratio, which is critical for asymmetric-decimal pairs (e.g.,
    ///         USDC/WETH) where a naïve 1-wei-of-each bootstrap would either be unaffordable
    ///         or set a meaningless price. Inflation defense is provided by virtual-shares
    ///         offsets in the conversion math (see {PoolVault._convertToAmounts}). Reverts
    ///         if the pool is already bootstrapped or if `sqrt(amount0 * amount1) == 0`.
    ///
    ///         Bootstrap is the sole trigger that flips a newly-initialized pool to live:
    ///         this closes the init→bootstrap window in which a swap could move slot0's
    ///         `sqrtPriceX96` against a zero-liquidity pool.
    /// @param key     The pool to bootstrap.
    /// @param amount0 Currency0 to deposit.
    /// @param amount1 Currency1 to deposit.
    /// @return shares Total shares minted, all credited to the owner.
    function bootstrap(PoolKey calldata key, uint256 amount0, uint256 amount1)
        external
        onlyOwner
        nonReentrant
        whenJITNotInProgress
        returns (uint256 shares)
    {
        shares = _bootstrap(key, msg.sender, msg.sender, amount0, amount1);
        // First successful bootstrap flips the pool to live. `_bootstrap` reverts on a
        // re-bootstrap attempt, so this branch fires exactly once per pool. The owner
        // can subsequently toggle liveness via `setPoolLive` (emergency pause).
        PoolId poolId = key.toId();
        _liveness.setLive(poolId, true);
    }

    /// @notice Deposit token0 and token1 proportional to the pool's current asset ratio.
    /// @dev    Requires owner or external deposits enabled. Pool must be bootstrapped first.
    ///         Records the depositor's deposit block; `removeLiquidity` reverts in the same
    ///         block to defend against atomic deposit-swap-withdraw fee/yield sniping.
    ///
    ///         Slippage bounds are enforced after the actual transfers so callers cap exposure
    ///         to swaps, vault share-price moves, or MEV between off-chain `previewDeposit` and
    ///         on-chain inclusion. `deadline` MUST be `>= block.timestamp` or the call reverts.
    ///         Use `type(uint256).max` for unbounded values, but production callers SHOULD set
    ///         tight bounds.
    /// @param key          The pool to deposit into.
    /// @param sharesToMint Number of shares to mint. Use `previewDeposit` to see required amounts.
    /// @param maxAmount0   Maximum currency0 the caller is willing to spend. Reverts if exceeded.
    /// @param maxAmount1   Maximum currency1 the caller is willing to spend. Reverts if exceeded.
    /// @param deadline     Unix timestamp after which the call reverts.
    /// @return amount0     Actual currency0 transferred from the caller.
    /// @return amount1     Actual currency1 transferred from the caller.
    function addLiquidity(
        PoolKey calldata key,
        uint256 sharesToMint,
        uint256 maxAmount0,
        uint256 maxAmount1,
        uint256 deadline
    ) external nonReentrant whenJITNotInProgress checkDeadline(deadline) returns (uint256 amount0, uint256 amount1) {
        _requireDepositAuth(key.toId());
        (amount0, amount1) = _deposit(key, msg.sender, msg.sender, sharesToMint);
        if (amount0 > maxAmount0 || amount1 > maxAmount1) revert SlippageExceeded();
    }

    /// @notice Burn shares and receive proportional token0 + token1.
    /// @dev    Amounts are rounded down to prevent over-withdrawal. Tokens are withdrawn
    ///         from vaults via `vault.withdraw` (exact assets) if the pool's tracked ERC-20
    ///         is insufficient. Reverts in the same block as the depositor's last deposit
    ///         (anti-fee-sniping).
    ///
    ///         Slippage bounds are enforced after the actual transfers so callers floor
    ///         received amounts against pool ratio moves between preview and inclusion.
    ///         `deadline` MUST be `>= block.timestamp` or the call reverts.
    /// @param key          The pool to withdraw from.
    /// @param sharesToBurn Number of shares to burn. Use `previewWithdraw` to see return amounts.
    /// @param minAmount0   Minimum currency0 the caller will accept. Reverts if not met.
    /// @param minAmount1   Minimum currency1 the caller will accept. Reverts if not met.
    /// @param deadline     Unix timestamp after which the call reverts.
    /// @return amount0     Actual currency0 transferred to the caller.
    /// @return amount1     Actual currency1 transferred to the caller.
    function removeLiquidity(
        PoolKey calldata key,
        uint256 sharesToBurn,
        uint256 minAmount0,
        uint256 minAmount1,
        uint256 deadline
    ) external nonReentrant whenJITNotInProgress checkDeadline(deadline) returns (uint256 amount0, uint256 amount1) {
        // Route through `poolManager.unlock` so the callback can redeem any pending ERC-6909
        // claims into `s.erc20` before the withdraw math runs. Between swaps,
        // `_depositAllToVaults` has swept `s.erc20` to 0 and `afterSwap` has minted positive
        // hook deltas as claims, so the LP's pro-rata `amount` (priced against
        // `s.erc20 + s.claims + vault`) cannot be sourced from `s.erc20` alone, and the vault
        // does not hold the claim portion; without pre-redeem, exits would brick or force an
        // unnecessary vault withdrawal that can itself revert on paused / illiquid vaults.
        bytes memory result = poolManager.unlock(abi.encode(key, msg.sender, sharesToBurn));
        (amount0, amount1) = abi.decode(result, (uint256, uint256));

        if (amount0 < minAmount0 || amount1 < minAmount1) revert SlippageExceeded();
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Only callable by the PoolManager as a re-entrant continuation of our own
    ///      `poolManager.unlock` call inside `removeLiquidity`. Anyone calling this directly
    ///      with crafted data could trigger an arbitrary LP withdraw, so the `msg.sender`
    ///      check is critical.
    ///
    ///      The encoded payload is `(PoolKey key, address owner, uint256 sharesToBurn)`. The
    ///      callback redeems both currencies' ERC-6909 claims first (cheap inside an unlock
    ///      context, satisfies the `s.erc20`-only inspection in `_ensureERC20`), then runs
    ///      `_withdraw` to mint payouts to `owner`.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert UnauthorizedCallback();

        (PoolKey memory key, address owner, uint256 sharesToBurn) = abi.decode(data, (PoolKey, address, uint256));
        PoolId poolId = key.toId();

        _redeemPoolClaims(poolId, key.currency0);
        _redeemPoolClaims(poolId, key.currency1);

        (uint256 amount0, uint256 amount1) = _withdraw(_vaultIdFor(poolId), owner, owner, sharesToBurn);
        return abi.encode(amount0, amount1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: OWNER CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Replace the liquidity distribution for a pool.
    /// @dev    Weights must sum to 10_000. Ticks must be aligned to tickSpacing.
    ///         Buckets can be asymmetric, overlapping, or non-contiguous.
    ///         Reverts during an active JIT cycle to prevent orphaning live LP positions.
    /// @param key     The pool to update.
    /// @param buckets The new distribution (1 to MAX_BUCKETS entries).
    function setDistribution(PoolKey calldata key, LiquidityBucket[] calldata buckets)
        external
        onlyOwner
        whenJITNotInProgress
    {
        _distribution.set(key.toId(), buckets, key.tickSpacing);
        emit DistributionUpdated(key.toId());
    }

    /// @notice Refresh the max-approval the hook grants to a pool's ERC-4626 vault.
    /// @dev    Recovery path for vaults whose allowance is unexpectedly consumed or reset.
    ///         `forceApprove` internally zeroes-then-sets for USDT-style tokens whose
    ///         `approve` reverts on a non-zero existing allowance, so a single call covers
    ///         both the well-behaved and the zero-out-first cases. No-op if the pool has no
    ///         vault configured for `currency`.
    /// @param key      The pool whose vault allowance should be refreshed.
    /// @param currency Which side (currency0 or currency1) to refresh.
    function refreshVaultApproval(PoolKey calldata key, Currency currency) external onlyOwner whenJITNotInProgress {
        _refreshVaultApproval(currency, address(_vaultOf(key.toId(), currency)));
    }

    /// @notice Emergency incident-response lever for a suspect vault: in one atomic action,
    ///         pause the pool, disable external deposits, zero both currencies' vault allowances,
    ///         and best-effort withdraw the pool's vault-held assets back into the hook. Use when
    ///         a configured vault is suspected compromised, paused, or pending a risky upgrade.
    /// @dev    The pool's vault binding is immutable, so this does not remove the vault. Four
    ///         actions run in order; the first three always succeed, the fourth is best-effort:
    ///
    ///           1. Pause (`livePools = false`): blocks swaps so the JIT cycle stops touching
    ///              the vault.
    ///           2. Disable external deposits: load-bearing, because `addLiquidity` is not gated
    ///              on liveness, so an external depositor could otherwise re-arm the allowance
    ///              via `_ensureVaultAllowance` on the deposit path even while the pool is paused.
    ///           3. Zero both vault allowances: removes the standing `type(uint256).max` grant
    ///              that lets a vault `transferFrom` the hook's raw balance of that currency
    ///              (including ERC-20 attributed to other pools sharing it; see {PoolVault}
    ///              `Vault trust model`).
    ///           4. Best-effort drain (`_drainVaultBestEffort`): redeems the pool's vault shares
    ///              back to raw ERC-20, rescuing assets already inside the vault, which step 3
    ///              alone does not protect. Wrapped in try/catch: if the vault is bricked/paused
    ///              and reverts on redeem, the rescue is skipped (emits {PoolVault-VaultDrainSkipped})
    ///              but the revocation + pause above still hold. `nonReentrant` because this is
    ///              the only owner path that makes an external call to the (untrusted) vault.
    ///
    ///         `removeLiquidity` is intentionally left open so LPs can still exit; it needs no
    ///         hook to vault allowance, so exits neither re-arm the exposure nor get trapped. To
    ///         resume normal operation the owner re-approves via {refreshVaultApproval} and
    ///         re-enables liveness / external deposits, which re-arms the exposure, so the
    ///         underlying vault incident must be resolved first.
    /// @param key The pool whose vault exposure to revoke.
    function emergencyRevokeVault(PoolKey calldata key) external onlyOwner nonReentrant whenJITNotInProgress {
        PoolId poolId = key.toId();

        _liveness.setLive(poolId, false);

        _depositGate.setOpen(poolId, false);

        _revokeVaultApproval(key.currency0, address(_vaultOf(poolId, key.currency0)));
        _revokeVaultApproval(key.currency1, address(_vaultOf(poolId, key.currency1)));

        // Rescue assets already inside the vault. Best-effort: a bricked vault must not block
        // the protections above.
        _drainVaultBestEffort(poolId, key.currency0);
        _drainVaultBestEffort(poolId, key.currency1);

        emit EmergencyVaultRevoked(poolId);
    }

    /// @notice Enable or disable external (non-owner) deposits for a pool.
    /// @param key     The pool to configure.
    /// @param enabled True to permit non-owner `addLiquidity`, false for owner-only.
    function setExternalDeposits(PoolKey calldata key, bool enabled) external onlyOwner whenJITNotInProgress {
        _depositGate.setOpen(key.toId(), enabled);
    }

    /// @notice Whether non-owner addresses may currently deposit into a pool.
    /// @param poolId The pool to read.
    /// @return Whether non-owner deposits are permitted.
    function externalDepositsEnabled(PoolId poolId) external view returns (bool) {
        return _depositGate.isOpen(poolId);
    }

    /// @notice Enable or disable pool liveness for emergency pause/resume.
    /// @dev    When toggled to false, `_beforeSwap` reverts with {PoolNotLive}, pausing the
    ///         pool for swaps. The static fee (`key.fee`) is unaffected; re-enabling
    ///         immediately restores trading at the original rate.
    /// @param key  The pool to toggle.
    /// @param live True to make swaps execute against JIT liquidity, false to pause the pool.
    function setPoolLive(PoolKey calldata key, bool live) external onlyOwner whenJITNotInProgress {
        _liveness.setLive(key.toId(), live);
    }

    /// @notice Total reserves managed by this hook for the given pool.
    /// @dev    Includes ERC-20, ERC-6909 claims, and ERC4626 vault balances.
    function getReserves(PoolKey calldata key) external view override returns (uint256 token0, uint256 token1) {
        return _totalAssets(key);
    }

    /// @notice Assets available for immediate swapping.
    /// @dev    Sizes vault-side balance via `vault.maxWithdraw(hook)` so the reported number
    ///         reflects what the hook can withdraw atomically right now, including any
    ///         idle-liquidity cap a gated vault (Spark savings vaults) enforces.
    ///         Curated/gated vaults that return `0` from `maxWithdraw` (Morpho VaultV2 and
    ///         similar) are sized via `previewRedeem` instead, the net realizable exit value
    ///         per share. See `InventoryLib.realizableVaultAssets`.
    function getEffectiveLiquidity(PoolKey calldata key)
        external
        view
        override
        returns (uint256 token0, uint256 token1)
    {
        return _effectiveAssets(key);
    }

    /// @notice Indicative quote against hypothetical DualPool JIT liquidity.
    /// @dev    Uses current active distribution-bucket liquidity for a compact view quote.
    ///         Ignores hookData; pricing is the static `key.fee`.
    ///
    ///         The estimate is a single constant-liquidity `computeSwapStep` (see
    ///         `_simulateIndicative`): it extrapolates the in-range bucket depth toward the
    ///         price limit, so for a swap large enough to exhaust the deployed buckets in a real
    ///         JIT cycle the raw step would report far more output than the pool holds (it can
    ///         exceed reserves several times over). `_simulateIndicative` therefore caps the
    ///         output leg at the effective output reserve. For exact output this returns 0 when
    ///         the requested output exceeds what the pool can deliver, since there is no honest
    ///         fill to price. The result stays an upper bound fit for ranking, not a precise
    ///         execution prediction; binding slippage protection belongs in the caller/router.
    function getIndicativeQuote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bytes calldata)
        external
        view
        override
        returns (uint256 outputAmount)
    {
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        (uint256 amountIn, uint256 amountOut) = _simulateIndicative(key, zeroForOne, amountSpecified, limit);
        if (amountSpecified < 0) {
            // Exact input: expected output, already capped at the deliverable reserve.
            outputAmount = amountOut;
        } else {
            // Exact output: required input. `_simulateIndicative` caps `amountOut` at the
            // deliverable reserve, so `amountOut < amountSpecified` means the pool cannot honor
            // the requested output. Return 0 (no quote) instead of an input figure priced for an
            // unachievable fill.
            outputAmount = amountOut >= uint256(amountSpecified) ? amountIn : 0;
        }
    }

    /// @notice Simulate a price-bounded swap against hypothetical JIT liquidity.
    /// @dev Returns both legs of the fill. When the swap would exhaust the deployable output
    ///      reserve, both legs are recomputed as the exact-output cost of draining that reserve, so
    ///      the returned (amountIn, amountOut) pair is always internally consistent: amountIn prices
    ///      exactly amountOut. The result is non-binding; binding slippage protection belongs in the
    ///      caller. See `_simulateIndicative`.
    function swapToPrice(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata
    ) external view override returns (uint256 amountIn, uint256 amountOut) {
        return _simulateIndicative(key, zeroForOne, amountSpecified, sqrtPriceLimitX96);
    }

    /// @notice Returns the share balance of `user` for the given pool.
    /// @param key  The pool whose share balance to read.
    /// @param user The address whose shares to look up.
    /// @return The number of pool shares held by `user`.
    function sharesOf(PoolKey calldata key, address user) external view returns (uint256) {
        return _shares.balanceOf(_vaultIdFor(key.toId()), user);
    }

    /// @notice Returns the current liquidity distribution for a pool.
    /// @param poolId The pool to query.
    /// @return The active list of liquidity buckets (tick ranges + weights).
    function getDistribution(PoolId poolId) external view returns (LiquidityBucket[] memory) {
        return _distribution.get(poolId);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        PUBLIC: HOOK PERMISSIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Required v4 hook flags:
    ///      - beforeInitialize: block direct init (force initializePool)
    ///      - beforeAddLiquidity / beforeRemoveLiquidity: restrict to hook-only LP
    ///      - beforeSwap: JIT deployment + fee override
    ///      - afterSwap: JIT teardown + delta resolution
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INTERNAL: HOOK CALLBACKS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev External LP additions are blocked. v4-core's `Hooks.noSelfCall` skips the hook
    ///      callback entirely when the hook itself is the caller, so the only path that
    ///      reaches this body is an external `modifyLiquidity` call, which is always rejected.
    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert LiquidityNotAllowed();
    }

    /// @dev External LP removals are blocked. Same `noSelfCall` reasoning as `_beforeAddLiquidity`.
    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert LiquidityNotAllowed();
    }

    /// @dev JIT entry point. Deploys multi-range JIT liquidity under the JIT lock. v4 charges
    ///      the static `key.fee` on the in-flight swap natively; no override is returned.
    ///
    ///      Reverts when the pool is paused (`!live`). Routers and aggregators see an explicit
    ///      failure instead of the swap running against zero deployed liquidity; the
    ///      multiplexer's per-target try/catch already handles the revert. hookData is
    ///      ignored entirely (see contract-level NatSpec).
    ///
    ///      A reentrant `_beforeSwap` on the same pool (e.g., from a malicious vault calling
    ///      `poolManager.swap(samePool)` during `_withdrawFromVault`) would corrupt the JIT
    ///      lifecycle: the inner cycle's `clear` would zero the per-pool slot while the outer
    ///      cycle is still in flight, so the outer `_afterSwap` would short-circuit and leave
    ///      the outer's deployed positions orphaned. {JITLock.enter} rejects it up-front.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        _liveness.requireLive(poolId);

        jitLockFor(poolId).enter();
        _deployJIT(poolId, key);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev JIT teardown. Removes all bucket positions, resolves the hook's net delta for both
    ///      currencies (debiting per-pool ERC-20 on settle), re-deposits remaining ERC-20 to
    ///      vaults, and clears the JIT lock. `_beforeSwap` always sets the lock when the pool
    ///      is live and reverts when it isn't, so reaching `_afterSwap` implies the lock is
    ///      set; a defensive lock read is unnecessary.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        _removeJIT(poolId, key);
        _resolveNetDelta(poolId, key);
        _depositAllToVaults(poolId, key);
        jitLockFor(poolId).clear();
        return (IHooks.afterSwap.selector, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INTERNAL: JIT LIFECYCLE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Deploy JIT liquidity across all distribution buckets.
    ///
    ///      Three-phase strategy:
    ///        1. **Compute allocations**: for each bucket, compute its weighted liquidity
    ///           from the full balance via `getLiquidityForAmounts`, then use `SqrtPriceMath`
    ///           to determine the exact token0 and token1 needed for deployment.
    ///        2. **Targeted withdrawal**: redeem per-pool ERC-6909 claims first (cheaper
    ///           than vault interaction), then withdraw only the shortfall from vaults.
    ///           Unneeded capital stays in the vault earning yield during the swap window.
    ///           Phase 2 reads the pool's `_erc20[poolId][currency]` tracker rather than the
    ///           hook's global `IERC20.balanceOf`, preserving cross-pool isolation when the
    ///           hook serves multiple pools sharing a currency.
    ///        3. **Deploy**: add each bucket as a concentrated LP position.
    ///
    /// @param poolId The pool to deploy for.
    /// @param key    The pool key (for currency references and modifyLiquidity calls).
    function _deployJIT(PoolId poolId, PoolKey calldata key) internal {
        // Use the cap-aware view: vaults that report more assets via `convertToAssets` than they
        // can satisfy via `withdraw` (paused, capped, utilization-constrained) would otherwise
        // produce `liqs[]` and `totalNeed{0,1}` sized above what `_withdrawFromVault` can deliver,
        // and the `_deployBuckets` settle would revert mid-cycle. Sizing against `_effectiveAssets`
        // matches both `getEffectiveLiquidity` (the routing/aggregator view) and what the JIT
        // cycle can actually pay for at deploy time. Share math (`_convertToAmounts`) deliberately
        // continues to use `_totalAssets` to ensure that LP pro-rata claims are over true economic
        // stake, not the momentarily-withdrawable subset of that stake.
        (uint256 bal0, uint256 bal1) = _effectiveAssets(poolId, key.currency0, key.currency1);
        // Exclude claims the PoolManager cannot physically honor yet (their backing settle is
        // still pending in this transaction, e.g. a prior same-pool swap within one unlock).
        // `_redeemPoolClaims` can only redeem the backed portion, and the vault does not hold
        // the claim portion, so sizing the deployment against unbacked claims would over-draw
        // the vault and revert. In steady state these are zero, so sizing is unchanged.
        bal0 -= _unbackedClaims(poolId, key.currency0);
        bal1 -= _unbackedClaims(poolId, key.currency1);
        if (bal0 == 0 && bal1 == 0) return;

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        LiquidityBucket[] memory buckets = _distribution.get(poolId);
        if (buckets.length == 0) return;

        // Phase 1: compute per-bucket liquidity and the total token amounts the deployment needs.
        (uint128[MAX_BUCKETS] memory liqs, uint256 totalNeed0, uint256 totalNeed1) =
            computeAllocations(buckets, sqrtPriceX96, bal0, bal1);

        if (totalNeed0 == 0 && totalNeed1 == 0) return;

        // Phase 2: liquidate claims (cheap), then pull only the shortfall from vault.
        // `_redeemPoolClaims` returns the post-redeem per-pool ERC-20 balance so we avoid a
        // follow-up SLOAD. Per-pool tracking, not the hook's global balance, preserves
        // cross-pool isolation.
        uint256 onHand0 = _redeemPoolClaims(poolId, key.currency0);
        uint256 onHand1 = _redeemPoolClaims(poolId, key.currency1);
        if (totalNeed0 > onHand0) _withdrawFromVault(poolId, key.currency0, totalNeed0 - onHand0);
        if (totalNeed1 > onHand1) _withdrawFromVault(poolId, key.currency1, totalNeed1 - onHand1);

        // Phase 3: deploy each bucket.
        _deployBuckets(poolId, key, buckets, liqs);
    }

    /// @dev Deploy each bucket's LP position. Separated from _deployJIT for stack depth.
    ///      Records each deployed liquidity value in the pool's `ActiveLiquidity` transient slots
    ///      so `_removeJIT` can size its inverse `modifyLiquidity` call without a storage SLOAD.
    function _deployBuckets(
        PoolId poolId,
        PoolKey calldata key,
        LiquidityBucket[] memory buckets,
        uint128[MAX_BUCKETS] memory liqs
    ) private {
        ActiveLiquidity slots = activeLiquidityFor(poolId);
        uint256 n = buckets.length;
        for (uint256 i; i < n; ++i) {
            uint128 liq = liqs[i];
            if (liq > 0) {
                LiquidityBucket memory bucket = buckets[i];
                poolManager.modifyLiquidity(
                    key,
                    ModifyLiquidityParams({
                        tickLower: bucket.tickLower,
                        tickUpper: bucket.tickUpper,
                        liquidityDelta: int256(uint256(liq)),
                        salt: LP_SALT
                    }),
                    ""
                );
                slots.store(i, liq);
            }
        }
    }

    /// @dev Remove all active JIT positions deployed in `_deployJIT`. Iterates the distribution
    ///      and removes each bucket that has non-zero active liquidity, reading it via
    ///      `ActiveLiquidity.takeAndClear` (which zeroes the slot on read so a later same-tx swap
    ///      on this pool does not see a stale value; see {ActiveLiquidity}). After removal, the
    ///      hook's cumulative delta reflects the net position from the deploy-swap-remove cycle.
    /// @param poolId The pool to remove JIT positions from.
    /// @param key    The pool key (for modifyLiquidity calls).
    function _removeJIT(PoolId poolId, PoolKey calldata key) internal {
        LiquidityBucket[] memory buckets = _distribution.get(poolId);
        uint256 n = buckets.length;
        ActiveLiquidity slots = activeLiquidityFor(poolId);

        for (uint256 i; i < n; ++i) {
            uint128 liq = slots.takeAndClear(i);
            if (liq > 0) {
                LiquidityBucket memory bucket = buckets[i];
                poolManager.modifyLiquidity(
                    key,
                    ModifyLiquidityParams({
                        tickLower: bucket.tickLower,
                        tickUpper: bucket.tickUpper,
                        liquidityDelta: -int256(uint256(liq)),
                        salt: LP_SALT
                    }),
                    ""
                );
            }
        }
    }

    /// @dev Resolve the hook's net delta for both currencies after the JIT cycle via the single
    ///      `SettlementLib` authority. Negative delta (hook owes PM): settle from the pool's raw
    ///      ERC-20 and debit its inventory partition. Positive delta (PM owes hook): mint ERC-6909
    ///      claims (cannot `take` because the swapper hasn't settled yet), recorded on the
    ///      partition and redeemed in the next `_deployJIT`.
    /// @param poolId The pool to resolve deltas for (used for inventory-partition derivation).
    /// @param key    The pool key (for currency references).
    function _resolveNetDelta(PoolId poolId, PoolKey calldata key) internal {
        SettlementLib.resolveCurrency(_inventory, poolManager, _partition(poolId, key.currency0), key.currency0);
        SettlementLib.resolveCurrency(_inventory, poolManager, _partition(poolId, key.currency1), key.currency1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INTERNAL: PRICING
    // ═══════════════════════════════════════════════════════════════════════════

    function _simulateIndicative(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96
    ) internal view returns (uint256 amountIn, uint256 amountOut) {
        PoolId poolId = key.toId();

        if (!_liveness.isLive(poolId)) return (0, 0);
        uint24 feePips = key.fee;

        // Use vault-cap-aware balances for indicative quotes. Execution caps vault
        // withdrawals at `_effectiveAssets`, so quoting against the uncapped `_totalAssets`
        // produces an indicative the JIT cycle cannot honour when the vault is paused
        // or utilization-constrained. Share math (`_convertToAmounts`) deliberately uses
        // `_totalAssets` (uncapped) so LP pro-rata claims are not capped.
        (uint256 bal0, uint256 bal1) = _effectiveAssets(poolId, key.currency0, key.currency1);
        if (bal0 == 0 && bal1 == 0) return (0, 0);

        uint160 sqrtPriceX96;
        int24 currentTick;
        {
            uint24 protocolFee;
            (sqrtPriceX96, currentTick, protocolFee,) = poolManager.getSlot0(poolId);
            if (sqrtPriceX96 == 0) return (0, 0);
            feePips = FeeLib.effectiveSwapFee(feePips, protocolFee, zeroForOne);
        }

        uint128 liquidity = activeLiquidity(_distribution.get(poolId), sqrtPriceX96, currentTick, bal0, bal1);
        if (liquidity == 0 || amountSpecified == 0) return (0, 0);

        (, uint256 stepIn, uint256 stepOut, uint256 feeAmount) =
            SwapMath.computeSwapStep(sqrtPriceX96, sqrtPriceLimitX96, liquidity, amountSpecified, feePips);
        amountIn = stepIn + feeAmount;
        amountOut = stepOut;

        // Physical-capacity bound. `computeSwapStep` treats the current in-range bucket depth as a
        // constant-liquidity curve extending all the way to `sqrtPriceLimitX96`, so for a swap large
        // enough to exhaust the deployed buckets it overstates output and can exceed reserves several
        // times over. The pool can deliver at most the effective output reserve (`bal0`/`bal1` are the
        // effective, immediately-redeemable balances read above), so when the raw step exceeds it the
        // reserve, not the price limit or the specified amount, is the binding constraint. Recompute
        // both legs as the exact-output cost of draining `outReserve` along the same curve so the
        // returned (amountIn, amountOut) pair stays internally consistent: the input is priced for
        // output the pool can actually deliver, never an over-claimed constant-liquidity step. Since
        // `outReserve < stepOut` is reachable toward the limit, the exact-output step is fully
        // satisfied before the price extreme, so the recomputed pair is exact.
        uint256 outReserve = zeroForOne ? bal1 : bal0;
        if (amountOut > outReserve) {
            uint160 drainLimit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
            (, uint256 drainIn,, uint256 drainFee) =
                SwapMath.computeSwapStep(sqrtPriceX96, drainLimit, liquidity, outReserve.toInt256(), feePips);
            amountIn = drainIn + drainFee;
            amountOut = outReserve;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INTERNAL: AUTH & POOL MANAGER
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Revert unless the caller is the owner or external deposits are enabled for the pool.
    /// @param poolId The pool to check authorization for.
    function _requireDepositAuth(PoolId poolId) internal view {
        if (msg.sender == owner()) return;
        if (_depositGate.isOpen(poolId)) return;
        revert Unauthorized();
    }

    /// @dev Verify that the ERC-4626 vault's `asset()` matches the pool's currency. Skipped
    ///      for `address(0)` (no vault; currency held as raw ERC-20). Called only at
    ///      `initializePool` since the vault address is immutable thereafter.
    function _requireVaultMatchesCurrency(IERC4626 vault, Currency currency) internal view {
        if (address(vault) == address(0)) return;
        if (vault.asset() != Currency.unwrap(currency)) revert VaultAssetMismatch();
    }

    /// @dev Provides PoolVault access to the PoolManager for claim operations (burn/take).
    function _poolManager() internal view override returns (IPoolManager) {
        return poolManager;
    }
}
