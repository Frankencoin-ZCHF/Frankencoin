// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {ITokenAdminRegistry} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/ITokenAdminRegistry.sol";
import {TokenPool} from "@chainlink/contracts-ccip/src/v0.8/ccip/pools/TokenPool.sol";
import {IBasicFrankencoin} from "../stablecoin/IBasicFrankencoin.sol";

contract BridgeAccounting is CCIPReceiver {
    IBasicFrankencoin public immutable ZCHF;
    ITokenAdminRegistry public immutable TOKEN_ADMIN_REGISTRY;

    event ReceivedProfits(uint256 amount);
    event ReceivedLosses(uint256 losses);
    event ReceivedSettlement(uint64 indexed chain, bytes indexed sender, uint256 losses, uint256 profits);

    error InvalidSender(uint64 chain, bytes sender);

    constructor(IBasicFrankencoin zchf, ITokenAdminRegistry registry, address router) CCIPReceiver(router) {
        ZCHF = zchf;
        TOKEN_ADMIN_REGISTRY = registry;
    }

    /// @notice Handles the profit and loss messages
    /// @param any2EvmMessage The message
    function _ccipReceive(Client.Any2EVMMessage memory any2EvmMessage) internal override {
        _validateSender(any2EvmMessage);

        (uint256 profits, uint256 losses) = abi.decode(any2EvmMessage.data, (uint256, uint256));
        if (profits > 0) {
            _handleProfits();
        }

        if (losses > 0) {
            _handleLosses(losses);
        }

        emit ReceivedSettlement(any2EvmMessage.sourceChainSelector, any2EvmMessage.sender, losses, profits);
    }

    /// @notice Validates the sender of the message by checking if the sender is a remote token.
    /// @param any2EvmMessage The message
    function _validateSender(Client.Any2EVMMessage memory any2EvmMessage) internal view {
        TokenPool pool = TokenPool(TOKEN_ADMIN_REGISTRY.getPool(address(ZCHF)));
        bytes memory expectedSender = pool.getRemoteToken(any2EvmMessage.sourceChainSelector);
        if (keccak256(any2EvmMessage.sender) != keccak256(expectedSender)) {
            revert InvalidSender(any2EvmMessage.sourceChainSelector, any2EvmMessage.sender);
        }
    }

    /// @notice Sends the current balance (aka profits) to the Frankencoin contract
    function _handleProfits() internal {
        // Use total balance to remove dust
        uint256 balance = ZCHF.balanceOf(address(this));
        ZCHF.collectProfits(address(this), balance);
        emit ReceivedProfits(balance);
    }

    /// @notice Handles the losses and burns the tokens received.
    /// @param amount The amount of losses taken by the system
    function _handleLosses(uint256 amount) internal {
        ZCHF.coverLoss(address(this), amount); // to trigger the Loss event
        // the BridgedFrankencoin already minted new tokens and made the minter whole.
        // the tokens minted by the main Frankencoin are therefore a duplicate and need to be burned
        // otherwise a loss would have double the impact
        ZCHF.burn(amount);
        emit ReceivedLosses(amount);
    }
}
