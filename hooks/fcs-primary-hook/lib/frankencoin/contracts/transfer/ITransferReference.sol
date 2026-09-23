// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";

/**
 * @title ITransferReference
 * @dev Interface for the TransferReference contract.
 */
interface ITransferReference {
    // Events
    event Transfer(address indexed from, address indexed to, uint256 amount, string ref);
    event CrossTransfer(address indexed sender, address indexed from, uint64 toChain, bytes indexed to, uint256 amount, string ref);

    // Errors
    error InfiniteAllowanceRequired(address owner, address spender);

    // ERC20 transfer functions
    function transfer(address recipient, uint256 amount, string calldata ref) external returns (bool);

    function transferFrom(address owner, address recipient, uint256 amount, string calldata ref) external returns (bool);

    // Cross transfer functions
    function crossTransfer(uint64 targetChain, address recipient, uint256 amount, string calldata ref) external returns (bool);

    function crossTransfer(uint64 targetChain, address recipient, uint256 amount, Client.EVMExtraArgsV2 calldata extraArgs, string calldata ref) external returns (bool);

    function crossTransfer(uint64 targetChain, bytes calldata recipient, uint256 amount, bytes calldata extraArgs, string calldata ref) external returns (bool);

    function crossTransferFrom(uint64 targetChain, address owner, address recipient, uint256 amount, string calldata ref) external returns (bool);

    function crossTransferFrom(uint64 targetChain, address owner, address recipient, uint256 amount, Client.EVMExtraArgsV2 calldata extraArgs, string calldata ref) external returns (bool);

    function crossTransferFrom(uint64 targetChain, address owner, bytes calldata recipient, uint256 amount, bytes calldata extraArgs, string calldata ref) external returns (bool);

    // Fee estimation
    function getCCIPFee(uint64 targetChain, address target, uint256 amount, bool nativeToken) external view returns (uint256);

    function getCCIPFee(uint64 targetChain, address target, uint256 amount, bool nativeToken, bytes calldata extraArgs) external view returns (uint256);

    function getCCIPFee(uint64 targetChain, bytes calldata target, uint256 amount, bool nativeToken, bytes calldata extraArgs) external view returns (uint256);

    // Read-only
    function zchf() external view returns (address);
}
