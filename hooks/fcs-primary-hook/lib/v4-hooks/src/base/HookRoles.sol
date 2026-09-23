// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

/// @title HookRoles
/// @notice AccessControl base + role identifiers shared by the upgradeable hooks and their
///         configuration mixins.
/// @dev Role hierarchy: DEFAULT_ADMIN_ROLE is the role admin of CONFIG_MANAGER_ROLE,
///      POOL_INITIALIZER_ROLE, and itself — it alone grants and revokes roles. The two
///      operational roles hold only their own operational powers, not role administration.
/// @custom:security-contact security@uniswap.org
abstract contract HookRoles is AccessControlUpgradeable {
    /// @notice Role permitted to update pool fee configuration
    /// @dev keccak256("CONFIG_MANAGER_ROLE")
    bytes32 public constant CONFIG_MANAGER_ROLE = 0xbbfb55d933c2bfa638763473275b1d84c4418e58d26cf9d2cd5758237756d9f0;
    /// @notice Role permitted to initialize pools
    /// @dev keccak256("POOL_INITIALIZER_ROLE")
    bytes32 public constant POOL_INITIALIZER_ROLE = 0x57040554eeb1644881e12709b5b3f4551135b4c3895f51421ab6ce98a9be00bd;
}
