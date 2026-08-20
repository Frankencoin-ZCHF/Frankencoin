// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ITransferWithAuthorization} from "./ITransferWithAuthorization.sol";

/**
 * @title ITransferWithAuthorizationV2
 * @notice EIP-3009 + ERC-7598 sidecar interface.
 * @dev Classic inherited `(v, r, s)` functions are ECDSA-only. The `bytes` overloads use ECDSA
 *      for codeless EOAs and ERC-1271, without ECDSA fallback, for addresses with code.
 */
interface ITransferWithAuthorizationV2 is ITransferWithAuthorization {
    error CallerMustBeDeployer();

    function eip712Domain() external view returns (bytes1 fields, string memory name, string memory version, uint256 chainId, address verifyingContract, bytes32 salt, uint256[] memory extensions);

    function transferWithAuthorization(address from, address to, uint256 value, uint256 validAfter, uint256 validBefore, bytes32 nonce, bytes calldata signature) external;

    function receiveWithAuthorization(address from, address to, uint256 value, uint256 validAfter, uint256 validBefore, bytes32 nonce, bytes calldata signature) external;

    function cancelAuthorization(address authorizer, bytes32 nonce, bytes calldata signature) external;
}
