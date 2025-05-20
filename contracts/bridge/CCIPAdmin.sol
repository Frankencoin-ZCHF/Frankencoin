// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {IGovernance} from "../equity/IGovernance.sol";
import {ITokenPool} from "./ITokenPool.sol";
import {TokenAdminRegistry} from "@chainlink/contracts-ccip/src/v0.8/ccip/tokenAdminRegistry/TokenAdminRegistry.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/RateLimiter.sol";
import {IBasicFrankencoin} from "../stablecoin/IBasicFrankencoin.sol";
import {RegistryModuleOwnerCustom} from "@chainlink/contracts-ccip/src/v0.8/ccip/tokenAdminRegistry/RegistryModuleOwnerCustom.sol";

// The admin for bridging Frankencoins using CCIP.
// Each chain needs an instance of this administrator.
contract CCIPAdmin {
    struct RemotePoolUpdate {
        bool add; // true if adding, false if removing
        uint64 chain;
        bytes poolAddress;
    }

    uint64 public constant DAY = 24 * 60 * 60;

    IGovernance public immutable GOVERNANCE;
    TokenAdminRegistry public immutable TOKEN_ADMIN_REGISTRY;
    address public immutable ZCHF;

    ITokenPool public tokenPool;
    mapping(bytes32 hash => uint64 deadline) public proposals;

    error TooEarly(uint64 deadline);
    error UnknownProposal(bytes32 hash);
    error ProposalAlreadyMade(bytes32 hash);
    error AlreadyRegistered();
    error TokenPoolNotSet();

    event TokenPoolSet(address indexed tokenPool);

    event ProposalMade(bytes32 hash, uint64 deadline);
    event ProposalDenied(bytes32 hash);
    event ProposalEnacted(bytes32 hash);

    event RemotePoolUpdateProposed(bytes32 hash, address indexed proposer, RemotePoolUpdate update);
    event RemoveChainProposed(bytes32 hash, address indexed proposer, uint64 chain);
    event AddChainProposed(bytes32 hash, address indexed proposer, ITokenPool.ChainUpdate update);
    event AdminTransferProposed(bytes32 hash, address indexed proposer, address newAdmin);

    event RemotePoolAdded(uint64 indexed chain, bytes indexed poolAddress);
    event RemotePoolRemoved(uint64 indexed chain, bytes indexed poolAddress);
    event ChainRemoved(uint64 id);
    event ChainAdded(ITokenPool.ChainUpdate config);
    event AdminTransferred(address newAdmin);
    event RateLimit(uint64 remoteChain, RateLimiter.Config inboundConfigs, RateLimiter.Config outboundConfig);

    modifier onlyQualified(address[] calldata helpers) {
        GOVERNANCE.checkQualified(msg.sender, helpers);
        _;
    }

    modifier tokenPoolSet() {
        if (address(tokenPool) == address(0)) revert TokenPoolNotSet();
        _;
    }

    constructor(TokenAdminRegistry tokenAdminRegistry, IBasicFrankencoin zchf) {
        GOVERNANCE = zchf.reserve();
        TOKEN_ADMIN_REGISTRY = tokenAdminRegistry;
        ZCHF = address(zchf);
    }
    
    /// @notice Registers the token in the CCIP system
    /// @dev Can only be called while the token admin is not set
    /// @param registry The registry to register the token with
    /// @param _tokenPool The token pool to administer
    /// @param chainsToAdd The chains to add to the token pool
    function registerToken(RegistryModuleOwnerCustom registry, ITokenPool _tokenPool, ITokenPool.ChainUpdate[] calldata chainsToAdd) external {
        // This prevents from reregistering the inital ccipAdmin contract after it got superseded by a new version
        if (TOKEN_ADMIN_REGISTRY.getTokenConfig(ZCHF).administrator != address(0)) {
            revert AlreadyRegistered();
        }
        // registerAdminViaGetCCIPAdmin() calls proposeAdministrator() in the background which prevents the existing admin from being set as pending
        registry.registerAdminViaGetCCIPAdmin(ZCHF);
        acceptAdmin(_tokenPool, chainsToAdd);
    }
    
    /// @notice Accepts the admin role transfer on the TokenAdminRegistry and sets the token pool
    /// @dev Can only be called if this contract is the pending owner for the token.
    /// @param _tokenPool The token pool to administer
    /// @param chainsToAdd The chains to add to the token pool
    function acceptAdmin(ITokenPool _tokenPool, ITokenPool.ChainUpdate[] calldata chainsToAdd) public {
        // The token pool can only be reset if this contract is a pending admin again. In this case it could be beneficial to reset the token pool
        TOKEN_ADMIN_REGISTRY.acceptAdminRole(ZCHF);
        setTokenPool(_tokenPool, chainsToAdd);
    }
    
    /// @notice Proposed a remote pool update
    /// @dev The contract only stores the hash. So the data has to be passed in during apply again
    /// @param update  The update proposal
    /// @param helpers The helpers to get enough votes
    function proposeRemotePoolUpdate(RemotePoolUpdate memory update, address[] calldata helpers) external {
        bytes32 hash = keccak256(abi.encode("remotePoolUpdate", update));
        propose(hash, 7, helpers);
        emit RemotePoolUpdateProposed(hash, msg.sender, update);
    }
    
    /// @notice Applies the update on the TokenPool
    /// @dev Requires the token pool to be set
    /// @param update RemotePoolUpdate information
    function applyRemotePoolUpdate(RemotePoolUpdate memory update) external tokenPoolSet {
        enact(keccak256(abi.encode("remotePoolUpdate", update)));
        if (update.add) {
            tokenPool.addRemotePool(update.chain, update.poolAddress);
            emit RemotePoolAdded(update.chain, update.poolAddress);
        } else {
            tokenPool.removeRemotePool(update.chain, update.poolAddress);
            emit RemotePoolRemoved(update.chain, update.poolAddress);
        }
    }
    
    /// @notice Sets the rate limits for the given chain. Any qualified voter can apply rate limits with immediate effect.
    ///         Rate limits can only do limited harm, so it is acceptable to be very permissive. At the same time, rate limits are typically
    ///         applied during emergencies, e.g. when a chain has been hacked. Therefore, it is desirable to ensure that
    ///         they can be applied quickly.
    /// @dev Requires the token pool to be set
    /// @param chain The chain to set the rate limits for
    /// @param inbound The inbound rate limits
    /// @param outbound The outbound rate limits
    /// @param helpers Array of helper addresses for qualification check
    function applyRateLimit(uint64 chain, RateLimiter.Config calldata inbound, RateLimiter.Config calldata outbound, address[] calldata helpers) external onlyQualified(helpers) tokenPoolSet {
        tokenPool.setChainRateLimiterConfig(chain, inbound, outbound);
        emit RateLimit(chain, inbound, outbound);
    }
    
    /// @notice Propose to add or remove remote chains
    /// @dev The contract only stores the hash. So the data has to be passed in during apply again
    /// @param chainId The chain to remove
    /// @param helpers Array of helper addresses for qualification check
    function proposeRemoveChain(uint64 chainId, address[] calldata helpers) external {
        bytes32 hash = keccak256(abi.encode("removeChain", chainId));
        propose(hash, 7, helpers);
        emit RemoveChainProposed(hash, msg.sender, chainId);
    }
    
    /// @notice Applies the remove chain proposal
    /// @dev Requires the token pool to be set
    /// @param chainId The chain to remove
    function applyRemoveChain(uint64 chainId) external tokenPoolSet {
        enact(keccak256(abi.encode("removeChain", chainId)));
        uint64[] memory chainsToRemove = new uint64[](1);
        chainsToRemove[0] = chainId;
        ITokenPool.ChainUpdate[] memory chainsToAdd = new ITokenPool.ChainUpdate[](0);
        tokenPool.applyChainUpdates(chainsToRemove, chainsToAdd);
        emit ChainRemoved(chainId);
    }
    
    /// @notice Propose to add a remote chains
    /// @dev The contract only stores the hash. So the data has to be passed in during apply again
    /// @param config The chain configuration
    /// @param helpers Array of helper addresses for qualification check
    function proposeAddChain(ITokenPool.ChainUpdate calldata config, address[] calldata helpers) external {
        bytes32 hash = keccak256(abi.encode("addChain", config));
        propose(hash, 7, helpers);
        emit AddChainProposed(hash, msg.sender, config);
    }
    
    /// @notice Applies the remote chain update
    /// @dev Requires the token pool to be set
    /// @param config RemoteChainUpdate information
    function applyAddChain(ITokenPool.ChainUpdate memory config) external tokenPoolSet {
        enact(keccak256(abi.encode("addChain", config)));
        uint64[] memory chainsToRemove = new uint64[](0);
        ITokenPool.ChainUpdate[] memory chainsToAdd = new ITokenPool.ChainUpdate[](1);
        chainsToAdd[0] = config;
        tokenPool.applyChainUpdates(chainsToRemove, chainsToAdd);
        emit ChainAdded(config);
    }
    
    /// @notice Proposed a new admin for the TokenPool and Admin on the Token registry
    /// @param newAdmin  The address of the new admin
    /// @param helpers Array of helper addresses for qualification check
    function proposeAdminTransfer(address newAdmin, address[] calldata helpers) external {
        bytes32 hash = keccak256(abi.encode("adminTransfer", newAdmin));
        propose(hash, 21, helpers);
        emit AdminTransferProposed(hash, msg.sender, newAdmin);
    }
    
    /// @notice Applies the admin transfer
    /// @dev Transfers admin on the TokenPool and ownership on the ZCHF token on the TokenAdminRegistry
    /// @param newAdmin The address of the new admin
    function applyAdminTransfer(address newAdmin) external {
        enact(keccak256(abi.encode("adminTransfer", newAdmin)));
        TOKEN_ADMIN_REGISTRY.transferAdminRole(ZCHF, newAdmin);
        if (address(tokenPool) != address(0)) tokenPool.transferOwnership(newAdmin);
        emit AdminTransferred(newAdmin);
    }
    
    /// @notice Denies and removes a pending proposal
    /// @dev Only qualified voters can deny proposals
    /// @param hash The hash of the proposal to deny
    /// @param helpers Array of helper addresses for qualification check
    function deny(bytes32 hash, address[] calldata helpers) external onlyQualified(helpers) {
        if (proposals[hash] == 0) revert UnknownProposal(hash);
        delete proposals[hash];
        emit ProposalDenied(hash);
    }
    
    /// @notice Enacts a pending proposal
    /// @param hash The hash of the proposal to enact
    function enact(bytes32 hash) internal {
        uint64 deadline = proposals[hash];
        if (deadline == 0) revert UnknownProposal(hash);
        if (deadline > block.timestamp) revert TooEarly(deadline);
        delete proposals[hash];
        emit ProposalEnacted(hash);
    }
    
    /// @notice Creates a new proposal with a delay period
    /// @dev Only qualified voters can create proposals
    /// @param hash The hash of the proposal data
    /// @param delayInDays Number of days to delay the proposal execution
    /// @param helpers Array of helper addresses for qualification check
    function propose(bytes32 hash, uint64 delayInDays, address[] calldata helpers) internal onlyQualified(helpers) {
        if (proposals[hash] > 0) revert ProposalAlreadyMade(hash);
        proposals[hash] = uint64(block.timestamp) + delayInDays * DAY;
        emit ProposalMade(hash, proposals[hash]);
    }
    
    /// @notice Sets the token pool to administer, sets it in the TokenAdminRegistry, accept ownership, and applies the chain updates
    /// @dev The token pool needs to have this contract as pending owner
    /// @param _tokenPool The token pool to set
    /// @param chainsToAdd The chains to add to the token pool
    function setTokenPool(ITokenPool _tokenPool, ITokenPool.ChainUpdate[] calldata chainsToAdd) internal {
        TOKEN_ADMIN_REGISTRY.setPool(ZCHF, address(_tokenPool));
        _tokenPool.acceptOwnership();

        if (chainsToAdd.length > 0) {
            _tokenPool.applyChainUpdates(new uint64[](0), chainsToAdd);
        }

        tokenPool = _tokenPool;
        emit TokenPoolSet(address(_tokenPool));
    }
}
