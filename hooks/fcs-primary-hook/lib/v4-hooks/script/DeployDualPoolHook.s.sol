// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";
import {AllowlistedFactory} from "../src/AllowlistedFactory.sol";
import {DualPoolHook} from "../src/alf/DualPoolHook.sol";

/// @title DeployDualPoolHook
/// @author Uniswap Labs
/// @notice Deploys `DualPoolHook` through the DualPool family's `AllowlistedFactory` (see
///         `DeployDualPoolFactory.s.sol`) so aggregators and third-party routers can discover it
///         via the factory's `Deployed` event and registry, and the hook's `factory()` getter
///         reports the canonical factory. The factory CREATE2-deploys the hook, so the address's
///         low 14 bits must carry the hook's permission flags
///         (`address & Hooks.ALL_HOOK_MASK == 0x2ac0`) and, for a live deployment, a leading-zero
///         vanity prefix. The FACTORY is the CREATE2 deployer: salts must be mined against the
///         factory address, and any salt mined for the old direct-deploy path (deployer `0x4e59…`)
///         is invalid here.
///
///         Two salt paths:
///           - `HOOK_SALT` set: use a salt mined offchain by `script/mine_dualpool_salt.sh`
///             (with `FACTORY` set to the same address as here). It is re-derived and checked for
///             BOTH the flag bits and `MIN_LEADING_ZERO_NIBBLES` before any broadcast, so a stale
///             or wrong-args salt fails fast.
///           - `HOOK_SALT` unset AND `MIN_LEADING_ZERO_NIBBLES == 0`: mine the flags-only salt
///             in-EVM via `HookMiner.find` (fine for tests / non-vanity deploys). A non-zero vanity
///             prefix is a ~2^38 search that is infeasible in-EVM, so the script reverts and points
///             at the offchain miner.
///
///         The constructor-arg encoding here MUST match the miner's (`script/mine_dualpool_salt.sh`
///         computes the same init-code hash), or the salt resolves to a different address. The
///         factory additionally requires the creation code's hash to be on its allowlist, so a
///         factory pinned to a different build of `DualPoolHook` rejects this script up front.
///
/// @dev Env:
///        FACTORY                 (required) AllowlistedFactory address (the CREATE2 deployer).
///        POOL_MANAGER            (required) v4 PoolManager address.
///        HOOK_OWNER              (required) initial hook owner.
///        MAX_GAS                 (default 800000) getIndicativeQuote staticcall budget.
///        MAX_MIN_DEPOSIT_BLOCKS  (default 3600) per-deployment deposit-lock ceiling.
///        MIN_LEADING_ZERO_NIBBLES(default 6) required leading-zero hex digits of the address.
///        HOOK_SALT               (optional) offchain-mined salt; omit only for a flags-only deploy.
///
///      Run (dry): FACTORY=0x… POOL_MANAGER=0x… HOOK_OWNER=0x… HOOK_SALT=0x… forge script script/DeployDualPoolHook.s.sol
///      Broadcast: append --rpc-url $RPC_URL --broadcast (and a --private-key / --account signer).
contract DeployDualPoolHook is Script {
    /// @dev DualPoolHook's permission bits (see {DualPoolHook.getHookPermissions}): beforeInitialize
    ///      | beforeAddLiquidity | beforeRemoveLiquidity | beforeSwap | afterSwap == 0x2ac0.
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );

    function run() external returns (DualPoolHook hook) {
        AllowlistedFactory factory = AllowlistedFactory(vm.envAddress("FACTORY"));
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        address owner = vm.envAddress("HOOK_OWNER");
        uint32 maxGas = uint32(vm.envOr("MAX_GAS", uint256(800_000)));
        uint64 maxMinDepositBlocks = uint64(vm.envOr("MAX_MIN_DEPOSIT_BLOCKS", uint256(3_600)));
        uint256 zeroNibbles = vm.envOr("MIN_LEADING_ZERO_NIBBLES", uint256(6));

        // MUST match the miner's encoding exactly (address, uint32, address, uint64).
        bytes memory creationCode = type(DualPoolHook).creationCode;
        bytes memory constructorArgs = abi.encode(poolManager, maxGas, owner, maxMinDepositBlocks);

        // Fail before broadcasting if this build is not the one the factory was pinned to.
        require(
            factory.isAllowedCreationCode(keccak256(creationCode)),
            "DeployDualPoolHook: creation code not allowed by factory (build drift?)"
        );

        (address expected, bytes32 salt) = _resolveSalt(address(factory), creationCode, constructorArgs, zeroNibbles);
        // Fail before broadcasting if the resolved address does not satisfy the constraints.
        _requireFlags(expected);
        _requireLeadingZeros(expected, zeroNibbles);

        console2.log("init-code hash:");
        console2.logBytes32(keccak256(abi.encodePacked(creationCode, constructorArgs)));
        console2.log("expected address:", expected);
        console2.log("salt:");
        console2.logBytes32(salt);

        // Deploy through the factory so the hook is registered for aggregator discovery and its
        // `factory()` getter reports the canonical factory. BaseHook's constructor independently
        // validates the address flags, so a wrong-flag address reverts here.
        vm.broadcast();
        hook = DualPoolHook(factory.deploy(creationCode, constructorArgs, salt));

        require(address(hook) == expected, "DeployDualPoolHook: address mismatch");
        _requireFlags(address(hook));
        _requireLeadingZeros(address(hook), zeroNibbles);
        require(hook.factory() == address(factory), "DeployDualPoolHook: factory() mismatch");
        require(factory.isFromFactory(address(hook)), "DeployDualPoolHook: not registered");

        console2.log("DualPoolHook deployed at:", address(hook));
    }

    /// @dev Resolve the salt: verify an offchain-mined `HOOK_SALT`, else mine flags-only in-EVM.
    ///      A mined salt is never zero (its trailing bytes are the nonce), so `bytes32(0)` is the
    ///      "not provided" sentinel. The factory is the CREATE2 deployer in both paths.
    function _resolveSalt(address factory, bytes memory creationCode, bytes memory constructorArgs, uint256 zeroNibbles)
        internal
        view
        returns (address expected, bytes32 salt)
    {
        salt = vm.envOr("HOOK_SALT", bytes32(0));
        if (salt != bytes32(0)) {
            expected = HookMiner.computeAddress(factory, uint256(salt), abi.encodePacked(creationCode, constructorArgs));
        } else {
            require(
                zeroNibbles == 0,
                "DeployDualPoolHook: set HOOK_SALT (mine with script/mine_dualpool_salt.sh) or MIN_LEADING_ZERO_NIBBLES=0"
            );
            (expected, salt) = HookMiner.find(factory, HOOK_FLAGS, creationCode, constructorArgs);
        }
    }

    /// @dev Require the address's low 14 bits equal the hook flag pattern.
    function _requireFlags(address a) internal pure {
        require(uint160(a) & HookMiner.FLAG_MASK == HOOK_FLAGS, "DeployDualPoolHook: flag bits mismatch");
    }

    /// @dev Require the top `zeroNibbles` hex digits of the address to be zero.
    function _requireLeadingZeros(address a, uint256 zeroNibbles) internal pure {
        if (zeroNibbles == 0) return;
        require(zeroNibbles <= 40, "DeployDualPoolHook: zeroNibbles > 40");
        require(uint160(a) >> (160 - 4 * zeroNibbles) == 0, "DeployDualPoolHook: missing leading zero nibbles");
    }
}
