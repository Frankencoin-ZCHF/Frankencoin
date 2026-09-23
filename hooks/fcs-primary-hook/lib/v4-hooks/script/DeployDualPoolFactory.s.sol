// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";
import {AllowlistedFactory} from "../src/AllowlistedFactory.sol";
import {DualPoolHook} from "../src/alf/DualPoolHook.sol";

/// @title DeployDualPoolFactory
/// @author Uniswap Labs
/// @notice Deploys the DualPool hook family's canonical `AllowlistedFactory`, pinned to the CURRENT
///         build of `DualPoolHook`.
///         The factory is the discovery anchor for aggregators and third-party routers, so it is
///         deployed through the canonical CREATE2 proxy (`0x4e59…`) with a fixed salt: the same
///         factory bytecode and salt resolve to the same address on every chain. For a vanity
///         (leading-zero) factory address, mine `FACTORY_SALT` offchain with
///         `script/mine_factory_salt.sh`; the salt is re-derived and checked here for the
///         `MIN_LEADING_ZERO_NIBBLES` prefix before any broadcast, so a stale or wrong-build salt
///         fails fast. Unlike the hooks there are no permission-flag bits to satisfy.
///
///         The allowlist is immutable. Recompiling a hook (source, compiler version, or settings)
///         changes its creation-code hash and requires a NEW factory deployment; that is the
///         mechanism that keeps `isFromFactory` meaning "bit-exact known bytecode".
///
///         After deploying the factory, mine hook salts against ITS address
///         (`FACTORY=0x… script/mine_dualpool_salt.sh`) and deploy hooks through
///         `DeployDualPoolHook.s.sol`.
///
/// @dev Env:
///        FACTORY_SALT            (default bytes32(0)) CREATE2 salt for the factory itself, mined
///                                by `script/mine_factory_salt.sh`. Keep it fixed across chains so
///                                the factory address matches everywhere.
///        MIN_LEADING_ZERO_NIBBLES(default 0) required leading-zero hex digits of the factory
///                                address. Set to the value the salt was mined for (miner default 6).
///
///      Run (dry): forge script script/DeployDualPoolFactory.s.sol
///      Broadcast: append --rpc-url $RPC_URL --broadcast (and a --private-key / --account signer).
contract DeployDualPoolFactory is Script {
    /// @dev The canonical deterministic-deployment proxy forge routes `new{salt}` through; the mined
    ///      salt assumes this as the CREATE2 deployer.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external returns (AllowlistedFactory factory) {
        bytes32 factorySalt = vm.envOr("FACTORY_SALT", bytes32(0));
        uint256 zeroNibbles = vm.envOr("MIN_LEADING_ZERO_NIBBLES", uint256(0));

        // Pin the allowlist to the current builds. The factory stores a set, but the array order
        // is part of the constructor-arg encoding and therefore the CREATE2 address: it MUST match
        // `script/mine_factory_salt.sh` or a mined FACTORY_SALT resolves to a different address.
        bytes32[] memory creationCodeHashes = new bytes32[](1);
        creationCodeHashes[0] = keccak256(type(DualPoolHook).creationCode);

        console2.log("DualPoolHook creation-code hash:");
        console2.logBytes32(creationCodeHashes[0]);

        // Re-derive the address the salt resolves to and fail before broadcasting if it does not
        // satisfy the vanity constraint (same fail-fast pattern as the hook deploy scripts).
        bytes memory initCode = abi.encodePacked(type(AllowlistedFactory).creationCode, abi.encode(creationCodeHashes));
        address expected = HookMiner.computeAddress(CREATE2_DEPLOYER, uint256(factorySalt), initCode);
        _requireLeadingZeros(expected, zeroNibbles);

        console2.log("init-code hash:");
        console2.logBytes32(keccak256(initCode));
        console2.log("expected address:", expected);
        console2.log("salt:");
        console2.logBytes32(factorySalt);

        vm.broadcast();
        factory = new AllowlistedFactory{salt: factorySalt}(creationCodeHashes);

        require(address(factory) == expected, "DeployDualPoolFactory: address mismatch");
        _requireLeadingZeros(address(factory), zeroNibbles);

        // Sanity: the allowlist round-trips before anyone mines salts against this factory.
        require(factory.isAllowedCreationCode(creationCodeHashes[0]), "DeployDualPoolFactory: allowlist mismatch");
        require(factory.allDeploymentsLength() == 0, "DeployDualPoolFactory: dirty registry");

        console2.log("AllowlistedFactory (DualPool family) deployed at:", address(factory));
        console2.log("Mine hook salts with: FACTORY=<address above> script/mine_dualpool_salt.sh");
    }

    /// @dev Require the top `zeroNibbles` hex digits of the address to be zero.
    function _requireLeadingZeros(address a, uint256 zeroNibbles) internal pure {
        if (zeroNibbles == 0) return;
        require(zeroNibbles <= 40, "DeployDualPoolFactory: zeroNibbles > 40");
        require(uint160(a) >> (160 - 4 * zeroNibbles) == 0, "DeployDualPoolFactory: missing leading zero nibbles");
    }
}
