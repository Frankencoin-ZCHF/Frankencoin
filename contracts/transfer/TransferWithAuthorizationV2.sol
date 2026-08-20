// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ITransferWithAuthorizationV2} from "./ITransferWithAuthorizationV2.sol";
import {IERC20} from "../erc20/IERC20.sol";
import {ECDSA} from "../utils/ECDSA.sol";
import {SignatureChecker} from "../utils/SignatureChecker.sol";

/**
 * @title TransferWithAuthorizationV2
 * @notice EIP-3009 sidecar with ERC-7598/ERC-1271 smart-account support for Frankencoin (ZCHF).
 *
 * Approved minters on the Frankencoin contract hold an implicit infinite allowance over
 * every ZCHF balance. This contract leverages that to execute transferFrom on behalf of
 * any holder who signs a valid authorization — no on-chain approve() required. Signature
 * validation is therefore the only gate on that allowance.
 *
 * Two signature schemes, deliberately kept separate:
 *
 *   - The classic EIP-3009 `(v, r, s)` entrypoints recover ECDSA only, regardless of whether
 *     `from` has code. They preserve the signature semantics of the EIP-3009 interface, so an
 *     integrator calling them always gets plain secp256k1 verification.
 *   - The ERC-7598 `bytes` overloads own smart-account support and route through
 *     SignatureChecker: EOA ECDSA when `from` has no code, ERC-1271 when it does.
 *
 * Other spec-compatible implementations may route both forms through one checker. V2
 * intentionally does not: for an EIP-7702-delegated EOA the classic path continues to validate
 * root-key ECDSA, while the bytes path follows the delegated account's ERC-1271 policy.
 *
 * V2 tightens ECDSA validation compared with V1's raw ecrecover: high-s signatures and
 * noncanonical v values are rejected, and failed/zero-address recovery is always invalid.
 *
 * The EIP-712 domain name is the compile-time constant "Frankencoin", matching both
 * Frankencoin.name() and BridgedFrankencoin.name(). Unlike V1 it is no longer read from the
 * asset during initialize, which keeps the domain separator independent of initialization
 * state — but it also means initialize() must only ever be pointed at a ZCHF-named asset.
 *
 * Deployment and initialization:
 *   1. Deploy this contract via the Arachnid CREATE2 factory (no constructor args — identical bytecode = identical address on every chain).
 *   2. Call initialize(asset) with the chain-specific ZCHF/bridged-token address. Only the hardcoded deployer may do this.
 *
 * Governance activation after deployment:
 *   1. Ensure the account calling suggestMinter holds at least ZCHF.MIN_FEE() in ZCHF; suggestMinter debits it from msg.sender.
 *   2. Call ZCHF.suggestMinter(address(this), ZCHF.MIN_APPLICATION_PERIOD(), ZCHF.MIN_FEE(), "EIP-3009 sidecar V2").
 *   3. Wait out the application period with no qualified veto from FPS holders.
 *   4. Once ZCHF.isMinter(address(this)) == true, the contract is live. Until then every
 *      authorization reverts for lack of allowance — deploying alone activates nothing.
 */
