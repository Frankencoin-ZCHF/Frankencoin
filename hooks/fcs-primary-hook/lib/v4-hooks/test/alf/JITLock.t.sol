// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {
    JITLock,
    JITInProgress,
    jitLockFor,
    anyJITInProgress,
    requireJITNotInProgress
} from "../../src/alf/types/JITLock.sol";

/// @notice Harness exercising the type's transient lock. Each scenario is a SINGLE external call so
///         the whole sequence runs in one transaction: EIP-1153 transient storage is cleared at the
///         end of a transaction, and `forge test --isolate` executes each top-level call as its own
///         transaction, so spreading a scenario across multiple harness calls would lose the state
///         between them. Keeping each scenario in one call makes the tests pass in both modes.
contract JITLockHarness {
    /// @dev Enter a cycle for `id`, report whether a cycle is in flight afterward.
    function enterAndReport(PoolId id) external returns (bool inProgress) {
        jitLockFor(id).enter();
        inProgress = anyJITInProgress();
    }

    /// @dev Enter then clear a cycle for `id`, report whether one is in flight afterward.
    function enterClearAndReport(PoolId id) external returns (bool inProgress) {
        jitLockFor(id).enter();
        jitLockFor(id).clear();
        inProgress = anyJITInProgress();
    }

    /// @dev Enter the same pool twice; the second {enter} must revert {JITInProgress}.
    function enterTwice(PoolId id) external {
        jitLockFor(id).enter();
        jitLockFor(id).enter();
    }

    /// @dev Enter a cycle, then hit the entry-point guard; it must revert while in flight. The guard
    ///      reads the global counter, so it rejects regardless of which pool an entry point targets.
    function enterThenRequireNotInProgress(PoolId id) external {
        jitLockFor(id).enter();
        requireJITNotInProgress();
    }

    /// @dev The guard passes when idle and again after a completed cycle, within one transaction.
    function requireNotInProgressIdleThenCycle(PoolId id) external {
        requireJITNotInProgress();
        jitLockFor(id).enter();
        jitLockFor(id).clear();
        requireJITNotInProgress();
    }

    /// @dev Run two pools' cycles concurrently, reporting the in-flight flag at each step. Distinct
    ///      pools have independent per-pool locks but share the global counter, so the hook is only
    ///      idle once every cycle has cleared.
    function twoPoolLifecycle(PoolId a, PoolId b)
        external
        returns (bool afterBothEnter, bool afterClearA, bool afterClearB)
    {
        jitLockFor(a).enter();
        jitLockFor(b).enter();
        afterBothEnter = anyJITInProgress();
        jitLockFor(a).clear();
        afterClearA = anyJITInProgress();
        jitLockFor(b).clear();
        afterClearB = anyJITInProgress();
    }
}

/// @title JITLockTest
/// @notice Isolated unit tests for the `JITLock` transient reentrancy-lock type, covering the
///         per-pool lock, the global in-flight counter, and the cross-pool guard, without standing
///         up a full hook. Passes under both default and `--isolate` execution (see the harness).
contract JITLockTest is Test {
    JITLockHarness internal h;

    PoolId internal poolA = PoolId.wrap(bytes32(uint256(0xA)));
    PoolId internal poolB = PoolId.wrap(bytes32(uint256(0xB)));

    function setUp() public {
        h = new JITLockHarness();
    }

    function test_enter_setsInProgress() public {
        assertTrue(h.enterAndReport(poolA), "in-flight after enter");
    }

    function test_clear_resetsInProgress() public {
        assertFalse(h.enterClearAndReport(poolA), "idle again after clear");
    }

    function test_enter_rejectsSamePoolReentry() public {
        vm.expectRevert(JITInProgress.selector);
        h.enterTwice(poolA);
    }

    /// @dev The global counter is the cross-pool guard: an in-flight cycle on pool A makes
    ///      `requireJITNotInProgress` revert for any entry point, even one targeting a different
    ///      pool. This is the path a per-pool lock alone would miss (e.g. a vault callback during
    ///      pool A's cycle calling `addLiquidity` on pool B).
    function test_requireNotInProgress_revertsWhileCycleInFlight() public {
        vm.expectRevert(JITInProgress.selector);
        h.enterThenRequireNotInProgress(poolA);
    }

    function test_requireNotInProgress_passesWhenIdleAndAfterCycle() public {
        h.requireNotInProgressIdleThenCycle(poolA); // no revert
    }

    function test_distinctPools_independentLocks_sharedCounter() public {
        (bool afterBothEnter, bool afterClearA, bool afterClearB) = h.twoPoolLifecycle(poolA, poolB);
        assertTrue(afterBothEnter, "both cycles in flight");
        assertTrue(afterClearA, "pool B still in flight after clearing A");
        assertFalse(afterClearB, "idle once all cycles clear");
    }

    function testFuzz_jitLockFor_isDeterministicAndPerPool(bytes32 a, bytes32 b) public pure {
        PoolId idA = PoolId.wrap(a);
        PoolId idB = PoolId.wrap(b);
        assertEq(JITLock.unwrap(jitLockFor(idA)), JITLock.unwrap(jitLockFor(idA)), "same pool yields same slot");
        if (a != b) {
            assertTrue(
                JITLock.unwrap(jitLockFor(idA)) != JITLock.unwrap(jitLockFor(idB)),
                "distinct pools yield distinct slots"
            );
        }
    }
}
