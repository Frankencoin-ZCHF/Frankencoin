// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @dev Local, dependency-free secp256k1 signature recovery.
 *
 * Only canonical signatures are accepted: `s` must be in the lower half order and
 * `v` must be 27 or 28. A failed recovery (address(0)) is always invalid, including
 * when the claimed signer is address(0).
 */
library ECDSA {
    // secp256k1n / 2
    uint256 private constant _HALF_ORDER = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    function isValidSignature(address signer, bytes32 hash, bytes memory signature) internal pure returns (bool) {
        (address recovered, bool success) = tryRecover(hash, signature);
        return success && signer != address(0) && recovered == signer;
    }

    function isValidSignature(address signer, bytes32 hash, uint8 v, bytes32 r, bytes32 s) internal pure returns (bool) {
        (address recovered, bool success) = tryRecover(hash, v, r, s);
        return success && signer != address(0) && recovered == signer;
    }

    function tryRecover(bytes32 hash, bytes memory signature) internal pure returns (address recovered, bool success) {
        if (signature.length != 65) {
            return (address(0), false);
        }

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
        return tryRecover(hash, v, r, s);
    }

    function tryRecover(bytes32 hash, uint8 v, bytes32 r, bytes32 s) internal pure returns (address recovered, bool success) {
        if (uint256(s) > _HALF_ORDER || (v != 27 && v != 28)) {
            return (address(0), false);
        }

        recovered = ecrecover(hash, v, r, s);
        success = recovered != address(0);
    }
}
