// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Script.sol";
import {PrefacedHookMiner} from "../../src/utils/PrefacedHookMiner.sol";

/// @notice Mines a CREATE2 salt for arbitrary hook creation code: required hook `flags`, leading address byte, no broadcast
contract MinePrefacedHookScript is Script {
    address internal constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    function setUp() public {}

    /// @param creationCode Contract creation bytecode only (constructor arguments are passed separately, as with `HookMiner.find`)
    /// @param constructorArgs ABI-encoded constructor arguments, or empty if none
    /// @param saltStart Lower bound for salt search; chain windows of PrefacedHookMiner.MAX_LOOP (e.g. script/minePrefacedHook.sh)
    /// @param addressPrefix Required MSB of the hook address (first byte after 0x in canonical hex)
    /// @param flags Bottom 14 bits of the address must match these hook permission flags
    /// @param deployer Address that will perform CREATE2; pass address(0) to use CREATE2_DEPLOYER
    function run(
        bytes memory creationCode,
        bytes memory constructorArgs,
        uint256 saltStart,
        uint8 addressPrefix,
        uint160 flags,
        address deployer
    ) public view {
        address d = deployer == address(0) ? CREATE2_DEPLOYER : deployer;

        (address hookAddress, bytes32 salt) =
            PrefacedHookMiner.find(d, flags, creationCode, constructorArgs, addressPrefix, saltStart);

        console.log("PrefacedHookMiner: deployer", d);
        console.log("PrefacedHookMiner: hookAddress", hookAddress);
        console.logBytes32(salt);
    }
}
