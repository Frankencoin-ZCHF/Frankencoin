// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {OwnedALFHook} from "./OwnedALFHook.sol";
import {SwapSimulator} from "../libraries/SwapSimulator.sol";

/// @title SpreadQuoterBase
/// @author Uniswap Labs
/// @notice Abstract base for spread quoters using native v4 LP with a static, per-pool fee.
///         Provides pricing via SwapSimulator and single-tick LP concentration. Concrete
///         hooks define LP access control and hook permissions.
/// @dev    Pools use a static fee defined by `PoolKey.fee` at deploy time. The v4 PoolManager
///         charges this fee natively on every swap. Owner has only a per-pool liveness flag
///         (`setPoolLive`) for pause/resume; pricing itself is immutable post-initialize.
/// @custom:security-contact security@uniswap.org
abstract contract SpreadQuoterBase is OwnedALFHook {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    /// @notice Lower tick of the single permitted LP range per pool. LP add liquidity calls
    ///         must use exactly `[activeLowerTick, activeLowerTick + tickSpacing]`.
    mapping(PoolId => int24) public activeLowerTick;

    /// @notice Emitted when the active lower tick is changed via `setActiveTick`. The initial
    ///         tick set by `initializePool` does not emit: the tick is observable via the
    ///         `activeLowerTick` getter and `setActiveTick` is the canonical mutation event.
    /// @param poolId           The pool whose active range changed.
    /// @param activeLowerTick  The new lower tick (always aligned to `tickSpacing`).
    event ActiveTickUpdated(PoolId indexed poolId, int24 activeLowerTick);

    /// @dev LP add-liquidity range is malformed (lower >= upper, not aligned to `tickSpacing`,
    ///      or the range width does not equal one tickSpacing).
    error InvalidTickRange();
    /// @dev LP add-liquidity range is correctly shaped but not at the configured `activeLowerTick`.
    error WrongActiveTick();

    /// @dev `setActiveTick` was called while the prior active band still holds liquidity.
    ///      Relocating without draining would orphan that liquidity in a range no longer
    ///      enforced by the hook, leaving multiple unmigrated bands coexisting and diverging
    ///      on-chain liquidity from the hook's single-band policy. Drain the old band first
    ///      (have authorized LPs remove all positions at the old tick), then relocate.
    /// @param activeLowerTick The prior active tick that still has liquidity referenced at it.
    error ActiveTickBandNonEmpty(int24 activeLowerTick);

    /// @dev `key.fee` carries the `LPFeeLibrary.DYNAMIC_FEE_FLAG` (0x800000). SpreadQuoter is
    ///      designed around a static fee fixed at pool creation; dynamic-fee pools require the
    ///      hook to maintain its own fee state and route every swap through a fee-update
    ///      callback, which this contract is not built for. If a dynamic-fee pool
    ///      slipped through, `slot0.lpFee` would stay at its `0` default for the pool's
    ///      lifetime and every swap would charge zero LP fee. Use a concrete `uint24` fee
    ///      value below `MAX_LP_FEE` instead.
    error DynamicFeeNotSupported();

    /// @dev The PoolKey's hooks address does not match this contract: `initializePool` was
    ///      called with a key intended for a different hook.
    error InvalidHookAddress();

    /// @param _poolManager The Uniswap v4 PoolManager.
    /// @param maxGas_      Gas budget declared for `getIndicativeQuote` staticcalls.
    /// @param owner_       Initial owner. Owner can toggle liveness and the active tick.
    constructor(IPoolManager _poolManager, uint32 maxGas_, address owner_)
        OwnedALFHook(_poolManager, maxGas_, owner_)
    {}

    // ──── IALFHook ────

    /// @notice Simulate a swap up to a target price, returning both amounts.
    /// @dev Delegates to `SwapSimulator.simulateSwapToPrice`. The `DYNAMIC_FEE_FLAG` and
    ///      `OVERRIDE_FEE_FLAG` bits are stripped from `key.fee` before forwarding; both
    ///      sit above `MAX_LP_FEE`, so the strip is a no-op for any valid static fee and a
    ///      belt-and-suspenders guard against a misconfigured pool slipping a flag bit past
    ///      `initializePool`'s rejection.
    function swapToPrice(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata
    ) external view virtual override returns (uint256 amountIn, uint256 amountOut) {
        if (!_liveness.isLive(key.toId())) return (0, 0);

        return SwapSimulator.simulateSwapToPrice(
            poolManager,
            key.toId(),
            zeroForOne,
            amountSpecified,
            _staticFee(key.fee),
            key.tickSpacing,
            sqrtPriceLimitX96
        );
    }

    // ──── Hook Lifecycle ────

    /// @notice Initialize a new SpreadQuoter pool at the operator's chosen price.
    /// @dev    `onlyOwner`-gated and routes through `poolManager.initialize` so v4's
    ///         `Hooks.noSelfCall` exempts the call from `_beforeInitialize`'s revert. The
    ///         active-tick derivation is performed inline from the tick returned by
    ///         `poolManager.initialize`. The pool starts paused (`livePools[id] == false`);
    ///         enable via {setPoolLive} after seeding LP at the derived active tick.
    ///         Dynamic-fee pools are rejected.
    /// @param key            The PoolKey (must reference this hook; `key.fee` must NOT carry
    ///                       the `LPFeeLibrary.DYNAMIC_FEE_FLAG`).
    /// @param sqrtPriceX96   Initial sqrt price (Q64.96). This price is permanent for the pool's
    ///                       lifetime.
    /// @return tick          The initial tick assigned by the PoolManager.
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external onlyOwner returns (int24 tick) {
        if (key.hooks != IHooks(address(this))) revert InvalidHookAddress();
        if (key.fee.isDynamicFee()) revert DynamicFeeNotSupported();
        tick = poolManager.initialize(key, sqrtPriceX96);
        _setActiveTickFromInitialTick(key, tick);
    }

    /// @dev Floor-align `tick` to `key.tickSpacing` and clamp into the v4 usable tick range so
    ///      the resulting LP range `[activeLowerTick, activeLowerTick + tickSpacing]` is always
    ///      a valid v4 LP position, even at the extremes near MIN/MAX_TICK. Emits no event;
    ///      `setActiveTick` is the canonical source for `ActiveTickUpdated` post-init.
    function _setActiveTickFromInitialTick(PoolKey calldata key, int24 tick) private {
        int24 compressed = tick / key.tickSpacing;
        if (tick < 0 && tick % key.tickSpacing != 0) compressed--;
        int24 candidate = compressed * key.tickSpacing;

        int24 minUsable = TickMath.minUsableTick(key.tickSpacing);
        int24 maxLower = TickMath.maxUsableTick(key.tickSpacing) - key.tickSpacing;
        if (candidate < minUsable) candidate = minUsable;
        else if (candidate > maxLower) candidate = maxLower;

        activeLowerTick[key.toId()] = candidate;
    }

    /// @dev Reverts when the pool is paused; otherwise no-ops. v4 charges the static fee from
    ///      `key.fee`, so no override is returned. hookData is ignored; pricing is fully static.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        view
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        _liveness.requireLive(poolId);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // ──── Pricing ────

    function _price(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bool, address)
        internal
        view
        virtual
        override
        returns (uint256 outputAmount)
    {
        if (!_liveness.isLive(key.toId())) return 0;
        outputAmount = SwapSimulator.simulateSwap(
            poolManager, key.toId(), zeroForOne, amountSpecified, _staticFee(key.fee), key.tickSpacing
        );
    }

    /// @dev Strip `DYNAMIC_FEE_FLAG` and `OVERRIDE_FEE_FLAG` from a raw `key.fee` before
    ///      forwarding to `SwapSimulator`, which assumes `fee <= MAX_SWAP_FEE`. Both flag
    ///      bits sit above `MAX_LP_FEE`, so the strip is a no-op for any valid static fee
    ///      and a belt-and-suspenders guard against a flag bit slipping past
    ///      `initializePool`'s dynamic-fee rejection.
    function _staticFee(uint24 rawFee) private pure returns (uint24) {
        return rawFee & ~(LPFeeLibrary.DYNAMIC_FEE_FLAG | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    // ──── LP Tick Enforcement ────

    /// @dev Enforce single-tick-spacing LP at the active tick.
    function _enforceActiveTick(PoolKey calldata key, ModifyLiquidityParams calldata params) internal view {
        if (params.tickUpper - params.tickLower != key.tickSpacing) revert InvalidTickRange();
        if (params.tickLower != activeLowerTick[key.toId()]) revert WrongActiveTick();
    }

    // ──── Owner Functions ────

    /// @notice Toggle liveness for a pool.
    /// @dev Pools default to paused (`false`) immediately after `manager.initialize`. The
    ///      owner enables a pool by calling `setPoolLive(key, true)`. Disabling pauses swaps
    ///      via `_beforeSwap`'s liveness check; pricing (the static `key.fee`) is unaffected.
    function setPoolLive(PoolKey calldata key, bool live) external virtual onlyOwner {
        _liveness.setLive(key.toId(), live);
    }

    /// @notice Set the active lower tick for LP concentration.
    /// @dev    Relocates the band that new LP adds will be enforced to (via
    ///         `_enforceActiveTick` in subclasses). Refuses to relocate while the prior
    ///         active band still references liquidity in v4: operators must drain the old
    ///         band first (have authorized LPs remove all positions at the old tick) before
    ///         calling this with a different `newActiveLowerTick`. Setting the same tick is
    ///         always permitted (idempotent no-op). For the multi-LP trust trade-offs (e.g.
    ///         revocation locking prior-band positions) see the consuming subclass's
    ///         `Trust model` NatSpec.
    function setActiveTick(PoolKey calldata key, int24 newActiveLowerTick) external virtual onlyOwner {
        if (newActiveLowerTick % key.tickSpacing != 0) revert InvalidTickRange();

        PoolId poolId = key.toId();
        int24 oldActiveLowerTick = activeLowerTick[poolId];
        if (newActiveLowerTick != oldActiveLowerTick) {
            // Operator footgun guard: relocating while positions still reference the old
            // band would leave them outside the enforced range, silently diverging on-chain
            // liquidity from the hook's single-band policy. `liquidityGross` at
            // `oldActiveLowerTick` is non-zero iff at least one position has either its
            // lower or upper tick on that boundary, and the hook enforces every position
            // as exactly `[activeLowerTick, activeLowerTick + tickSpacing]`, so this catches
            // every position opened under the old policy.
            (uint128 liquidityGross,) = poolManager.getTickLiquidity(poolId, oldActiveLowerTick);
            if (liquidityGross != 0) revert ActiveTickBandNonEmpty(oldActiveLowerTick);
        }

        activeLowerTick[poolId] = newActiveLowerTick;
        emit ActiveTickUpdated(poolId, newActiveLowerTick);
    }
}
