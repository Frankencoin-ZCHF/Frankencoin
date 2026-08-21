// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ECDSA} from "./ECDSA.sol";
import {IERC1271} from "./IERC1271.sol";

/**
 * @dev Signature verification for the encoded-signature (bytes) path.
 *
 * Routing matches Circle FiatToken `SignatureChecker` and OpenZeppelin (used by xGAS):
 *   - `signer.code.length == 0`: ECDSA recovery of a packed `r,s,v` signature.
 *   - `signer.code.length > 0`: ERC-1271 only.
 *
 * There is no ECDSA-first fallback when the signer has code. After EIP-7702 delegation the
 * bytes path follows the account's current ERC-1271 policy. Classic EIP-3009 `(v, r, s)`
 * entrypoints do not use this library.
 *
 * ECDSA validation is delegated to the local ECDSA primitive, which rejects high-s,
 * noncanonical `v`, failed recovery, and the zero signer.
 */
library SignatureChecker {
    bytes4 private constant ERC1271_MAGICVALUE = IERC1271.isValidSignature.selector;

    function isValidSignatureNow(address signer, bytes32 hash, bytes memory signature) internal view returns (bool) {
        if (signer == address(0)) {
            return false;
        }
        if (signer.code.length == 0) {
            return ECDSA.isValidSignature(signer, hash, signature);
        }
        return isValidERC1271SignatureNow(signer, hash, signature);
    }

    function isValidERC1271SignatureNow(address signer, bytes32 hash, bytes memory signature) internal view returns (bool) {
        bytes memory callData = abi.encodeCall(IERC1271.isValidSignature, (hash, signature));
        bool success;
        uint256 returnSize;
        bytes32 result;

        // Cap copied return data at one word. This accepts normal ABI responses while preventing
        // a hostile account from forcing this checker to allocate/copy oversized return data.
        assembly ("memory-safe") {
            let output := mload(0x40)
            mstore(output, 0)
            success := staticcall(gas(), signer, add(callData, 0x20), mload(callData), output, 0x20)
            returnSize := returndatasize()
            result := mload(output)
        }

        return success && returnSize >= 32 && result == bytes32(ERC1271_MAGICVALUE);
    }
}
