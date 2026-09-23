// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolConfig} from "../types/BookConfig.sol";
import {PositionInfo} from "../types/BookPositions.sol";

/// @title INativeBookQuoterSource
/// @author Uniswap Labs
/// @notice Minimal read interface used by `NativeBookQuoter` to inspect a NativeBook hook's
///         book state: per-pool liveness and configuration, the pool-scoped active position
///         index, the bounded-retirement cursor, and per-position metadata.
/// @custom:security-contact security@uniswap.org
interface INativeBookQuoterSource {
    /// @notice Whether `poolId` is currently quoting and executing swaps.
    /// @param poolId Pool being queried.
    /// @return live True if the pool is live.
    function livePools(PoolId poolId) external view returns (bool live);

    /// @notice Return canonical native-book configuration for a pool.
    /// @param poolId Pool being queried.
    /// @return config The pool's book configuration.
    function poolConfigs(PoolId poolId) external view returns (PoolConfig memory config);

    /// @notice Return metadata for a hook-owned maker position.
    /// @param positionId Position id being queried.
    /// @return info The position metadata. An untracked id returns the zero struct.
    function positions(bytes32 positionId) external view returns (PositionInfo memory info);

    /// @notice Return a pool's active position id at an index.
    /// @param poolId Pool being queried.
    /// @param index Zero-based active position index.
    /// @return positionId Active position id at `index`.
    function activePositionAt(PoolId poolId, uint256 index) external view returns (bytes32 positionId);

    /// @notice Return the number of active position ids tracked for a pool.
    /// @param poolId Pool being queried.
    /// @return count Number of active position ids.
    function activePositionCount(PoolId poolId) external view returns (uint256 count);

    /// @notice Return the pool's bounded retirement cursor.
    /// @param poolId Pool being queried.
    /// @return cursor Current cursor into the pool's active position ids.
    function retireCursor(PoolId poolId) external view returns (uint256 cursor);
}
