// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Libraries
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BinMath} from "./libraries/BinMath.sol";

// Types
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BookConfig, PoolConfig} from "./types/BookConfig.sol";
import {MakerInventory} from "./types/MakerInventory.sol";
import {
    BookPositions,
    PositionInfo,
    Side,
    positionId as derivePositionId,
    positionSalt,
    isRetirable
} from "./types/BookPositions.sol";
import {
    BinCapacity,
    InvalidBinOffset,
    validOffset,
    validateDistinctOffsets,
    replaceLadderStructHash,
    cancelLadderStructHash
} from "./types/Ladder.sol";
import {jitLockFor, requireJITNotInProgress} from "./types/JITLock.sol";

// Interfaces
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IALFHook} from "./interfaces/IALFHook.sol";
import {INativeBookQuoterSource} from "./interfaces/INativeBookQuoterSource.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Contracts
import {OwnedALFHook} from "./base/OwnedALFHook.sol";
import {NativeBookQuoter} from "./NativeBookQuoter.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @title NativeBookHook
/// @author Uniswap Labs
/// @notice Maker-facing quote ladders backed by native Uniswap v4 liquidity.
/// @dev Makers express bids/asks as bounded capacity in canonical bins. The hook owns the
///      underlying v4 positions, keyed by maker-specific salts, so swaps execute through the
///      native v4 swap loop while the hook enforces quote-ladder shape and one-shot expiry.
///
///      The contract is a thin shell over type-driven capabilities: `BookConfig` (per-pool
///      parameters), `MakerInventory` (maker custody), `BookPositions` (the position registry
///      and retirement cursor), `Ladder` (order shape and EIP-712 hashing), and `BinMath`
///      (bin geometry), with `Liveness` and the metadata/settlement surface inherited from
///      {OwnedALFHook}. The shell wires `msg.sender`, emits events, enforces access control,
///      and drives the PoolManager; domain logic lives in the types.
///
///      ## Reentrancy
///
///      User-facing entry points carry the OZ `nonReentrant` transient guard plus
///      `whenJITNotInProgress`. `_beforeSwap` (no fresh entry point, so ineligible for the OZ
///      guard) wraps its bounded retirement scan in the per-pool `JITLock`: the scan settles
///      each retired bin against the PoolManager via `_take`/`_settle` on the pool currencies, so
///      a callback-capable (e.g. ERC-777) currency could reenter, and the lock stops such a token
///      callback from reentering the LP/inventory entry points or the same pool's swap path
///      mid-scan. Maker value never leaves during the scan: it is credited to the internal
///      `MakerInventory` ledger, and the only transfer to an arbitrary address is `withdraw`.
/// @custom:security-contact security@uniswap.org
contract NativeBookHook is OwnedALFHook, ReentrancyGuardTransient, EIP712, Nonces, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    // ═══════════════════════════════════════════════════════════════════════════
    //                              TYPES
    // ═══════════════════════════════════════════════════════════════════════════

    enum UnlockAction {
        ReplaceLadder,
        CancelLadder,
        RetirePosition,
        RetirePositions,
        ClaimFees
    }

    struct ReplaceCallbackData {
        address submitter;
        address maker;
        PoolKey key;
        BinCapacity[] bids;
        BinCapacity[] asks;
        uint40 expiry;
        int24 expectedRefTick;
        uint24 maxTickDeviation;
        uint256 nonce;
        uint256 deadline;
        bool viaSignature;
    }

    struct CancelCallbackData {
        address submitter;
        address maker;
        PoolKey key;
        uint256 nonce;
        uint256 deadline;
        bool viaSignature;
    }

    struct RetireCallbackData {
        address caller;
        PoolKey key;
        bytes32 positionId;
    }

    struct RetirePositionsCallbackData {
        address caller;
        PoolKey key;
        bytes32[] positionIds;
        uint256 maxRetire;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              STATE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice External quote helper backing the IALFHook view surface.
    NativeBookQuoter public immutable quoter;

    /// @dev Per-pool canonical book configuration, as a type-driven `BookConfig`. Set once in
    ///      `initializePool`, read on the ladder and swap paths.
    BookConfig internal _config;

    /// @dev Maker-scoped custody ledger, as a type-driven `MakerInventory`. Funded via
    ///      `deposit`/`depositFor`, consumed when bins post, credited by removals and fees.
    MakerInventory internal _makerInventory;

    /// @dev The position registry, as a type-driven `BookPositions`: metadata by id plus the
    ///      maker and pool indexes and the bounded-retirement cursor.
    BookPositions internal _book;

    // ═══════════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    event PoolCreated(
        PoolId indexed poolId,
        address indexed creator,
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        uint160 sqrtPriceX96,
        int24 tick,
        PoolConfig config
    );
    event InventoryDeposited(
        address indexed maker,
        address indexed currency,
        address indexed depositor,
        uint256 requestedAmount,
        uint256 amount
    );
    event InventoryWithdrawn(
        address indexed maker, address indexed currency, address indexed recipient, uint256 amount
    );
    event LadderReplaced(
        PoolId indexed poolId,
        address indexed maker,
        address indexed submitter,
        uint256 bidCount,
        uint256 askCount,
        uint40 expiry,
        uint256 nonce,
        uint256 deadline,
        bool viaSignature
    );
    event LadderCanceled(
        PoolId indexed poolId,
        address indexed maker,
        address indexed submitter,
        uint256 binsRemoved,
        uint256 amount0,
        uint256 amount1,
        uint256 nonce,
        uint256 deadline,
        bool viaSignature
    );
    event BinPosted(
        PoolId indexed poolId,
        address indexed maker,
        bytes32 indexed positionId,
        Side side,
        int24 tickLower,
        int24 tickUpper,
        int8 offset,
        uint128 capacity,
        uint128 liquidity,
        uint40 expiry
    );
    event BinRetired(
        PoolId indexed poolId,
        address indexed maker,
        bytes32 indexed positionId,
        Side side,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );
    event FeesClaimed(
        PoolId indexed poolId,
        address indexed maker,
        bytes32 indexed positionId,
        address caller,
        uint256 amount0,
        uint256 amount1
    );
    event PositionsRetired(
        PoolId indexed poolId, address indexed caller, uint256 candidateCount, uint256 maxRetire, uint256 retired
    );

    // ═══════════════════════════════════════════════════════════════════════════
    //                              ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev `unlockCallback` was invoked by an address other than the PoolManager.
    error CallbackOnlyPoolManager();
    /// @dev The PoolKey's hooks address does not match this contract.
    error InvalidHookAddress();
    /// @dev Native ETH (`address(0)`) is unsupported: maker payments are pulled from arbitrary
    ///      maker addresses during PoolManager settlement, which has no native-value path.
    error InvalidNativeCurrency();
    /// @dev Ladder TTL is zero, exceeds the pool's `maxQuoteTtl`, or outlives the signature
    ///      deadline; or the ladder's bin count exceeds the pool's `maxMakerBins`.
    error InvalidQuoteTtl();
    /// @dev A posted bin's computed v4 liquidity is below the pool's `minBinLiquidity` floor.
    error InvalidBinLiquidity();
    /// @dev The EIP-712 signature deadline has passed.
    error SignatureExpired();
    /// @dev The EIP-712 signature does not recover to the maker.
    error InvalidSignature();
    /// @dev The position id does not reference an active position in the supplied pool.
    error InvalidPosition();
    /// @dev The maker address is zero.
    error InvalidMaker();
    /// @dev The withdrawal recipient address is zero.
    error InvalidRecipient();
    /// @dev A zero amount was supplied where a positive amount is required, or a deposit
    ///      credited nothing after transfer accounting.
    error ZeroAmount();
    /// @dev The ladder's total bin count exceeds the pool's `maxMakerBins`.
    error TooManyBins();
    /// @dev `retirePosition` targeted a position that is neither expired nor crossed.
    error PositionNotRetirable();
    /// @dev External LP tried to mint a position exactly one bin wide. That range is reserved
    ///      for the book so third-party positions cannot masquerade as maker bins.
    error ReservedBookRange();
    /// @dev Keeper batch candidates are capped by `maxRetire` so caller-paid scan work is explicit.
    error TooManyRetireCandidates(uint256 candidates, uint256 maxRetire);

    // ═══════════════════════════════════════════════════════════════════════════
    //                              MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Reverts {JITInProgress} while `_beforeSwap`'s retirement scan is in flight anywhere
    ///      in the hook. Blocks maker-token callbacks from reentering inventory and ladder entry
    ///      points mid-settlement. Thin delegate over {requireJITNotInProgress}.
    modifier whenJITNotInProgress() {
        requireJITNotInProgress();
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    /// @param _poolManager The Uniswap v4 PoolManager.
    /// @param maxGas_ Gas budget declared for `getIndicativeQuote` staticcalls.
    /// @param owner_ Initial owner for pool initialization and liveness controls.
    constructor(IPoolManager _poolManager, uint32 maxGas_, address owner_)
        OwnedALFHook(_poolManager, maxGas_, owner_)
        EIP712("NativeBookHook", "1")
    {
        quoter = new NativeBookQuoter(_poolManager);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: POOL ADMINISTRATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Initialize a pool and store its canonical book-bin configuration.
    /// @dev Native ETH is intentionally unsupported in this hook because maker payments are
    ///      pulled from arbitrary maker addresses during PoolManager settlement. The pool is
    ///      flipped live immediately: the book starts empty, so there is no pre-seed window
    ///      to protect.
    /// @param key Pool key. The hook address must be this contract.
    /// @param sqrtPriceX96 Initial pool price.
    /// @param config Canonical book configuration for this pool.
    /// @return tick Initial tick returned by the PoolManager.
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96, PoolConfig calldata config)
        external
        onlyOwner
        returns (int24 tick)
    {
        if (key.hooks != IHooks(address(this))) revert InvalidHookAddress();
        if (key.currency0.isAddressZero() || key.currency1.isAddressZero()) revert InvalidNativeCurrency();

        PoolId poolId = key.toId();
        _config.set(poolId, key.tickSpacing, config);
        tick = poolManager.initialize(key, sqrtPriceX96);

        emit PoolCreated(
            poolId,
            msg.sender,
            Currency.unwrap(key.currency0),
            Currency.unwrap(key.currency1),
            key.fee,
            key.tickSpacing,
            sqrtPriceX96,
            tick,
            config
        );
        _liveness.setLive(poolId, true);
    }

    /// @notice Toggle swap liveness for a pool.
    /// @param key Pool key.
    /// @param live New liveness value.
    function setPoolLive(PoolKey calldata key, bool live) external onlyOwner whenJITNotInProgress {
        _liveness.setLive(key.toId(), live);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: MAKER INVENTORY
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deposit inventory for the caller.
    /// @param currency ERC-20 currency to deposit. Native ETH is unsupported.
    /// @param amount Requested transfer amount. Fee-on-transfer tokens credit the actual received amount.
    /// @return credited Amount credited to the caller's inventory.
    function deposit(Currency currency, uint256 amount)
        external
        whenJITNotInProgress
        nonReentrant
        returns (uint256 credited)
    {
        credited = _depositFor(msg.sender, currency, amount);
    }

    /// @notice Deposit inventory for a maker.
    /// @param maker Maker receiving internal inventory credit.
    /// @param currency ERC-20 currency to deposit. Native ETH is unsupported.
    /// @param amount Requested transfer amount. Fee-on-transfer tokens credit the actual received amount.
    /// @return credited Amount credited to the maker's inventory.
    function depositFor(address maker, Currency currency, uint256 amount)
        public
        whenJITNotInProgress
        nonReentrant
        returns (uint256 credited)
    {
        credited = _depositFor(maker, currency, amount);
    }

    /// @notice Withdraw unused maker inventory.
    /// @param currency ERC-20 currency to withdraw.
    /// @param amount Amount to withdraw from the caller's inventory.
    /// @param recipient Address receiving the ERC-20 transfer.
    function withdraw(Currency currency, uint256 amount, address recipient) external whenJITNotInProgress nonReentrant {
        if (currency.isAddressZero()) revert InvalidNativeCurrency();
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert InvalidRecipient();

        _makerInventory.debit(msg.sender, currency, amount);
        IERC20(Currency.unwrap(currency)).safeTransfer(recipient, amount);
        emit InventoryWithdrawn(msg.sender, Currency.unwrap(currency), recipient, amount);
    }

    /// @notice Return a maker's withdrawable inventory balance.
    function inventoryBalance(address maker, Currency currency) external view returns (uint256) {
        return _makerInventory.balanceOf(maker, currency);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: LADDER MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Replace the caller's whole maker ladder for a pool.
    /// @dev Existing active bins are removed and proceeds are credited to the maker before new
    ///      canonical bins are posted. New bins consume the maker's deposited inventory.
    /// @param key Pool key.
    /// @param bids Bid capacities. Offsets must be negative.
    /// @param asks Ask capacities. Offsets must be positive.
    /// @param ttl Quote lifetime in seconds, capped by the pool config.
    function replaceLadder(
        PoolKey calldata key,
        BinCapacity[] calldata bids,
        BinCapacity[] calldata asks,
        uint40 ttl,
        int24 expectedRefTick,
        uint24 maxTickDeviation
    ) external whenJITNotInProgress nonReentrant {
        _validateLadderInput(key.toId(), bids.length, asks.length, ttl);
        validateDistinctOffsets(bids, asks);

        uint256 nonce = _useNonce(msg.sender);
        uint40 expiry = uint40(block.timestamp) + ttl;
        poolManager.unlock(
            abi.encode(
                UnlockAction.ReplaceLadder,
                ReplaceCallbackData(
                    msg.sender, msg.sender, key, bids, asks, expiry, expectedRefTick, maxTickDeviation, nonce, 0, false
                )
            )
        );
    }

    /// @notice Replace a maker's whole ladder using an EIP-712 signature from the maker.
    /// @dev This lets solvers, market-maker daemons, or relayers post quotes without the swap router
    ///      knowing anything about book updates. New bins consume the maker's deposited inventory.
    /// @param key Pool key.
    /// @param maker Maker whose ladder is being replaced.
    /// @param bids Bid capacities. Offsets must be negative.
    /// @param asks Ask capacities. Offsets must be positive.
    /// @param ttl Quote lifetime in seconds, capped by the pool config.
    /// @param deadline Signature expiry timestamp.
    /// @param signature Maker EIP-712 signature.
    function replaceLadderWithSig(
        PoolKey calldata key,
        address maker,
        BinCapacity[] calldata bids,
        BinCapacity[] calldata asks,
        uint40 ttl,
        int24 expectedRefTick,
        uint24 maxTickDeviation,
        uint256 deadline,
        bytes calldata signature
    ) external whenJITNotInProgress nonReentrant {
        if (block.timestamp > deadline) revert SignatureExpired();
        PoolId poolId = key.toId();
        _validateLadderInput(poolId, bids.length, asks.length, ttl);
        validateDistinctOffsets(bids, asks);
        if (block.timestamp + ttl > deadline) revert InvalidQuoteTtl();

        uint256 nonce = _useNonce(maker);
        bytes32 digest = _hashTypedDataV4(
            replaceLadderStructHash(poolId, maker, bids, asks, ttl, expectedRefTick, maxTickDeviation, nonce, deadline)
        );
        if (!SignatureChecker.isValidSignatureNowCalldata(maker, digest, signature)) revert InvalidSignature();

        uint40 expiry = uint40(block.timestamp) + ttl;
        poolManager.unlock(
            abi.encode(
                UnlockAction.ReplaceLadder,
                ReplaceCallbackData(
                    msg.sender, maker, key, bids, asks, expiry, expectedRefTick, maxTickDeviation, nonce, deadline, true
                )
            )
        );
    }

    /// @notice Cancel all active bins for the caller in a pool and credit proceeds to caller inventory.
    /// @param key Pool key.
    function cancelLadder(PoolKey calldata key) external whenJITNotInProgress nonReentrant {
        uint256 nonce = _useNonce(msg.sender);
        poolManager.unlock(
            abi.encode(UnlockAction.CancelLadder, CancelCallbackData(msg.sender, msg.sender, key, nonce, 0, false))
        );
    }

    /// @notice Cancel a maker's ladder using an EIP-712 signature from the maker.
    /// @dev This lets relayers remove stale maker exposure without specialized swap-router support.
    /// @param key Pool key.
    /// @param maker Maker whose active bins should be cancelled.
    /// @param deadline Signature expiry timestamp.
    /// @param signature Maker EIP-712 signature.
    function cancelLadderWithSig(PoolKey calldata key, address maker, uint256 deadline, bytes calldata signature)
        external
        whenJITNotInProgress
        nonReentrant
    {
        if (block.timestamp > deadline) revert SignatureExpired();

        uint256 nonce = _useNonce(maker);
        bytes32 digest = _hashTypedDataV4(cancelLadderStructHash(key.toId(), maker, nonce, deadline));
        if (!SignatureChecker.isValidSignatureNowCalldata(maker, digest, signature)) revert InvalidSignature();

        poolManager.unlock(
            abi.encode(UnlockAction.CancelLadder, CancelCallbackData(msg.sender, maker, key, nonce, deadline, true))
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: KEEPER MAINTENANCE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Retire an expired or crossed position for any maker.
    /// @dev This is public so keepers can clean stale bins without the maker being online.
    /// @param key Pool key.
    /// @param positionId Position identifier emitted or read from {makerPositionAt}.
    function retirePosition(PoolKey calldata key, bytes32 positionId) external whenJITNotInProgress nonReentrant {
        poolManager.unlock(abi.encode(UnlockAction.RetirePosition, RetireCallbackData(msg.sender, key, positionId)));
    }

    /// @notice Retire a bounded set of expired or crossed positions.
    /// @dev Unlike {retirePosition}, this skips ids that are not currently retirable so keepers can
    ///      submit optimistic batches without a single fresh position reverting the whole batch.
    /// @param key Pool key.
    /// @param positionIds Candidate position ids.
    /// @param maxRetire Maximum positions to retire from this batch. Zero means no-op.
    /// @return retired Number of positions retired.
    function retirePositions(PoolKey calldata key, bytes32[] calldata positionIds, uint256 maxRetire)
        external
        whenJITNotInProgress
        nonReentrant
        returns (uint256 retired)
    {
        if (maxRetire == 0) return 0;
        if (positionIds.length > maxRetire) revert TooManyRetireCandidates(positionIds.length, maxRetire);

        bytes memory result = poolManager.unlock(
            abi.encode(
                UnlockAction.RetirePositions, RetirePositionsCallbackData(msg.sender, key, positionIds, maxRetire)
            )
        );
        retired = abi.decode(result, (uint256));
    }

    /// @notice Claim accrued swap fees for one active maker bin without removing its liquidity.
    /// @dev Anyone can call this because proceeds are always credited to the maker recorded on the position.
    /// @param key Pool key.
    /// @param positionId Position identifier emitted or read from {makerPositionAt}.
    function claimFees(PoolKey calldata key, bytes32 positionId) external whenJITNotInProgress nonReentrant {
        poolManager.unlock(abi.encode(UnlockAction.ClaimFees, RetireCallbackData(msg.sender, key, positionId)));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: VIEWS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Return the EIP-712 digest a maker signs for {replaceLadderWithSig}.
    function hashReplaceLadder(
        PoolKey calldata key,
        address maker,
        BinCapacity[] calldata bids,
        BinCapacity[] calldata asks,
        uint40 ttl,
        int24 expectedRefTick,
        uint24 maxTickDeviation,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32) {
        return _hashTypedDataV4(
            replaceLadderStructHash(
                key.toId(), maker, bids, asks, ttl, expectedRefTick, maxTickDeviation, nonce, deadline
            )
        );
    }

    /// @notice Return the EIP-712 digest a maker signs for {cancelLadderWithSig}.
    function hashCancelLadder(PoolKey calldata key, address maker, uint256 nonce, uint256 deadline)
        external
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(cancelLadderStructHash(key.toId(), maker, nonce, deadline));
    }

    /// @notice Return canonical native-book configuration for a pool.
    function poolConfigs(PoolId poolId) external view returns (PoolConfig memory) {
        return _config.get(poolId);
    }

    /// @notice Return metadata for a hook-owned maker position.
    function positions(bytes32 positionId) external view returns (PositionInfo memory) {
        return _book.get(positionId);
    }

    /// @notice Number of active position ids currently tracked for a maker and pool.
    function makerPositionCount(PoolId poolId, address maker) external view returns (uint256) {
        return _book.makerCount(poolId, maker);
    }

    /// @notice Return a maker's active position id at an index.
    /// @param poolId Pool whose maker index is being queried.
    /// @param maker Maker whose active position id is being queried.
    /// @param index Zero-based index into the maker's active position ids for the pool.
    /// @return positionId Active position id at `index`.
    function makerPositionAt(PoolId poolId, address maker, uint256 index) external view returns (bytes32) {
        return _book.makerAt(poolId, maker, index);
    }

    /// @notice Number of active position ids tracked for a pool.
    /// @param poolId Pool whose active position count is being queried.
    /// @return count Number of active hook-owned position ids tracked for the pool.
    function activePositionCount(PoolId poolId) external view returns (uint256) {
        return _book.activeCount(poolId);
    }

    /// @notice Return a pool's active position id at an index.
    /// @param poolId Pool whose active position id is being queried.
    /// @param index Zero-based index into the pool's active position ids.
    /// @return positionId Active position id at `index`.
    function activePositionAt(PoolId poolId, uint256 index) external view returns (bytes32 positionId) {
        return _book.activeAt(poolId, index);
    }

    /// @notice Cursor used for bounded opportunistic retirement.
    /// @param poolId Pool whose retirement cursor is being queried.
    /// @return cursor Current cursor into the pool's active position ids.
    function retireCursor(PoolId poolId) external view returns (uint256 cursor) {
        return _book.cursor(poolId);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: IALFHook QUOTING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IALFHook
    /// @dev Quotes the same native v4 tick-walking path used by execution, with the hook's
    ///      bounded pre-swap retirement applied as virtual liquidity removals.
    function getIndicativeQuote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bytes calldata)
        external
        view
        override
        returns (uint256 outputAmount)
    {
        return quoter.getIndicativeQuote(INativeBookQuoterSource(address(this)), key, zeroForOne, amountSpecified);
    }

    /// @inheritdoc IALFHook
    /// @dev Applies the same virtual pre-swap retirement as {getIndicativeQuote}.
    function swapToPrice(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata
    ) external view override returns (uint256, uint256) {
        return quoter.swapToPrice(
            INativeBookQuoterSource(address(this)), key, zeroForOne, amountSpecified, sqrtPriceLimitX96
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: POOL MANAGER CALLBACK
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert CallbackOnlyPoolManager();

        UnlockAction action = abi.decode(data, (UnlockAction));
        if (action == UnlockAction.ReplaceLadder) {
            (, ReplaceCallbackData memory d) = abi.decode(data, (UnlockAction, ReplaceCallbackData));
            _replaceLadder(d);
        } else if (action == UnlockAction.CancelLadder) {
            (, CancelCallbackData memory d) = abi.decode(data, (UnlockAction, CancelCallbackData));
            (uint256 binsRemoved, uint256 amount0, uint256 amount1) =
                _removeMakerPositions(d.key, d.maker, type(uint256).max);
            emit LadderCanceled(
                d.key.toId(), d.maker, d.submitter, binsRemoved, amount0, amount1, d.nonce, d.deadline, d.viaSignature
            );
        } else if (action == UnlockAction.RetirePosition) {
            (, RetireCallbackData memory d) = abi.decode(data, (UnlockAction, RetireCallbackData));
            (, int24 currentTick,,) = poolManager.getSlot0(d.key.toId());
            if (!isRetirable(_book.get(d.positionId), d.key.toId(), currentTick)) revert PositionNotRetirable();
            _removePosition(d.key, d.positionId);
        } else if (action == UnlockAction.RetirePositions) {
            (, RetirePositionsCallbackData memory d) = abi.decode(data, (UnlockAction, RetirePositionsCallbackData));
            uint256 retired = _retirePositions(d.key, d.positionIds, d.maxRetire);
            emit PositionsRetired(d.key.toId(), d.caller, d.positionIds.length, d.maxRetire, retired);
            return abi.encode(retired);
        } else {
            (, RetireCallbackData memory d) = abi.decode(data, (UnlockAction, RetireCallbackData));
            _claimFees(d.key, d.positionId, d.caller);
        }

        return "";
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        PUBLIC: HOOK PERMISSIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Required v4 hook flags:
    ///      - beforeInitialize: block direct init (force initializePool; see OwnedALFHook)
    ///      - beforeAddLiquidity: reject exact-bin-width external LP (ReservedBookRange)
    ///      - beforeRemoveLiquidity: pass-through (external LP may always exit)
    ///      - beforeSwap: liveness gate + bounded opportunistic retirement
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
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

    /// @dev External LP additions must not be exactly one bin wide: that range is reserved for
    ///      the book so third-party positions cannot masquerade as maker bins.
    function _beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        PoolConfig storage config = _config.get(key.toId());
        if (config.binSpacingTicks > 0 && params.tickUpper - params.tickLower == config.binSpacingTicks) {
            revert ReservedBookRange();
        }
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @dev External LP removals are always permitted; only additions are shape-constrained.
    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @dev Liveness gate plus bounded opportunistic retirement of stale/crossed bins. The scan
    ///      settles each retired bin against the PoolManager via `_take`/`_settle` on the pool
    ///      currencies, so it runs under the per-pool `JITLock`: entry points reject reentry via
    ///      `whenJITNotInProgress` and a reentrant same-pool swap is rejected by {JITLock.enter}.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        _liveness.requireLive(poolId);

        jitLockFor(poolId).enter();
        _retireSome(key, _config.get(poolId).maxRetirePerSwap);
        jitLockFor(poolId).clear();
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INTERNAL: LADDER LIFECYCLE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Shared entry validation: TTL within the pool's cap and total bins within the
    ///      pool's per-maker allowance.
    function _validateLadderInput(PoolId poolId, uint256 bidCount, uint256 askCount, uint40 ttl) internal view {
        PoolConfig storage config = _config.get(poolId);
        if (ttl == 0 || ttl > config.maxQuoteTtl) revert InvalidQuoteTtl();
        if (bidCount + askCount > config.maxMakerBins) revert TooManyBins();
    }

    /// @dev Whole-ladder replacement inside the unlock: remove every active bin (crediting
    ///      proceeds to the maker), re-anchor on the current reference tick under the maker's
    ///      slippage bound, then post the new bids and asks from maker inventory.
    function _replaceLadder(ReplaceCallbackData memory d) internal {
        PoolId poolId = d.key.toId();
        _liveness.requireLive(poolId);
        _removeMakerPositions(d.key, d.maker, type(uint256).max);

        PoolConfig storage config = _config.get(poolId);
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        int24 refTick = BinMath.referenceTick(currentTick, config.binSpacingTicks);
        BinMath.requireRefTickWithin(refTick, d.expectedRefTick, d.maxTickDeviation);

        for (uint256 i; i < d.bids.length;) {
            _postBin(d.key, d.maker, config, refTick, Side.Bid, d.bids[i], d.expiry);
            unchecked {
                ++i;
            }
        }
        for (uint256 i; i < d.asks.length;) {
            _postBin(d.key, d.maker, config, refTick, Side.Ask, d.asks[i], d.expiry);
            unchecked {
                ++i;
            }
        }

        emit LadderReplaced(
            poolId, d.maker, d.submitter, d.bids.length, d.asks.length, d.expiry, d.nonce, d.deadline, d.viaSignature
        );
    }

    /// @dev Post one bin: project the offset onto its tick range, size single-sided liquidity,
    ///      mint the hook-owned v4 position (debiting maker inventory on settlement), and record
    ///      it in the registry. Zero-amount entries are skipped.
    function _postBin(
        PoolKey memory key,
        address maker,
        PoolConfig memory config,
        int24 refTick,
        Side side,
        BinCapacity memory bin,
        uint40 expiry
    ) internal {
        if (bin.amount == 0) return;
        if (!validOffset(side, bin.offset, config.binsPerSide)) revert InvalidBinOffset();

        (int24 tickLower, int24 tickUpper) = BinMath.binRange(refTick, bin.offset, config.binSpacingTicks);
        if (tickLower < TickMath.minUsableTick(key.tickSpacing) || tickUpper > TickMath.maxUsableTick(key.tickSpacing))
        {
            revert InvalidBinOffset();
        }
        uint128 liquidity = BinMath.binLiquidity(side, tickLower, tickUpper, bin.amount);
        if (liquidity < config.minBinLiquidity) revert InvalidBinLiquidity();

        PoolId poolId = key.toId();
        bytes32 id = derivePositionId(poolId, maker, side, tickLower);

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: positionSalt(id)
            }),
            ""
        );
        _resolveDelta(key, delta, maker);

        _book.record(
            id,
            PositionInfo({
                maker: maker,
                poolId: poolId,
                side: side,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidity: liquidity,
                expiry: expiry,
                active: true
            })
        );

        emit BinPosted(poolId, maker, id, side, tickLower, tickUpper, bin.offset, bin.amount, liquidity, expiry);
    }

    /// @dev Remove up to `maxRemovals` of the maker's active bins, crediting proceeds to the
    ///      maker's inventory. Pops from the back of the maker index so removal stays O(1).
    function _removeMakerPositions(PoolKey memory key, address maker, uint256 maxRemovals)
        internal
        returns (uint256 removed, uint256 amount0, uint256 amount1)
    {
        PoolId poolId = key.toId();
        while (_book.makerCount(poolId, maker) != 0 && removed < maxRemovals) {
            bytes32 id = _book.makerAt(poolId, maker, _book.makerCount(poolId, maker) - 1);
            (uint256 removedAmount0, uint256 removedAmount1, bool didRemove) = _removePosition(key, id);
            amount0 += removedAmount0;
            amount1 += removedAmount1;
            if (!didRemove) break;
            unchecked {
                ++removed;
            }
        }
    }

    /// @dev Burn a position's v4 liquidity, credit proceeds to its maker, and delete it from
    ///      the registry. A no-op for inactive ids.
    function _removePosition(PoolKey memory key, bytes32 id)
        internal
        returns (uint256 amount0, uint256 amount1, bool removed)
    {
        PositionInfo memory p = _book.get(id);
        if (!p.active) return (0, 0, false);

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: p.tickLower,
                tickUpper: p.tickUpper,
                liquidityDelta: -int256(uint256(p.liquidity)),
                salt: positionSalt(id)
            }),
            ""
        );
        (amount0, amount1) = _resolveDelta(key, delta, p.maker);

        _book.remove(id);
        emit BinRetired(p.poolId, p.maker, id, p.side, p.tickLower, p.tickUpper, p.liquidity, amount0, amount1);
        removed = true;
    }

    /// @dev Retire every retirable id in `positionIds`, up to `maxRetire`. Non-retirable ids
    ///      are skipped, not reverted, so keeper batches tolerate stale candidate lists.
    function _retirePositions(PoolKey memory key, bytes32[] memory positionIds, uint256 maxRetire)
        internal
        returns (uint256 retired)
    {
        PoolId poolId = key.toId();
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        for (uint256 i; i < positionIds.length && retired < maxRetire;) {
            bytes32 id = positionIds[i];
            if (isRetirable(_book.get(id), poolId, currentTick)) {
                _removePosition(key, id);
                unchecked {
                    ++retired;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Poke a position's fee growth with a zero liquidity delta and credit the accrued
    ///      fees to its maker.
    function _claimFees(PoolKey memory key, bytes32 id, address caller) internal {
        PositionInfo memory p = _book.get(id);
        if (!p.active || PoolId.unwrap(p.poolId) != PoolId.unwrap(key.toId())) revert InvalidPosition();

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: p.tickLower, tickUpper: p.tickUpper, liquidityDelta: 0, salt: positionSalt(id)
            }),
            ""
        );
        (uint256 amount0, uint256 amount1) = _resolveDelta(key, delta, p.maker);
        emit FeesClaimed(p.poolId, p.maker, id, caller, amount0, amount1);
    }

    /// @dev Bounded opportunistic retirement: scan active ids from the pool's cursor, retiring any
    ///      that are expired or crossed. The scan inspects at most `min(maxRemovals, activeCount)`
    ///      ids — one full pass — since re-inspecting a position within the same call is wasted
    ///      work (its retirability cannot change mid-call). The cursor persists across swaps so the
    ///      scan makes progress even when each swap only inspects a slice of the book. Mirrored
    ///      virtually by `NativeBookQuoter._quoteRetirementAdjustments`; keep the two scans in
    ///      lockstep.
    function _retireSome(PoolKey calldata key, uint8 maxRemovals) internal {
        if (maxRemovals == 0) return;
        PoolId poolId = key.toId();
        uint256 length = _book.activeCount(poolId);
        if (length == 0) return;

        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        // Cap inspections at one full pass: the smaller of the operator's per-swap budget
        // (`maxRemovals`) and the active count at entry (`length`). This bounds removals by the same
        // budget (each inspection retires at most one id) without wrapping to re-check the book.
        uint256 budget = maxRemovals < length ? maxRemovals : length;
        uint256 checked = 0;
        uint256 cursor = _book.cursor(poolId) % length;
        while (_book.activeCount(poolId) != 0 && checked < budget) {
            uint256 activeLength = _book.activeCount(poolId);
            if (cursor >= activeLength) cursor = 0;
            bytes32 id = _book.activeAt(poolId, cursor);
            unchecked {
                ++checked;
            }
            if (isRetirable(_book.get(id), poolId, currentTick)) {
                _removePosition(key, id);
                if (cursor >= _book.activeCount(poolId)) cursor = 0;
            } else {
                unchecked {
                    ++cursor;
                }
            }
        }
        uint256 remaining = _book.activeCount(poolId);
        _book.storeCursor(poolId, remaining == 0 ? 0 : cursor % remaining);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INTERNAL: SETTLEMENT
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Resolve a `modifyLiquidity` delta against the maker's inventory: negative legs are
    ///      settled to the PoolManager from hook-held ERC-20 (debiting the maker), positive legs
    ///      are taken from the PoolManager and credited to the maker.
    function _resolveDelta(PoolKey memory key, BalanceDelta delta, address maker)
        internal
        returns (uint256 credit0, uint256 credit1)
    {
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();

        if (amount0 < 0) _debitAndSettle(key.currency0, maker, uint256(uint128(-amount0)));
        else if (amount0 > 0) credit0 = _takeAndCredit(key.currency0, maker, uint256(uint128(amount0)));

        if (amount1 < 0) _debitAndSettle(key.currency1, maker, uint256(uint128(-amount1)));
        else if (amount1 > 0) credit1 = _takeAndCredit(key.currency1, maker, uint256(uint128(amount1)));
    }

    function _debitAndSettle(Currency currency, address maker, uint256 amount) internal {
        _makerInventory.debit(maker, currency, amount);
        _settle(currency, address(this), amount);
    }

    function _takeAndCredit(Currency currency, address maker, uint256 amount) internal returns (uint256 credited) {
        uint256 balanceBefore = currency.balanceOfSelf();
        _take(currency, address(this), amount);
        credited = currency.balanceOfSelf() - balanceBefore;
        _makerInventory.credit(maker, currency, credited);
    }

    function _depositFor(address maker, Currency currency, uint256 amount) internal returns (uint256 credited) {
        if (maker == address(0)) revert InvalidMaker();
        if (currency.isAddressZero()) revert InvalidNativeCurrency();
        if (amount == 0) revert ZeroAmount();

        IERC20 token = IERC20(Currency.unwrap(currency));
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        credited = token.balanceOf(address(this)) - balanceBefore;
        if (credited == 0) revert ZeroAmount();

        _makerInventory.credit(maker, currency, credited);
        emit InventoryDeposited(maker, Currency.unwrap(currency), msg.sender, amount, credited);
    }
}
