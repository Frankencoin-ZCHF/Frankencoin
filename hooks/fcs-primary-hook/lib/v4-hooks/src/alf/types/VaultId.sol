// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title VaultId
/// @author Uniswap Labs
/// @notice User-defined value type identifying a vault within a `Shares` ledger.
///         32-byte opaque key; equality is identity. Consumer conventions determine how
///         the key is derived (e.g., PoolVault uses `PoolId.unwrap(key.toId())`; a generic
///         deployer might use `keccak256(abi.encode(asset0, asset1, salt))`).
/// @dev    Type-safe wrapper around `bytes32` so callers can't accidentally pass a random
///         hash where a vault key is expected. Pure value type: no storage, no methods
///         beyond equality and conversion via `wrap`/`unwrap`.
type VaultId is bytes32;

using {eq as ==, neq as !=} for VaultId global;

function eq(VaultId a, VaultId b) pure returns (bool) {
    return VaultId.unwrap(a) == VaultId.unwrap(b);
}

function neq(VaultId a, VaultId b) pure returns (bool) {
    return VaultId.unwrap(a) != VaultId.unwrap(b);
}
