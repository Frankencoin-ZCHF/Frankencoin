// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Libraries
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

// Interfaces
import {IAllowlistedFactory} from "./interfaces/IAllowlistedFactory.sol";

/// @title AllowlistedFactory
/// @author Uniswap Labs
/// @notice A CREATE2 deployer and discovery registry restricted to an immutable allowlist of
///         creation-code hashes. It is intended to be used with canonical hook implementations:
///         aggregators and third-party routers watch {Deployed} events (or enumerate
///         {allDeployments}) to find new hooks, then follow each hook's `PoolCreated` events for
///         its pools, and each hook points back here via its `factory()` getter so provenance is
///         checkable from either side. Nothing in the contract is hook-specific, so any family
///         of hooks can reuse it by deploying an instance pinned to their hashes.
///
///         ## Why the caller supplies the creation code
///
///         Allowlisted contracts' creation code are not embedded in this factory's own runtime.
///         Instead, it is passed as calldata to {deploy} and accepted only if its keccak256 hash
///         is on the allowlist fixed at construction. Registered deployments are therefore
///         guaranteed to match known implementations. Constructor arguments are just opaque bytes
///         appended to the creation code, so the factory carries no assumptions about any the
///         contract's constructor shape; the allowlisted hash identifies the contract and how to
///         decode its arguments.
///
///         ## Trust model
///
///         The allowlist is immutable: there is no owner and no way to add or remove creation
///         code post-deployment, so `isFromFactory` can never be made to vouch for foreign
///         bytecode. Deployment is permissionless and constructor arguments (including any
///         owner) are the deployer's choice; registration attests bytecode provenance, not
///         operator trustworthiness. New contract versions require a new factory.
///
///         ## CREATE2 and hook salt mining
///
///         This factory is the CREATE2 deployer, so deterministic addresses derive from ITS
///         address. For v4 hooks that means flag/vanity salts must be mined against the factory
///         (see `script/mine_dualpool_salt.sh`), and the hook's BaseHook constructor validates
///         the resulting address's permission flags, so a stale or wrong-deployer salt reverts
///         instead of deploying a broken hook. Deploy transactions are not meaningfully
///         front-runnable: identical inputs produce the identical contract at the identical
///         address, so a sniped deployment only reverts the victim's transaction after the
///         intended contract already exists.
/// @custom:security-contact security@uniswap.org
contract AllowlistedFactory is IAllowlistedFactory {
    /// @inheritdoc IAllowlistedFactory
    mapping(bytes32 creationCodeHash => bool allowed) public override isAllowedCreationCode;

    /// @inheritdoc IAllowlistedFactory
    mapping(address deployed => bytes32 creationCodeHash) public override creationCodeHashOf;

    /// @inheritdoc IAllowlistedFactory
    address[] public override allDeployments;

    /// @param creationCodeHashes keccak256 hashes of the creation code deployable through this
    ///                           factory (e.g. `keccak256(type(DualPoolHook).creationCode)`).
    ///                           Must be non-empty with no zero entries; fixed forever.
    constructor(bytes32[] memory creationCodeHashes) {
        uint256 n = creationCodeHashes.length;
        if (n == 0) revert InvalidAllowlist();
        for (uint256 i; i < n; ++i) {
            bytes32 creationCodeHash = creationCodeHashes[i];
            if (creationCodeHash == bytes32(0)) revert InvalidAllowlist();
            isAllowedCreationCode[creationCodeHash] = true;
        }
    }

    /// @inheritdoc IAllowlistedFactory
    function deploy(bytes calldata creationCode, bytes calldata constructorArgs, bytes32 salt)
        external
        override
        returns (address deployed)
    {
        bytes32 creationCodeHash = keccak256(creationCode);
        if (!isAllowedCreationCode[creationCodeHash]) revert CreationCodeNotAllowed(creationCodeHash);

        // A CREATE2 collision (salt reuse) returns address(0) and Create2.deploy reverts, so a
        // registry entry can never be overwritten.
        deployed = Create2.deploy(0, salt, abi.encodePacked(creationCode, constructorArgs));

        creationCodeHashOf[deployed] = creationCodeHash;
        allDeployments.push(deployed);

        emit Deployed(deployed, creationCodeHash, msg.sender, constructorArgs, salt);
    }

    /// @inheritdoc IAllowlistedFactory
    function computeAddress(bytes calldata creationCode, bytes calldata constructorArgs, bytes32 salt)
        external
        view
        override
        returns (address deployed)
    {
        return Create2.computeAddress(salt, keccak256(abi.encodePacked(creationCode, constructorArgs)));
    }

    /// @inheritdoc IAllowlistedFactory
    function isFromFactory(address deployed) external view override returns (bool) {
        return creationCodeHashOf[deployed] != bytes32(0);
    }

    /// @inheritdoc IAllowlistedFactory
    function allDeploymentsLength() external view override returns (uint256) {
        return allDeployments.length;
    }
}
