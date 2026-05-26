// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../stablecoin/IFrankencoin.sol";

/**
 * @title ZCHFTransferWithAuthorization
 * @notice EIP-3009 sidecar for the Frankencoin (ZCHF) stablecoin.
 *
 * Approved minters on the Frankencoin contract hold an implicit infinite allowance over
 * every ZCHF balance. This contract leverages that to execute transferFrom on behalf of
 * any holder who signs a valid EIP-3009 authorization — no on-chain approve() required.
 *
 * Deployment steps:
 *   1. Deploy this contract with the ZCHF address.
 *   2. Fund the application fee: ZCHF.transfer(deployer, ZCHF.MIN_FEE()).
 *   3. Call ZCHF.suggestMinter(address(this), ZCHF.MIN_APPLICATION_PERIOD(), ZCHF.MIN_FEE(), "EIP-3009 sidecar").
 *   4. Wait out the application period with no qualified veto from FPS holders.
 *   5. Once ZCHF.isMinter(address(this)) == true, the contract is live.
 */
contract ZCHFTransferWithAuthorization {
    IFrankencoin public immutable ZCHF;

    bytes32 public immutable DOMAIN_SEPARATOR;

    // keccak256("TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH =
        0x7c7c6cdb67a18743f49ec6fa9b35f50d52ed05cbed4cc592e13b44501c1a2267;

    // keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH =
        0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8;

    // keccak256("CancelAuthorization(address authorizer,bytes32 nonce)")
    bytes32 public constant CANCEL_AUTHORIZATION_TYPEHASH =
        0x158b0a9edf7a828aad02f63cd515c68ef2f50ba807396f6d12842833a1597429;

    // authorizer => nonce => consumed
    // EIP-3009 uses random 32-byte nonces (not sequential) to allow concurrent authorizations.
    mapping(address => mapping(bytes32 => bool)) public authorizationState;

    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);
    event AuthorizationCanceled(address indexed authorizer, bytes32 indexed nonce);

    error AuthorizationNotYetValid();
    error AuthorizationExpired();
    error AuthorizationAlreadyUsed();
    error InvalidSignature();
    error CallerMustBePayee();

    constructor(IFrankencoin zchf) {
        ZCHF = zchf;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                // keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
                bytes32(0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f),
                keccak256(bytes(zchf.name())),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    /**
     * @notice Execute a transfer on behalf of the authorizer.
     * @dev Any caller may submit a valid authorization. When calling from a smart contract,
     *      prefer receiveWithAuthorization to prevent front-running.
     * @param from      Token owner and signer of the authorization.
     * @param to        Recipient of the transfer.
     * @param value     Amount of ZCHF to transfer.
     * @param validAfter  Unix timestamp before which the authorization is not yet valid.
     * @param validBefore Unix timestamp at or after which the authorization expires.
     * @param nonce     Randomly generated 32-byte value unique to this authorization.
     */
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        _requireValidAuthorization(from, nonce, validAfter, validBefore);
        _requireValidSignature(
            from,
            keccak256(abi.encode(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce)),
            v, r, s
        );
        _markUsed(from, nonce);
        ZCHF.transferFrom(from, to, value);
    }

    /**
     * @notice Execute a transfer restricted to msg.sender == to.
     * @dev Use this variant when the recipient is a smart contract. The caller restriction
     *      prevents a front-runner from extracting the signature and redirecting it.
     */
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (msg.sender != to) revert CallerMustBePayee();
        _requireValidAuthorization(from, nonce, validAfter, validBefore);
        _requireValidSignature(
            from,
            keccak256(abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce)),
            v, r, s
        );
        _markUsed(from, nonce);
        ZCHF.transferFrom(from, to, value);
    }

    /**
     * @notice Cancel an unused authorization. Only the authorizer can cancel their own nonce.
     */
    function cancelAuthorization(address authorizer, bytes32 nonce, uint8 v, bytes32 r, bytes32 s) external {
        if (authorizationState[authorizer][nonce]) revert AuthorizationAlreadyUsed();
        _requireValidSignature(
            authorizer,
            keccak256(abi.encode(CANCEL_AUTHORIZATION_TYPEHASH, authorizer, nonce)),
            v, r, s
        );
        authorizationState[authorizer][nonce] = true;
        emit AuthorizationCanceled(authorizer, nonce);
    }

    function _requireValidAuthorization(
        address authorizer,
        bytes32 nonce,
        uint256 validAfter,
        uint256 validBefore
    ) private view {
        if (block.timestamp <= validAfter) revert AuthorizationNotYetValid();
        if (block.timestamp >= validBefore) revert AuthorizationExpired();
        if (authorizationState[authorizer][nonce]) revert AuthorizationAlreadyUsed();
    }

    function _requireValidSignature(address signer, bytes32 dataHash, uint8 v, bytes32 r, bytes32 s) private view {
        address recovered = ecrecover(
            keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, dataHash)),
            v, r, s
        );
        if (recovered == address(0) || recovered != signer) revert InvalidSignature();
    }

    function _markUsed(address authorizer, bytes32 nonce) private {
        authorizationState[authorizer][nonce] = true;
        emit AuthorizationUsed(authorizer, nonce);
    }
}
