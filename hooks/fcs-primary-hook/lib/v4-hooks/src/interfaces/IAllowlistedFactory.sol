// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IAllowlistedFactory
/// @author Uniswap Labs
/// @notice A CREATE2 deployer and discovery registry restricted to an immutable allowlist of
///         creation-code hashes. Deployed for the DualPool hook family so aggregators and
///         third-party routers can find and verify hooks, but generic: it works for any
///         contract whose creation code is pinned at factory construction.
///
///         Integrators discover deployments in two ways:
///           - Offchain: index {Deployed} events from the factory.
///           - Onchain: enumerate {allDeployments} / {allDeploymentsLength}, or verify a
///             candidate address with {isFromFactory}.
///
///         Provenance, not endorsement: a registered address is a bit-exact build of
///         allowlisted bytecode, but deployment is permissionless and constructor arguments
///         (including any owner) are the deployer's choice. Integrators must still evaluate
///         the operator behind a deployment.
interface IAllowlistedFactory {
    /// @notice Emitted for every contract deployed through the factory. The primary offchain
    ///         discovery signal.
    /// @param deployed         The deployed contract address.
    /// @param creationCodeHash keccak256 of the creation code; identifies which allowlisted
    ///                         contract was deployed, and therefore the ABI shape of
    ///                         `constructorArgs` (decode offchain against that contract's
    ///                         constructor, e.g. `(address, uint32, address, uint64)` for the
    ///                         DualPool hook family: PoolManager, maxGas, owner,
    ///                         maxMinDepositBlocks).
    /// @param deployer         The account that called {deploy}.
    /// @param constructorArgs  The ABI-encoded constructor arguments used.
    /// @param salt             The CREATE2 salt used (for v4 hooks, mined for permission flags
    ///                         and vanity prefix).
    event Deployed(
        address indexed deployed,
        bytes32 indexed creationCodeHash,
        address indexed deployer,
        bytes constructorArgs,
        bytes32 salt
    );

    /// @notice The supplied creation code's hash is not on the factory's allowlist.
    /// @param creationCodeHash keccak256 of the rejected creation code.
    error CreationCodeNotAllowed(bytes32 creationCodeHash);

    /// @notice The factory was constructed with an empty or zero-valued allowlist entry.
    error InvalidAllowlist();

    /// @notice Deploy allowlisted creation code via CREATE2 and register the result.
    /// @dev    The caller supplies the creation code because allowlisted contracts may sit near
    ///         the EIP-170 size limit: embedding their creation code in the factory's runtime
    ///         would be impossible, so it is passed in and pinned by hash instead. Constructor
    ///         arguments are opaque to the factory; the CREATE2 init code is
    ///         `abi.encodePacked(creationCode, constructorArgs)`, exactly what a direct
    ///         `new Contract{salt: salt}(...)` would run, and malformed arguments revert inside
    ///         the constructor. For v4 hooks, the hook's own constructor (BaseHook) validates
    ///         that the resulting address encodes the correct permission flags, so a salt not
    ///         mined against this factory reverts here.
    /// @param creationCode    Creation code of an allowlisted contract, e.g.
    ///                        `type(DualPoolHook).creationCode`.
    /// @param constructorArgs ABI-encoded constructor arguments for that contract.
    /// @param salt            CREATE2 salt; this factory is the CREATE2 deployer
    ///                        (see `script/mine_dualpool_salt.sh` for hook salt mining).
    /// @return deployed The deployed contract address.
    function deploy(bytes calldata creationCode, bytes calldata constructorArgs, bytes32 salt)
        external
        returns (address deployed);

    /// @notice Predict the address {deploy} would deploy to for the given inputs.
    /// @param creationCode    Creation code of the contract.
    /// @param constructorArgs ABI-encoded constructor arguments.
    /// @param salt            CREATE2 salt.
    /// @return deployed The counterfactual address.
    function computeAddress(bytes calldata creationCode, bytes calldata constructorArgs, bytes32 salt)
        external
        view
        returns (address deployed);

    /// @notice Whether a creation-code hash is deployable through this factory.
    /// @param creationCodeHash keccak256 of a contract's creation code.
    /// @return allowed True if {deploy} accepts creation code with this hash.
    function isAllowedCreationCode(bytes32 creationCodeHash) external view returns (bool allowed);

    /// @notice The creation-code hash a registered contract was deployed from.
    /// @param deployed A deployed contract address.
    /// @return creationCodeHash keccak256 of its creation code, or `bytes32(0)` if the address
    ///                          was not deployed by this factory.
    function creationCodeHashOf(address deployed) external view returns (bytes32 creationCodeHash);

    /// @notice Whether an address was deployed by this factory.
    /// @param deployed The address to check.
    /// @return True if {deploy} deployed it.
    function isFromFactory(address deployed) external view returns (bool);

    /// @notice The contract deployed at position `index`, in deployment order.
    /// @param index Position in the registry, `< allDeploymentsLength()`.
    /// @return deployed The contract address.
    function allDeployments(uint256 index) external view returns (address deployed);

    /// @notice Total number of contracts deployed through this factory.
    /// @return Number of registry entries, for onchain enumeration of {allDeployments}.
    function allDeploymentsLength() external view returns (uint256);
}
