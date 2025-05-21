// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "../erc20/IERC20.sol";
import {CCIPSender} from "../bridge/CCIPSender.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";

/**
 * @dev A module for Frankencoin transfers with a reference number, incl. cross chain transfers
 */
contract TransferReference is CCIPSender {
    IERC20 public immutable zchf;
    uint256 internal constant INFINITY = (1 << 255); // @dev: copied from "./ERC20.sol"

    event Transfer(address indexed from, address indexed to, uint256 amount, string ref);

    // @dev: **to** is type bytes to support arbitrary destination chains without risk of unsafe conversion
    event CrossTransfer(address indexed sender, address indexed from, uint64 toChain, bytes indexed to, uint256 amount, string ref);

    error InfiniteAllowanceRequired(address owner, address spender);

    constructor(address token, IRouterClient router, address link) CCIPSender(router, link) {
        zchf = IERC20(token);
    }

    // erc20 transfer
    function transfer(address recipient, uint256 amount, string calldata ref) public returns (bool) {
        zchf.transferFrom(msg.sender, recipient, amount);
        emit Transfer(msg.sender, recipient, amount, ref);
        return true;
    }

    function transferFrom(address owner, address recipient, uint256 amount, string calldata ref) public returns (bool) {
        if (zchf.allowance(owner, msg.sender) < INFINITY) revert InfiniteAllowanceRequired(owner, msg.sender);
        zchf.transferFrom(owner, recipient, amount);
        emit Transfer(owner, recipient, amount, ref);
        return true;
    }

    // cross transfer
    function crossTransfer(uint64 targetChain, address recipient, uint256 amount, string calldata ref) public returns (bool) {
        _crossTransfer(targetChain, msg.sender, _toReceiver(recipient), amount, "", ref);
        return true;
    }

    function crossTransfer(uint64 targetChain, address recipient, uint256 amount, Client.EVMExtraArgsV2 calldata extraArgs, string calldata ref) public returns (bool) {
        _crossTransfer(targetChain, msg.sender, _toReceiver(recipient), amount, Client._argsToBytes(extraArgs), ref);
        return true;
    }

    function crossTransfer(uint64 targetChain, bytes memory recipient, uint256 amount, bytes calldata extraArgs, string calldata ref) public returns (bool) {
        _crossTransfer(targetChain, msg.sender, recipient, amount, extraArgs, ref);
        return true;
    }

    // cross transfer from
    function crossTransferFrom(uint64 targetChain, address owner, address recipient, uint256 amount, string calldata ref) public returns (bool) {
        if (zchf.allowance(owner, msg.sender) < INFINITY) revert InfiniteAllowanceRequired(owner, msg.sender);
        _crossTransfer(targetChain, owner, _toReceiver(recipient), amount, "", ref);
        return true;
    }

    function crossTransferFrom(uint64 targetChain, address owner, address recipient, uint256 amount, Client.EVMExtraArgsV2 calldata extraArgs, string calldata ref) public returns (bool) {
        if (zchf.allowance(owner, msg.sender) < INFINITY) revert InfiniteAllowanceRequired(owner, msg.sender);
        _crossTransfer(targetChain, owner, _toReceiver(recipient), amount, Client._argsToBytes(extraArgs), ref);
        return true;
    }

    function crossTransferFrom(uint64 targetChain, address owner, bytes memory recipient, uint256 amount, bytes calldata extraArgs, string calldata ref) public returns (bool) {
        if (zchf.allowance(owner, msg.sender) < INFINITY) revert InfiniteAllowanceRequired(owner, msg.sender);
        _crossTransfer(targetChain, owner, recipient, amount, extraArgs, ref);
        return true;
    }

    function _crossTransfer(uint64 targetChain, address from, bytes memory target, uint256 amount, bytes memory extraArgs, string calldata ref) private {
        zchf.transferFrom(from, address(this), amount);
        zchf.approve(address(ROUTER), amount);
        _send(targetChain, constructTransferMessage(target, amount, extraArgs));
        emit CrossTransfer(msg.sender, from, targetChain, target, amount, ref); // @dev: target is type bytes
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
