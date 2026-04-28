// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IModule
 * @notice Minimal interface that minting modules registered in the ModuleRegistry should implement.
 * @dev Kept intentionally small so future versions can extend it without breaking existing modules.
 *      The registry does not enforce this interface at proposal time; it is a convention for
 *      discoverability and off-chain tooling.
 */
interface IModule {
    /**
     * @notice Human-readable name of the module, used for identification in UIs and indexers.
     * @return The module name string.
     */
    function name() external view returns (string memory);
}