contract TransferWithAuthorizationV2 is ITransferWithAuthorizationV2 {
    address private constant _deployer = 0x045a8395FE21CE34f0eC34d242c342ade4Ded5be;

    bytes32 private constant _HASHED_NAME = keccak256(bytes("Frankencoin"));
    bytes32 private constant _HASHED_VERSION = keccak256(bytes("1"));

    IERC20 public asset;

    // keccak256("TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = 0x7c7c6cdb67a18743f49ec6fa9b35f50d52ed05cbed4cc592e13b44501c1a2267;

    // keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = 0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8;

    // keccak256("CancelAuthorization(address authorizer,bytes32 nonce)")
    bytes32 public constant CANCEL_AUTHORIZATION_TYPEHASH = 0x158b0a9edf7a828aad02f63cd515c68ef2f50ba807396f6d12842833a1597429;

    mapping(address => mapping(bytes32 => bool)) public authorizationState;

    function initialize(IERC20 _asset) external {
        if (_deployer != msg.sender) revert CallerMustBeDeployer();
        if (address(asset) != address(0)) revert AlreadyInitialized();
        asset = _asset;
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    // keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
                    bytes32(0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f),
                    _HASHED_NAME,
                    _HASHED_VERSION,
                    block.chainid,
                    address(this)
                )
            );
    }

    function eip712Domain() external view returns (bytes1 fields, string memory name, string memory version, uint256 chainId, address verifyingContract, bytes32 salt, uint256[] memory extensions) {
        return (hex"0f", "Frankencoin", "1", block.chainid, address(this), bytes32(0), new uint256[](0));
    }

    function balanceOf(address account) external view returns (uint256) {
        return asset.balanceOf(account);
    }

    /// @notice EIP-3009: execute a transfer with an EOA ECDSA authorization.
    /// @dev Classic path: ECDSA recovery only, independent of whether `from` has code (xGAS / not FiatToken packing).
    function transferWithAuthorization(address from, address to, uint256 value, uint256 validAfter, uint256 validBefore, bytes32 nonce, uint8 v, bytes32 r, bytes32 s) external {
        _requireValidAuthorization(from, nonce, validAfter, validBefore);
        _requireValidECDSASignature(from, keccak256(abi.encode(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce)), v, r, s);
        _markUsed(from, nonce);
        asset.transferFrom(from, to, value);
    }

    /// @notice Encoded-signature transfer (FiatTokenV2_2 / xGAS TransferAuth).
    /// @dev Packed `r,s,v` for EOAs; ERC-1271 when `from` has code. Does not alter the classic `(v, r, s)` path.
    function transferWithAuthorization(address from, address to, uint256 value, uint256 validAfter, uint256 validBefore, bytes32 nonce, bytes calldata signature) external {
        _requireValidAuthorization(from, nonce, validAfter, validBefore);
        _requireValidSignature(from, keccak256(abi.encode(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce)), signature);
        _markUsed(from, nonce);
        asset.transferFrom(from, to, value);
    }

    /// @notice EIP-3009: receive a transfer with an EOA ECDSA authorization.
    function receiveWithAuthorization(address from, address to, uint256 value, uint256 validAfter, uint256 validBefore, bytes32 nonce, uint8 v, bytes32 r, bytes32 s) external {
        if (msg.sender != to) revert CallerMustBePayee();
        _requireValidAuthorization(from, nonce, validAfter, validBefore);
        _requireValidECDSASignature(from, keccak256(abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce)), v, r, s);
        _markUsed(from, nonce);
        asset.transferFrom(from, to, value);
    }

    /// @notice Encoded-signature receive (FiatTokenV2_2 / xGAS TransferAuth).
    function receiveWithAuthorization(address from, address to, uint256 value, uint256 validAfter, uint256 validBefore, bytes32 nonce, bytes calldata signature) external {
        if (msg.sender != to) revert CallerMustBePayee();
        _requireValidAuthorization(from, nonce, validAfter, validBefore);
        _requireValidSignature(from, keccak256(abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce)), signature);
        _markUsed(from, nonce);
        asset.transferFrom(from, to, value);
    }

    /// @notice EIP-3009: cancel an authorization with an EOA ECDSA signature.
    function cancelAuthorization(address authorizer, bytes32 nonce, uint8 v, bytes32 r, bytes32 s) external {
        if (authorizationState[authorizer][nonce]) revert AuthorizationAlreadyUsed();
        _requireValidECDSASignature(authorizer, keccak256(abi.encode(CANCEL_AUTHORIZATION_TYPEHASH, authorizer, nonce)), v, r, s);
        authorizationState[authorizer][nonce] = true;
        emit AuthorizationCanceled(authorizer, nonce);
    }

    /// @notice Encoded-signature cancel (FiatTokenV2_2 / xGAS TransferAuth).
    function cancelAuthorization(address authorizer, bytes32 nonce, bytes calldata signature) external {
        if (authorizationState[authorizer][nonce]) revert AuthorizationAlreadyUsed();
        _requireValidSignature(authorizer, keccak256(abi.encode(CANCEL_AUTHORIZATION_TYPEHASH, authorizer, nonce)), signature);
        authorizationState[authorizer][nonce] = true;
        emit AuthorizationCanceled(authorizer, nonce);
    }

    function _requireValidAuthorization(address authorizer, bytes32 nonce, uint256 validAfter, uint256 validBefore) private view {
        if (block.timestamp <= validAfter) revert AuthorizationNotYetValid();
        if (block.timestamp >= validBefore) revert AuthorizationExpired();
        if (authorizationState[authorizer][nonce]) revert AuthorizationAlreadyUsed();
    }

    /// @dev Classic EIP-3009: local ECDSA validation only. No dependency on SignatureChecker/ERC-1271.
    function _requireValidECDSASignature(address signer, bytes32 dataHash, uint8 v, bytes32 r, bytes32 s) private view {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), dataHash));
        if (!ECDSA.isValidSignature(signer, digest, v, r, s)) revert InvalidSignature();
    }

    /// @dev Encoded path only: EOA ECDSA or ERC-1271 depending on `signer.code.length`.
    function _requireValidSignature(address signer, bytes32 dataHash, bytes memory signature) private view {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), dataHash));
        if (!SignatureChecker.isValidSignatureNow(signer, digest, signature)) revert InvalidSignature();
    }

    function _markUsed(address authorizer, bytes32 nonce) private {
        authorizationState[authorizer][nonce] = true;
        emit AuthorizationUsed(authorizer, nonce);
    }
}
