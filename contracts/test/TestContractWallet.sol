// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract TestContractWallet {
    address public owner;
    bytes4 private constant MAGICVALUE = 0x1626ba7e;

    constructor(address owner_) {
        owner = owner_;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        if (signature.length != 65) return 0xffffffff;
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        if (v < 27) v += 27;
        address recovered = ecrecover(hash, v, r, s);
        if (recovered != address(0) && recovered == owner) return MAGICVALUE;
        return 0xffffffff;
    }
}

contract TestAlwaysValidWallet {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }
}

contract TestRejectingWallet {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0xffffffff;
    }
}

contract TestRevertingWallet {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        revert("wallet reverted");
    }
}

contract TestShortReturnWallet {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        assembly ("memory-safe") {
            mstore(0, shl(224, 0x1626ba7e))
            return(0, 4)
        }
    }
}

contract TestMalformedReturnWallet {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        assembly ("memory-safe") {
            mstore(0, or(shl(224, 0x1626ba7e), 1))
            return(0, 32)
        }
    }
}

contract TestOversizedReturnWallet {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        assembly ("memory-safe") {
            mstore(0, shl(224, 0x1626ba7e))
            return(0, 0x100000)
        }
    }
}
