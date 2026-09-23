// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.26;

library HookMiner {
    // Mask to slice out the bottom 14 bit
    uint160 constant FLAG_MASK = 0x3FFF;

    // Maximum number of iterations to find a salt, avoid infinte loops
    uint256 constant MAX_LOOP = 200_000;

    /// @notice Find a salt that produces a hook address with the desired `flags`
    /// @param deployer The address that will deploy the hook. In `forge test`, this will be the test contract
    /// `address(this)` or the pranking address
    ///                 In `forge script`, this should be `0x4e59b44847b379578588920cA78FbF26c0B4956C` (CREATE2 Deployer
    /// Proxy)
    /// @param flags The desired flags for the hook address
    /// @param creationCode The creation code of a hook contract. Example: `type(Hook).creationCode`
    /// @param constructorArgs The encoded constructor arguments of a hook contract. Example:
    /// `abi.encode(address(manager))`
    /// @return hookAddress salt and corresponding address that was found. The salt can be used in `new Hook{salt:
    /// salt}(<constructor arguments>)`
    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        view
        returns (address, bytes32)
    {
        address hookAddress;
        bytes memory creationCodeWithArgs = abi.encodePacked(creationCode, constructorArgs);
        bytes32 keccakOfCreationCodeWithArgs = keccak256(creationCodeWithArgs);

        uint256 salt;
        for (salt; salt < MAX_LOOP; salt++) {
            hookAddress = computeAddress(deployer, salt, keccakOfCreationCodeWithArgs);
            if (uint160(hookAddress) & FLAG_MASK == flags && hookAddress.code.length == 0) {
                return (hookAddress, bytes32(salt));
            }
        }
        revert("HookMiner: could not find salt");
    }

    /// @notice Precompute a contract address deployed via CREATE2
    /// @param deployer The address that will deploy the hook. In `forge test`, this will be the test contract
    /// `address(this)` or the pranking address
    ///                 In `forge script`, this should be `0x4e59b44847b379578588920cA78FbF26c0B4956C` (CREATE2 Deployer
    /// Proxy)
    /// @param salt The salt used to deploy the hook
    /// @param keccakOfCreationCodeWithArgs The creation code of a hook contract
    function computeAddress(address deployer, uint256 salt, bytes32 keccakOfCreationCodeWithArgs)
        internal
        pure
        returns (address hookAddress)
    {
        uint256 fmp; // temporary storage for the value of free memory pointer
        // save free memory pointer
        assembly {
            fmp := mload(0x40)
        }
        // To see how does Create2 work check
        // https://docs.soliditylang.org/en/v0.8.26/control-structures.html#salted-contract-creations-create2
        bytes memory data = abi.encodePacked(bytes1(0xFF), deployer, salt, keccakOfCreationCodeWithArgs);
        hookAddress = address(uint160(uint256(keccak256(data))));
        // restore free memory pointer (otherwise memory usage in Solidity grows and grows with each iteration)
        assembly {
            mstore(0x40, fmp)
        }
    }
}
