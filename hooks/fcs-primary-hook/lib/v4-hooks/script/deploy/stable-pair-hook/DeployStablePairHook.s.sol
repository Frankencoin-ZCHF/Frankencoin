// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";
import {StablePairHook} from "../../../src/stable/StablePairHook.sol";
import {BaseDynamicFeeHook} from "../../../src/base/BaseDynamicFeeHook.sol";
import {Parameters, DeployParameters} from "./Parameters.sol";

/// @notice Deploys the StablePairHook implementation and its ERC1967 proxy. The proxy is the
///         registered v4 hook, so its address (not the implementation's) is mined for the flags.
contract DeployStablePairHookScript is Script, Parameters {
    error AddressMismatch(address deployed, address expected);
    error FlagsMismatch(address deployed, uint160 flags);
    error RolesNotSetForChainId(uint256 chainId);
    error ImplementationMismatch(address current, address expected);
    error RolesMismatch(address proxy);

    /// @dev Must match BaseDynamicFeeHook.getHookPermissions(); the proxy's mined address freezes
    ///      this flag set forever
    uint160 public constant STABLE_PAIR_HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );

    function run() public returns (address) {
        DeployParameters memory params = getParameters(block.chainid);

        if (params.owner == address(0) || params.poolInitializer == address(0) || params.configManager == address(0)) {
            revert RolesNotSetForChainId(block.chainid);
        }

        // Step 1: Deploy the implementation via CREATE2 so reruns reuse the same address. Its salt
        // is mined so the address carries no hook-flag bits
        bytes memory implementationConstructorArgs = abi.encode(params.poolManager);
        (address implementation, bytes32 implementationSalt) = _resolveCreate2Address(
            params.stablePairHookImplementationSalt,
            uint160(0),
            type(StablePairHook).creationCode,
            implementationConstructorArgs,
            "implementation"
        );
        if (implementation.code.length == 0) {
            vm.broadcast();
            StablePairHook deployedImplementation = new StablePairHook{salt: implementationSalt}(params.poolManager);
            if (address(deployedImplementation) != implementation) {
                revert AddressMismatch(address(deployedImplementation), implementation);
            }
            console2.log("StablePairHook implementation deployed to:", implementation);
        } else {
            console2.log("Reusing existing StablePairHook implementation at:", implementation);
        }

        // Step 2: Deploy the proxy at a mined hook address, initializing the roles atomically
        bytes memory initializeCall =
            abi.encodeCall(BaseDynamicFeeHook.initialize, (params.owner, params.poolInitializer, params.configManager));
        bytes memory proxyConstructorArgs = abi.encode(implementation, initializeCall);

        (address expectedAddress, bytes32 salt) = _resolveCreate2Address(
            params.stablePairHookProxySalt,
            STABLE_PAIR_HOOK_FLAGS,
            type(ERC1967Proxy).creationCode,
            proxyConstructorArgs,
            "proxy"
        );

        if (expectedAddress.code.length > 0) {
            address currentImplementation =
                address(uint160(uint256(vm.load(expectedAddress, ERC1967Utils.IMPLEMENTATION_SLOT))));
            if (currentImplementation != implementation) {
                revert ImplementationMismatch(currentImplementation, implementation);
            }
            StablePairHook existing = StablePairHook(expectedAddress);
            if (
                !existing.hasRole(existing.DEFAULT_ADMIN_ROLE(), params.owner)
                    || !existing.hasRole(existing.POOL_INITIALIZER_ROLE(), params.poolInitializer)
                    || !existing.hasRole(existing.CONFIG_MANAGER_ROLE(), params.configManager)
            ) {
                revert RolesMismatch(expectedAddress);
            }
            console2.log("Skipping deployment, StablePairHook proxy already exists at:", expectedAddress);
            return expectedAddress;
        }

        vm.broadcast();
        ERC1967Proxy proxy = new ERC1967Proxy{salt: salt}(implementation, initializeCall);

        // Matching expectedAddress also pins the flags: they were verified when it was resolved
        if (address(proxy) != expectedAddress) {
            revert AddressMismatch(address(proxy), expectedAddress);
        }

        console2.log("StablePairHook (proxy) deployed to:", address(proxy));
        return address(proxy);
    }

    /// @notice Resolves the CREATE2 address for `creationCode` + `constructorArgs`: uses the
    ///         cached salt when set, otherwise mines one whose address encodes exactly `flags`.
    ///         Either way, the resolved address' flag bits are verified before it is used.
    function _resolveCreate2Address(
        bytes32 cachedSalt,
        uint160 flags,
        bytes memory creationCode,
        bytes memory constructorArgs,
        string memory label
    ) internal view returns (address expected, bytes32 salt) {
        console2.log(string.concat(label, " init code hash (for external salt mining):"));
        console2.logBytes32(keccak256(abi.encodePacked(creationCode, constructorArgs)));

        if (cachedSalt != bytes32(0)) {
            // Use the cached salt for a deterministic address
            salt = cachedSalt;
            expected = HookMiner.computeAddress(
                CREATE2_DEPLOYER, uint256(salt), abi.encodePacked(creationCode, constructorArgs)
            );
        } else {
            (expected, salt) = HookMiner.find(CREATE2_DEPLOYER, flags, creationCode, constructorArgs);
            console2.log(
                string.concat("Mined ", label, " salt (cache it in Parameters.sol for deterministic deployments):")
            );
            console2.logBytes32(salt);
        }
        if (uint160(expected) & Hooks.ALL_HOOK_MASK != flags) revert FlagsMismatch(expected, flags);
    }
}
