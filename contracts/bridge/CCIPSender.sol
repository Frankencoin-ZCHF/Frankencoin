// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {IERC20} from "../erc20/IERC20.sol";

abstract contract CCIPSender {
    IRouterClient public immutable ROUTER;
    address public immutable LINK;

    error InsufficientFeeTokens(address token, uint256 fee);
    error InsufficientFeeTokenAllowance(address token, uint256 fee);

    constructor(IRouterClient router, address link) {
        ROUTER = router;
        LINK = link;
    }

    /// @notice Encodes the receiver correctly
    /// @param target The target address
    /// @return The encoded receiver
    function _toReceiver(address target) internal pure returns (bytes memory) {
        return abi.encode(target);
    }

    /// @notice Builds the message struct
    /// @dev Guesses the fee token based on msg.value
    /// @param receiver The receiver
    /// @param payload The payload
    /// @param tokenAmounts The token amounts
    /// @param extraArgs The extra args such as gas limit and out-of-order execution
    /// @return The message struct
    function _constructMessage(bytes memory receiver, bytes memory payload, Client.EVMTokenAmount[] memory tokenAmounts, bytes memory extraArgs) internal view returns (Client.EVM2AnyMessage memory) {
        return Client.EVM2AnyMessage(receiver, payload, tokenAmounts, _guessFeeToken(), extraArgs);
    }

    /// @notice Builds the message struct
    /// @param receiver The receiver
    /// @param payload The payload
    /// @param tokenAmounts The token amounts
    /// @param nativeToken Whether to use native token or LINK
    /// @param extraArgs The extra args such as gas limit and out-of-order execution
    /// @return The message struct
    function _constructMessage(bytes memory receiver, bytes memory payload, Client.EVMTokenAmount[] memory tokenAmounts, bool nativeToken,  bytes memory extraArgs) internal view returns (Client.EVM2AnyMessage memory) {
        return Client.EVM2AnyMessage(receiver, payload, tokenAmounts, nativeToken ? address(0) : LINK, extraArgs);
    }

    /// @notice Gets the fee from the router for the given message and chain combition
    /// @param chain The chain
    /// @param message The message
    /// @return The fee
    function _calculateFee(uint64 chain, Client.EVM2AnyMessage memory message) internal view returns (uint256) {
        return ROUTER.getFee(chain, message);
    }

    /// @notice Sends the message to the router and handles fee payment
    /// @dev External call to msg.sender if fees are paid in native token. This function can lead to a potential reentrancy.
    /// @param chain The chain
    /// @param message The message
    /// @return The message id and fee
    function _send(uint64 chain, Client.EVM2AnyMessage memory message) internal returns (bytes32, uint256) {
        uint256 fee = _calculateFee(chain, message);
        bytes32 messageId;
        if (message.feeToken != address(0)) {
            // We trust the feeToken to be not malicious.
            // ROUTER.getFee() verifies that the feeToken is supported by CCIP and thus vetted.
            if (IERC20(message.feeToken).balanceOf(msg.sender) < fee) revert InsufficientFeeTokens(message.feeToken, fee);
            if (IERC20(message.feeToken).allowance(msg.sender, address(this)) < fee) revert InsufficientFeeTokenAllowance(message.feeToken, fee);
            IERC20(message.feeToken).transferFrom(msg.sender, address(this), fee);
            IERC20(message.feeToken).approve(address(ROUTER), fee);
            messageId = ROUTER.ccipSend(chain, message);

            // Send back any leftover fee tokens
            uint256 leftover = IERC20(message.feeToken).balanceOf(address(this));
            if (leftover > 0) IERC20(message.feeToken).transfer(msg.sender, leftover);
        } else {
            if (msg.value < fee) revert InsufficientFeeTokens(message.feeToken, fee);
            messageId = ROUTER.ccipSend{value: fee}(chain, message);
            // return overpaid fee to sender. We don't care about the success of this call.
            if(msg.value - fee > 0) payable(msg.sender).call{value: msg.value - fee}("");
        }
        return (messageId, fee);
    }

    /// @notice Guesses the fee token based on msg.value
    /// @return The fee token
    function _guessFeeToken() internal view returns (address) {
        return (msg.value > 0) ? address(0) : LINK;
    }
}
