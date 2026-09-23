// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Emitted when a pool's external-deposit gate changes.
/// @param poolId  The pool whose gate changed.
/// @param enabled Whether non-owner deposits are permitted.
event ExternalDepositsUpdated(PoolId indexed poolId, bool enabled);

/// @title DepositGate
/// @author Uniswap Labs
/// @notice Per-pool gate for whether non-owner addresses may deposit, as a type-driven value. The
///         gate is set at pool initialization and toggled by the owner thereafter. The consumer
///         combines {isOpen} with its own owner check to authorize a deposit (the owner can always
///         deposit; non-owners only when the gate is open), and re-exposes per-pool state through
///         its `externalDepositsEnabled` getter.
/// @param _inner Whether each pool permits non-owner deposits.
/// @custom:security-contact security@uniswap.org
struct DepositGate {
    mapping(PoolId poolId => bool) _inner;
}

using {isOpen, setOpen} for DepositGate global;

/// @notice Whether `poolId` permits non-owner deposits.
/// @param self   DepositGate storage.
/// @param poolId The pool to read.
/// @return Whether non-owner deposits are currently permitted.
function isOpen(DepositGate storage self, PoolId poolId) view returns (bool) {
    return self._inner[poolId];
}

/// @notice Set `poolId`'s deposit gate and emit {ExternalDepositsUpdated}.
/// @param self    DepositGate storage.
/// @param poolId  The pool to toggle.
/// @param enabled The new gate state.
function setOpen(DepositGate storage self, PoolId poolId, bool enabled) {
    self._inner[poolId] = enabled;
    emit ExternalDepositsUpdated(poolId, enabled);
}
