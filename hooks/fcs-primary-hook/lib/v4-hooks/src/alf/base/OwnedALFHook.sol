// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {BaseALFHook} from "./BaseALFHook.sol";
import {IALFHook} from "../interfaces/IALFHook.sol";
import {Liveness} from "../types/Liveness.sol";

/// @title OwnedALFHook
/// @author Uniswap Labs
/// @notice Shared owner-administered ALF base for hooks that run a fixed-config, per-pool-liveness
///         model (DualPoolHook and the SpreadQuoter family). Layers `Ownable2Step` with
///         `renounceOwnership` disabled, the per-pool `Liveness` capability, and a direct-initialize
///         guard on top of the `BaseALFHook` metadata/settlement surface (`maxGas`, reserves,
///         indicative quoting, the `ALFHookData`/attestation envelope, `DeltaResolver._pay`).
///         Concrete subclasses add their own pricing, distribution / LP gating, and the guarded
///         `initializePool` entry point.
/// @dev Pricing is static per `PoolKey.fee` and immutable post-initialize; the owner has only a
///      per-pool liveness flag for pause/resume. The owner is the single trust principal, so
///      `renounceOwnership` is disabled.
/// @custom:security-contact security@uniswap.org
abstract contract OwnedALFHook is BaseALFHook, Ownable2Step {
    /// @notice Per-pool pause/resume flag. Pools default to paused; the subclass's guarded
    ///         bootstrap/init and its `setPoolLive` toggle it via the `Liveness` capability. Read
    ///         externally through {livePools}.
    Liveness internal _liveness;

    /// @dev Direct `poolManager.initialize` for a pool using this hook is rejected; callers MUST go
    ///      through the subclass's guarded `initializePool` so pricing, distribution, and vault
    ///      config are validated and the pool's initial `sqrtPriceX96` (immutable post-init) cannot
    ///      be front-run by a third party at a price the operator did not choose.
    error DirectInitializeBlocked();

    /// @dev `renounceOwnership` was called. Renouncing would permanently disable every `onlyOwner`
    ///      entry point and orphan every pool referencing this hook. The operator is the single
    ///      trust principal in this model; their continuing presence is load-bearing.
    error RenounceOwnershipDisabled();

    /// @param manager The Uniswap v4 PoolManager.
    /// @param maxGas_ Gas budget declared for `getIndicativeQuote` staticcalls.
    /// @param owner_  Initial contract owner. Transferable via OZ's two-step
    ///                {Ownable2Step.transferOwnership} / {Ownable2Step.acceptOwnership} flow.
    constructor(IPoolManager manager, uint32 maxGas_, address owner_) BaseALFHook(manager, maxGas_) Ownable(owner_) {}

    /// @dev Reject direct `poolManager.initialize`. Per v4 `Hooks.noSelfCall`, the hook's own
    ///      `poolManager.initialize` from `initializePool` skips this callback, so the only caller
    ///      path that reaches here is an external party's direct attempt.
    function _beforeInitialize(address, PoolKey calldata, uint160) internal pure override returns (bytes4) {
        revert DirectInitializeBlocked();
    }

    /// @notice Disabled. The hook's design requires a live owner indefinitely; renouncing would
    ///         permanently brick every `onlyOwner` entry point and orphan every pool referencing
    ///         this hook. Use {Ownable2Step.transferOwnership} to rotate operators instead.
    /// @dev    See {RenounceOwnershipDisabled} for the rationale.
    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }

    /// @inheritdoc IALFHook
    /// @dev Always reports live; hook-level liveness is per-pool via {livePools}. Routers call this
    ///      to reject offline hooks; this hook is always reachable, but individual pools may pause.
    function isLive() external pure override returns (bool) {
        return true;
    }

    /// @notice Whether `poolId` is currently quoting and executing swaps.
    /// @param poolId The pool to read.
    /// @return Whether the pool is live.
    function livePools(PoolId poolId) external view returns (bool) {
        return _liveness.isLive(poolId);
    }
}
