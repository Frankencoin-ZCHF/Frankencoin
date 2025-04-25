// SPDX-License-Identifier: MIT
// Copied from https://github.com/transmissions11/solmate/blob/main/src/tokens/ERC20.sol
// and modified it.

pragma solidity ^0.8.0;

import "./ERC20.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {CCIPSender} from "../bridge/CCIPSender.sol";

abstract contract CrossChainERC20 is ERC20, CCIPSender {
    event Transfer(address indexed from, uint64 toChain, bytes indexed to, uint256 value);

    constructor(address router, address linkToken) CCIPSender(IRouterClient(router), linkToken) {}

    /// @notice Transfers tokens to the target chain
    /// @dev Requires the caller to approve this contract to spend the tokens.
    /// @param targetChain The chain selector of the destination chain.
    /// @param target The address of the recipient on the destination chain.
    /// @param amount The amount of tokens to transfer.
    function transfer(uint64 targetChain, address target, uint256 amount) external payable {
        transfer(targetChain, _toReceiver(target), amount, "");
    }

    /// @notice Transfers tokens to the target chain
    /// @dev Requires the caller to approve this contract to spend the tokens.
    /// @param targetChain The chain selector of the destination chain.
    /// @param target The address of the recipient on the destination chain.
    /// @param amount The amount of tokens to transfer.
    /// @param extraArgs Extra arguments for CCIP
    function transfer(uint64 targetChain, address target, uint256 amount, Client.EVMExtraArgsV2 calldata extraArgs) external payable {
        transfer(targetChain, _toReceiver(target), amount, Client._argsToBytes(extraArgs));
    }

    /// @notice Transfers tokens to the target chain
    /// @dev Requires the caller to approve this contract to spend the tokens.
    /// @param targetChain The chain selector of the destination chain.
    /// @param target The address of the recipient on the destination chain.
    /// @param amount The amount of tokens to transfer.
    /// @param extraArgs Extra arguments for CCIP
    function transfer(uint64 targetChain, bytes memory target, uint256 amount, bytes memory extraArgs) public payable {
        _transfer(msg.sender, address(this), amount);
        _approve(address(this), address(ROUTER), amount);
        _send(targetChain, constructTransferMessage(target, amount, extraArgs));
        emit Transfer(msg.sender, targetChain, target, amount);
    }

    /// @notice Gets the CCIP fee for a transfer.
    /// @param targetChain The chain selector of the destination chain.
    /// @param target The address of the recipient on the destination chain.
    /// @param amount The amount of tokens to transfer.
    /// @param nativeToken Whether the token is a native token.
    function getCCIPFee(uint64 targetChain, address target, uint256 amount, bool nativeToken) public view returns (uint256) {
        return getCCIPFee(targetChain, _toReceiver(target), amount, nativeToken, "");
    }

    /// @notice Gets the CCIP fee for a transfer.
    /// @param targetChain The chain selector of the destination chain.
    /// @param target The address of the recipient on the destination chain.
    /// @param amount The amount of tokens to transfer.
    /// @param nativeToken Whether the token is a native token.
    /// @param extraArgs Extra arguments for CCIP
    function getCCIPFee(uint64 targetChain, address target, uint256 amount, bool nativeToken, bytes memory extraArgs) public view returns (uint256) {
        return getCCIPFee(targetChain, _toReceiver(target), amount, nativeToken, extraArgs);
    }

    /// @notice Gets the CCIP fee for a transfer.
    /// @param targetChain The chain selector of the destination chain.
    /// @param target The address of the recipient on the destination chain.
    /// @param amount The amount of tokens to transfer.
    /// @param nativeToken Whether the token is a native token.
    /// @param extraArgs Extra arguments for CCIP
    function getCCIPFee(uint64 targetChain, bytes memory target, uint256 amount, bool nativeToken, bytes memory extraArgs) public view returns (uint256) {
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount(address(this), amount);
        return _calculateFee(targetChain, _constructMessage(target, "", tokenAmounts, nativeToken, extraArgs));
    }

    /// @notice Construct a CCIP message.
    /// @dev This function will create an EVM2AnyMessage struct with all the necessary information for tokens transfer.
    /// @param receiver The address of the receiver.
    /// @param amount The amount of the token to be transferred.
    /// @return Client.EVM2AnyMessage Returns an EVM2AnyMessage struct which contains information for sending a CCIP message.
    function constructTransferMessage(bytes memory receiver, uint256 amount, bytes memory extraArgs) private view returns (Client.EVM2AnyMessage memory) {
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount(address(this), amount);
        return _constructMessage(receiver, "", tokenAmounts, extraArgs);
    }
}
