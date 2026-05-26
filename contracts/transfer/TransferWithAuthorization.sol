// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ITransferWithAuthorization, IERC20} from "./ITransferWithAuthorization.sol";

/**
 * @title TransferWithAuthorization
 * @notice EIP-3009 sidecar for the Frankencoin (ZCHF) stablecoin.
 *
 * Approved minters on the Frankencoin contract hold an implicit infinite allowance over
 * every ZCHF balance. This contract leverages that to execute transferFrom on behalf of
 * any holder who signs a valid EIP-3009 authorization — no on-chain approve() required.
 *
 * Deployment steps:
 *   1. Deploy this contract with the ZCHF address.
 *   2. Ensure the deployer holds at least ZCHF.MIN_FEE() in ZCHF (suggestMinter debits it from msg.sender).
 *   3. Call ZCHF.suggestMinter(address(this), ZCHF.MIN_APPLICATION_PERIOD(), ZCHF.MIN_FEE(), "EIP-3009 sidecar").
 *   4. Wait out the application period with no qualified veto from FPS holders.
 *   5. Once ZCHF.isMinter(address(this)) == true, the contract is live.
 */
contract TransferWithAuthorization is ITransferWithAuthorization {
    IERC20 public immutable asset;

    // Hashed at construction time so DOMAIN_SEPARATOR() avoids a string copy + external call on every verification.
    bytes32 private immutable _hashedName;
    bytes32 private immutable _hashedVersion;

    // keccak256("TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = 0x7c7c6cdb67a18743f49ec6fa9b35f50d52ed05cbed4cc592e13b44501c1a2267;

    // keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = 0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8;

    // keccak256("CancelAuthorization(address authorizer,bytes32 nonce)")
    bytes32 public constant CANCEL_AUTHORIZATION_TYPEHASH = 0x158b0a9edf7a828aad02f63cd515c68ef2f50ba807396f6d12842833a1597429;

    /// @notice Returns the state of an authorization
    mapping(address => mapping(bytes32 => bool)) public authorizationState;

    constructor(IERC20 _asset) {
        asset = _asset;
        _hashedName = keccak256(bytes(_asset.name()));
        _hashedVersion = keccak256(bytes("1"));
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    //keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
                    bytes32(0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f),
                    _hashedName,
                    _hashedVersion,
                    block.chainid,
                    address(this)
                )
            );
    }

    function balanceOf(address account) external view returns (uint256) {
        return asset.balanceOf(account);
    }

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
    function transferWithAuthorization(address from, address to, uint256 value, uint256 validAfter, uint256 validBefore, bytes32 nonce, uint8 v, bytes32 r, bytes32 s) external {
        _requireValidAuthorization(from, nonce, validAfter, validBefore);
        _requireValidSignature(from, keccak256(abi.encode(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce)), v, r, s);
        _markUsed(from, nonce);
        asset.transferFrom(from, to, value);
    }

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
    function receiveWithAuthorization(address from, address to, uint256 value, uint256 validAfter, uint256 validBefore, bytes32 nonce, uint8 v, bytes32 r, bytes32 s) external {
        if (msg.sender != to) revert CallerMustBePayee();
        _requireValidAuthorization(from, nonce, validAfter, validBefore);
        _requireValidSignature(from, keccak256(abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce)), v, r, s);
        _markUsed(from, nonce);
        asset.transferFrom(from, to, value);
    }

    /// @notice Attempt to cancel an authorization
    /// @param authorizer   Authorizer's address
    /// @param nonce        Nonce of the authorization
    /// @param v            v of the signature
    /// @param r            r of the signature
    /// @param s            s of the signature
    function cancelAuthorization(address authorizer, bytes32 nonce, uint8 v, bytes32 r, bytes32 s) external {
        if (authorizationState[authorizer][nonce]) revert AuthorizationAlreadyUsed();
        _requireValidSignature(authorizer, keccak256(abi.encode(CANCEL_AUTHORIZATION_TYPEHASH, authorizer, nonce)), v, r, s);
        authorizationState[authorizer][nonce] = true;
        emit AuthorizationCanceled(authorizer, nonce);
    }

    function _requireValidAuthorization(address authorizer, bytes32 nonce, uint256 validAfter, uint256 validBefore) private view {
        if (block.timestamp <= validAfter) revert AuthorizationNotYetValid();
        if (block.timestamp >= validBefore) revert AuthorizationExpired();
        if (authorizationState[authorizer][nonce]) revert AuthorizationAlreadyUsed();
    }

    function _requireValidSignature(address signer, bytes32 dataHash, uint8 v, bytes32 r, bytes32 s) private view {
        address recovered = ecrecover(keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), dataHash)), v, r, s);
        if (recovered == address(0) || recovered != signer) revert InvalidSignature();
    }

    function _markUsed(address authorizer, bytes32 nonce) private {
        authorizationState[authorizer][nonce] = true;
        emit AuthorizationUsed(authorizer, nonce);
    }
}
