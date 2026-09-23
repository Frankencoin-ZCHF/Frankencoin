// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {DualPoolHook} from "../../../src/alf/DualPoolHook.sol";
import {LiquidityBucket} from "../../../src/alf/types/Distribution.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";

/// @title DualPoolHandler
/// @notice Foundry invariant-test handler that bounded-fuzzes DualPoolHook through a sequence
///         of LP, swap, and yield operations across a fixed actor set. Tracks ghost variables so
///         the invariant test can assert solvency, share-supply parity, and JIT lock cleanliness.
///
/// @dev    `fail_on_revert = false` is expected — many handler calls deliberately stress edge
///         cases (zero-share deposits, oversized withdrawals, swaps against an empty pool) that
///         the protocol correctly rejects. Reverts are normal; the invariants must hold over the
///         post-state of every successful operation.
contract DualPoolHandler is Test {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    // ──── System-under-test wiring ────

    DualPoolHook public immutable hook;
    IPoolManager public immutable manager;
    PoolSwapTest public immutable swapRouter;
    PoolKey public key;
    PoolId public poolId;
    MockERC20 public token0;
    MockERC20 public token1;
    MockERC4626 public vault0;
    MockERC4626 public vault1;

    // ──── Actor pool ────

    /// @dev A fixed set of actors. The invariant assertion sums their shares and compares to
    ///      `totalShares(poolId)`; using a closed set avoids the unbounded-storage problem of
    ///      tracking ad-hoc msg.senders.
    address[] public actors;
    mapping(address => bool) public isActor;

    // ──── Ghost variables ────
    //
    //  Track expectations across the fuzz run that the post-state of any individual op cannot
    //  test directly. Asserted by `invariant_*` functions in DualPoolInvariantTest.

    uint256 public ghost_totalDeposited0;
    uint256 public ghost_totalDeposited1;
    uint256 public ghost_totalWithdrawn0;
    uint256 public ghost_totalWithdrawn1;
    uint256 public ghost_totalYieldInjected0;
    uint256 public ghost_totalYieldInjected1;

    /// @dev Net token flow into the pool from swaps, per side (signed). A swap changes the hook's
    ///      position by the negation of the swapper's delta, so the pool's token0 change for a fill
    ///      is `-delta.amount0()` (positive = pool received token0, negative = pool paid it out).
    ///      Consumed by the per-side value-conservation invariant, which must account for swap flow
    ///      on top of deposits/yield/bootstrap.
    int256 public ghost_swapNetIn0;
    int256 public ghost_swapNetIn1;

    /// @dev Per-call counters — useful for diagnostics if invariants regress.
    uint256 public ghost_addLiquidityCalls;
    uint256 public ghost_removeLiquidityCalls;
    uint256 public ghost_swapCalls;
    uint256 public ghost_yieldCalls;
    uint256 public ghost_warpCalls;
    uint256 public ghost_setDistributionCalls;

    constructor(
        DualPoolHook _hook,
        IPoolManager _manager,
        PoolSwapTest _swapRouter,
        PoolKey memory _key,
        MockERC20 _token0,
        MockERC20 _token1,
        MockERC4626 _vault0,
        MockERC4626 _vault1,
        address[] memory _actors
    ) {
        hook = _hook;
        manager = _manager;
        swapRouter = _swapRouter;
        key = _key;
        poolId = _key.toId();
        token0 = _token0;
        token1 = _token1;
        vault0 = _vault0;
        vault1 = _vault1;
        for (uint256 i; i < _actors.length; i++) {
            actors.push(_actors[i]);
            isActor[_actors[i]] = true;
        }
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    // ──── Internal helpers ────

    function _pickActor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    /// @dev Mint and approve `amount` of each token from `actor` to the hook. The hook pulls
    ///      tokens via `safeTransferFrom`, so the actor must hold the balance and have
    ///      pre-approved the hook.
    function _fundActor(address actor, uint256 amount0, uint256 amount1) internal {
        if (amount0 > 0) {
            token0.mint(actor, amount0);
            vm.prank(actor);
            token0.approve(address(hook), type(uint256).max);
        }
        if (amount1 > 0) {
            token1.mint(actor, amount1);
            vm.prank(actor);
            token1.approve(address(hook), type(uint256).max);
        }
    }

    /// @dev Approve the swap router to spend `actor`'s tokens. Idempotent.
    function _approveSwap(address actor) internal {
        vm.startPrank(actor);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    // ──── Handler operations ────

    /// @notice Mint shares for an actor in proportion to current pool ratio.
    function addLiquidity(uint256 actorSeed, uint256 sharesSeed) external {
        ghost_addLiquidityCalls++;

        address actor = _pickActor(actorSeed);
        // Bound shares to a reasonable mint size. Too large and we'd exceed available supply
        // for the actor; too small and we hit the round-up zero-amount revert path.
        uint256 totalShares = hook.totalShares(poolId);
        if (totalShares == 0) return; // bootstrap is owner-only; handled in setUp
        uint256 sharesToMint = bound(sharesSeed, 1, totalShares); // up to 100% dilution

        // Use previewDeposit to size the funding correctly for the actor.
        (uint256 want0, uint256 want1) = hook.previewDeposit(key, sharesToMint);
        _fundActor(actor, want0, want1);

        vm.prank(actor);
        try hook.addLiquidity(key, sharesToMint, type(uint256).max, type(uint256).max, type(uint256).max) returns (
            uint256 a0, uint256 a1
        ) {
            ghost_totalDeposited0 += a0;
            ghost_totalDeposited1 += a1;
        } catch {
            // Expected paths: deposit auth (if external deposits are not enabled), zero-share
            // edge cases, slippage in fast-vault-yield scenarios. Invariants must still hold
            // post-revert.
        }
    }

    /// @notice Burn an actor's shares back into proportional assets.
    function removeLiquidity(uint256 actorSeed, uint256 sharesSeed) external {
        ghost_removeLiquidityCalls++;

        address actor = _pickActor(actorSeed);
        uint256 userBal = hook.userShares(poolId, actor);
        if (userBal == 0) return;
        uint256 sharesToBurn = bound(sharesSeed, 1, userBal);

        // Advance one block — same-block-withdraw guard would otherwise revert if the actor
        // just deposited in this fuzz iteration.
        vm.roll(block.number + 1);

        vm.prank(actor);
        try hook.removeLiquidity(key, sharesToBurn, 0, 0, type(uint256).max) returns (uint256 a0, uint256 a1) {
            ghost_totalWithdrawn0 += a0;
            ghost_totalWithdrawn1 += a1;
        } catch {}
    }

    /// @notice Execute a swap through the v4 swap router. Generates both directions and both
    ///         exact-input and exact-output by varying the input seeds.
    function swap(uint256 actorSeed, uint256 dirSeed, int256 amountSeed) external {
        ghost_swapCalls++;

        address actor = _pickActor(actorSeed);
        bool zeroForOne = (dirSeed % 2 == 0);

        // Bound amount magnitude — extreme amounts revert the swap math, which would burn
        // every fuzz iteration if we didn't constrain. Allow exact-in (negative) and
        // exact-out (positive) separately.
        int256 amount = amountSeed;
        if (amount == 0) amount = 1;
        if (amount > 1e21) amount = 1e21;
        if (amount < -1e21) amount = -1e21;

        // Fund the actor for the input side. Over-funding doesn't hurt; under-funding reverts.
        _fundActor(actor, 1e22, 1e22);
        _approveSwap(actor);

        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        vm.prank(actor);
        try swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amount, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) returns (
            BalanceDelta d
        ) {
            // Pool's token change = negation of the swapper's delta. Accumulate net inflow per side
            // so the value-conservation invariant can bound LP withdrawals by everything that ever
            // entered the pool (deposits + yield + bootstrap + swap flow).
            ghost_swapNetIn0 += -int256(d.amount0());
            ghost_swapNetIn1 += -int256(d.amount1());
        } catch {}
    }

    /// @notice Inject yield into one of the vaults. Tests that LP shares correctly accrue
    ///         underlying yield and that share math doesn't break under post-bootstrap
    ///         vault inflation.
    function simulateYield(uint256 sideSeed, uint256 amountSeed) external {
        ghost_yieldCalls++;

        // Bound yield: not too small (rounds to 0) and not too large (overflows totals).
        uint256 amount = bound(amountSeed, 1e6, 1e21);
        if (sideSeed % 2 == 0) {
            token0.mint(address(this), amount);
            token0.approve(address(vault0), amount);
            vault0.simulateYield(amount);
            ghost_totalYieldInjected0 += amount;
        } else {
            token1.mint(address(this), amount);
            token1.approve(address(vault1), amount);
            vault1.simulateYield(amount);
            ghost_totalYieldInjected1 += amount;
        }
    }

    /// @notice Rotate the pool's liquidity distribution to a fresh, valid shape. Exercises
    ///         `setDistribution` interleaved with the JIT lifecycle and makes the distribution
    ///         invariants (weights sum to 10_000, bounded bucket count, non-zero weights)
    ///         non-trivial — without this the distribution never changes after setUp.
    /// @dev    Always constructs a well-formed distribution (so the call succeeds), pranked as
    ///         the hook owner. `whenJITNotInProgress` holds between handler calls.
    function setDistribution(uint256 nSeed, uint256 widthSeed) external {
        ghost_setDistributionCalls++;

        uint256 n = bound(nSeed, 1, 8);
        LiquidityBucket[] memory dist = new LiquidityBucket[](n);
        uint256 base = 10_000 / n;
        uint256 assigned;
        for (uint256 i; i < n; i++) {
            uint16 w = (i == n - 1) ? uint16(10_000 - assigned) : uint16(base);
            if (i != n - 1) assigned += base;
            uint256 mult = bound(widthSeed, 1, 1_000) + i;
            int24 hw = int24(uint24(mult)) * key.tickSpacing;
            dist[i] = LiquidityBucket({tickLower: -hw, tickUpper: hw, weightBps: w});
        }

        vm.prank(hook.owner());
        try hook.setDistribution(key, dist) {} catch {}
    }

    /// @notice Advance time and block number — exercises any time-dependent paths (deposit-block
    ///         guard, deadline checks).
    function warpTime(uint256 secondsSeed) external {
        ghost_warpCalls++;
        uint256 sec = bound(secondsSeed, 1, 7 days);
        vm.warp(block.timestamp + sec);
        vm.roll(block.number + 1);
    }
}
