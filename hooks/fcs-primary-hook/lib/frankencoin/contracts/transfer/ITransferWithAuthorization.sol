// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "../erc20/IERC20.sol";

/**
 * @title ITransferWithAuthorization
 * @notice Interface for the EIP-3009 gasless transfer sidecar for the Frankencoin (ZCHF) stablecoin.
 */
interface ITransferWithAuthorization {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);
    event AuthorizationCanceled(address indexed authorizer, bytes32 indexed nonce);

    /// @dev Emitted when the EIP-712 domain may have changed (ERC-5267).
    event EIP712DomainChanged();

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error AlreadyInitialized();
    error AuthorizationNotYetValid();
    error AuthorizationExpired();
    error AuthorizationAlreadyUsed();
    error InvalidSignature();
    error CallerMustBeDeployer();
    error CallerMustBePayee();

    // -------------------------------------------------------------------------
    // EIP-712 type hashes
    // -------------------------------------------------------------------------

    // keccak256("TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
    function TRANSFER_WITH_AUTHORIZATION_TYPEHASH() external view returns (bytes32);

    // keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
    function RECEIVE_WITH_AUTHORIZATION_TYPEHASH() external view returns (bytes32);

    // keccak256("CancelAuthorization(address authorizer,bytes32 nonce)")
    function CANCEL_AUTHORIZATION_TYPEHASH() external view returns (bytes32);

    // -------------------------------------------------------------------------
    // Read-only
    // -------------------------------------------------------------------------

    function initialize(IERC20 _asset) external;

    function asset() external view returns (IERC20);

    function balanceOf(address account) external view returns (uint256);

    function DOMAIN_SEPARATOR() external view returns (bytes32);

    /**
     * @notice Returns the fields and values that describe the domain separator used for EIP-712 signing (ERC-5267).
     * @return fields   Bitmap where bit i is set if domain field i is present (name=0, version=1, chainId=2, verifyingContract=3, salt=4).
     * @return name     Domain name.
     * @return version  Domain version.
     * @return chainId  Chain ID.
     * @return verifyingContract  Address of this contract.
     * @return salt     Not used; always zero.
     * @return extensions  Not used; always empty.
     */
    function eip712Domain() external view returns (bytes1 fields, string memory name, string memory version, uint256 chainId, address verifyingContract, bytes32 salt, uint256[] memory extensions);

    /// @notice Returns the state of an authorization
    /// @dev Nonces are randomly generated 32-byte data unique to the authorizer's address
    /// @param authorizer Authorizer's address
    /// @param nonce Nonce of the authorization
    /// @return True if the nonce is used
    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool);

    // -------------------------------------------------------------------------
    // Authorization functions
    // -------------------------------------------------------------------------

    /// @notice Execute a transfer with a signed authorization
    /// @param from         Payer's address (Authorizer)
    /// @param to           Payee's address
    /// @param value        Amount to be transferred
    /// @param validAfter   The time after which this is valid (unix time)
    /// @param validBefore  The time before which this is valid (unix time)
    /// @param nonce        Unique nonce
    /// @param v            v of the signature
    /// @param r            r of the signature
    /// @param s            s of the signature
    function transferWithAuthorization(address from, address to, uint256 value, uint256 validAfter, uint256 validBefore, bytes32 nonce, uint8 v, bytes32 r, bytes32 s) external;

    /**
     * @notice Receive a transfer with a signed authorization from the payer
     * @dev This has an additional check to ensure that the payee's address matches
     * the caller of this function to prevent front-running attacks. (See security
     * considerations)
     * @param from          Payer's address (Authorizer)
     * @param to            Payee's address
     * @param value         Amount to be transferred
     * @param validAfter    The time after which this is valid (unix time)
     * @param validBefore   The time before which this is valid (unix time)
     * @param nonce         Unique nonce
     * @param v             v of the signature
     * @param r             r of the signature
     * @param s             s of the signature
     */
    function receiveWithAuthorization(address from, address to, uint256 value, uint256 validAfter, uint256 validBefore, bytes32 nonce, uint8 v, bytes32 r, bytes32 s) external;

    /// @notice Attempt to cancel an authorization
    /// @param authorizer   Authorizer's address
    /// @param nonce        Nonce of the authorization
    /// @param v            v of the signature
    /// @param r            r of the signature
    /// @param s            s of the signature
    function cancelAuthorization(address authorizer, bytes32 nonce, uint8 v, bytes32 r, bytes32 s) external;
}
