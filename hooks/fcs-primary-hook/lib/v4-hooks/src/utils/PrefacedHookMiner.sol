// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @title PrefacedHookMiner
/// @notice a minimal library for mining hook addresses with a fixed leading address byte (same CREATE2 logic as HookMiner)
library PrefacedHookMiner {
    // mask to slice out the bottom 14 bit of the address
    uint160 constant FLAG_MASK = Hooks.ALL_HOOK_MASK; // 0000 ... 0000 0011 1111 1111 1111

    // Maximum number of iterations to find a salt, avoid infinite loops or MemoryOOG
    uint256 constant MAX_LOOP = 160_444;

    /// @notice Find a salt that produces a hook address with the desired `flags` and leading byte `addressPrefix`
    /// @param deployer The address that will deploy the hook. In `forge test`, this will be the test contract `address(this)` or the pranking address
    /// In `forge script`, this should be `0x4e59b44847b379578588920cA78FbF26c0B4956C` (CREATE2 Deployer Proxy)
    /// @param flags The desired flags for the hook address. Example `uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | ...)`
    /// @param creationCode The creation code of a hook contract. Example: `type(Counter).creationCode`
    /// @param constructorArgs The encoded constructor arguments of a hook contract. Example: `abi.encode(address(manager))`
    /// @param addressPrefix The most significant byte of the hook address (the `0xAB` in `0xABcd...`)
    /// @param saltStart Lower bound (inclusive) for the salt search; chain windows of `MAX_LOOP` for long searches (e.g. bash minePrefacedHook.sh)
    /// @return (hookAddress, salt) The hook deploys to `hookAddress` when using `salt` with the syntax: `new Hook{salt: salt}(<constructor arguments>)`
    function find(
        address deployer,
        uint160 flags,
        bytes memory creationCode,
        bytes memory constructorArgs,
        uint8 addressPrefix,
        uint256 saltStart
    ) internal view returns (address, bytes32) {
        flags = flags & FLAG_MASK; // mask for only the bottom 14 bits
        bytes memory creationCodeWithArgs = abi.encodePacked(creationCode, constructorArgs);

        address hookAddress;
        uint256 end = saltStart + MAX_LOOP;
        for (uint256 salt = saltStart; salt < end; salt++) {
            hookAddress = computeAddress(deployer, salt, creationCodeWithArgs);

            // leading byte, bottom 14 bits match flags, and no bytecode at address
            if (
                uint8(uint160(hookAddress) >> 152) == addressPrefix && uint160(hookAddress) & FLAG_MASK == flags
                    && hookAddress.code.length == 0
            ) {
                return (hookAddress, bytes32(salt));
            }
        }
        revert("PrefacedHookMiner: could not find salt");
    }

    /// @notice Precompute a contract address deployed via CREATE2
    /// @param deployer The address that will deploy the hook. In `forge test`, this will be the test contract `address(this)` or the pranking address
    /// In `forge script`, this should be `0x4e59b44847b379578588920cA78FbF26c0B4956C` (CREATE2 Deployer Proxy)
    /// @param salt The salt used to deploy the hook
    /// @param creationCodeWithArgs The creation code of a hook contract, with encoded constructor arguments appended. Example: `abi.encodePacked(type(Counter).creationCode, abi.encode(constructorArg1, constructorArg2))`
    function computeAddress(address deployer, uint256 salt, bytes memory creationCodeWithArgs)
        internal
        pure
        returns (address hookAddress)
    {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), deployer, salt, keccak256(creationCodeWithArgs)))))
        );
    }
}
