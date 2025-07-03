// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {Leadrate} from "./Leadrate.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {CCIPSender} from "../bridge/CCIPSender.sol";

contract LeadrateSender is CCIPSender {
    Leadrate public immutable LEADRATE;

    event Pushed(uint64 chain, bytes indexed bridgedLeadrate, uint24 newRatePPM);

    error LengthMismatch(uint256 expected, uint256 given);

    constructor(Leadrate leadrate, IRouterClient router, address linkToken) CCIPSender(router, linkToken) {
        LEADRATE = leadrate;
    }

    /// @notice Push the current leadrate to the targets in bulk.
    /// @dev Bulks only work with approved fee tokens and not native.
    /// @param chains The chain selectors of the destination chains.
    /// @param targets The addresses of the recipients on the destination chains.
    function pushLeadrate(uint64[] calldata chains, bytes[] calldata targets) external {
        pushLeadrate(chains, targets, new bytes[](chains.length));
    }

    /// @notice Push the current leadrate to the targets in bulk.
    /// @dev Bulks only work with approved fee tokens and not native.
    /// @param chains The chain selectors of the destination chains.
    /// @param targets The addresses of the recipients on the destination chains.
    /// @param extraArgs Extra arguments for CCIP
    function pushLeadrate(uint64[] calldata chains, bytes[] calldata targets, bytes[] memory extraArgs) public {
        if (chains.length != targets.length) revert LengthMismatch(chains.length, targets.length);
        if (chains.length != extraArgs.length) revert LengthMismatch(chains.length, extraArgs.length);

        _applyPendingChanges();
        uint24 currentRate = LEADRATE.currentRatePPM();
        for (uint256 i; i < chains.length; i++) {
            _sendLeadrate(chains[i], targets[i], currentRate, extraArgs[i]);
        }
    }

    /// @notice Push the current leadrate to the target chain.
    /// @param chain The chain selector of the destination chain.
    /// @param target The address of the recipient on the destination chain.
    function pushLeadrate(uint64 chain, address target) external payable {
        pushLeadrate(chain, _toReceiver(target), "");
    }

    /// @notice Push the current leadrate to the target chain.
    /// @param chain The chain selector of the destination chain.
    /// @param target The address of the recipient on the destination chain.
    /// @param extraArgs Extra arguments for CCIP
    function pushLeadrate(uint64 chain, address target, Client.EVMExtraArgsV2 calldata extraArgs) external payable {
        pushLeadrate(chain, _toReceiver(target), Client._argsToBytes(extraArgs));
    }

    /// @notice Push the current leadrate to the target chain.
    /// @param chain The chain selector of the destination chain.
    /// @param target The address of the recipient on the destination chain.
    /// @param extraArgs Extra arguments for CCIP
    function pushLeadrate(uint64 chain, bytes memory target, bytes memory extraArgs) public payable {
        _applyPendingChanges();
        _sendLeadrate(chain, target, LEADRATE.currentRatePPM(), extraArgs);
    }

    /// @notice Gets the CCIP fee.
    /// @param chain The chain selector of the destination chain.
    /// @param target The address of the recipient on the destination chain.
    /// @param nativeToken Whether to use native token for the fee.
    function getCCIPFee(uint64 chain, address target, bool nativeToken) public view returns (uint256) {
        return getCCIPFee(chain, _toReceiver(target), nativeToken, "");
    }

    /// @notice Gets the CCIP fee.
    /// @param chain The chain selector of the destination chain.
    /// @param target The address of the recipient on the destination chain.
    /// @param nativeToken Whether to use native token for the fee.
    /// @param extraArgs Extra arguments for CCIP
    function getCCIPFee(uint64 chain, address target, bool nativeToken, bytes memory extraArgs) public view returns (uint256) {
        return getCCIPFee(chain, _toReceiver(target), nativeToken, extraArgs);
    }

    /// @notice Gets the CCIP fee.
    /// @param chain The chain selector of the destination chain.
    /// @param target The address of the recipient on the destination chain.
    /// @param nativeToken Whether to use native token for the fee.
    /// @param extraArgs Extra arguments for CCIP
    function getCCIPFee(uint64 chain, bytes memory target, bool nativeToken, bytes memory extraArgs) public view returns (uint256) {
        return _calculateFee(chain, _constructMessage(target, abi.encode(LEADRATE.currentRatePPM()), new Client.EVMTokenAmount[](0), nativeToken, extraArgs));
    }

    /// @notice Constructs and sends the CCIP message.
    /// @param chain The chain selector of the destination chain.
    /// @param target The address of the recipient on the destination chain.
    /// @param newRatePPM The new leadrate.
    /// @param extraArgs Extra arguments for CCIP
    function _sendLeadrate(uint64 chain, bytes memory target, uint24 newRatePPM, bytes memory extraArgs) internal {
        _send(chain, _constructMessage(target, abi.encode(newRatePPM), new Client.EVMTokenAmount[](0), extraArgs));
        emit Pushed(chain, target, newRatePPM);
    }

    /// @notice Applies pending changes to the leadrate if possible.
    function _applyPendingChanges() internal {
        // external calls are necessary because applyChange() would revert if there is no pending change
        if (LEADRATE.currentRatePPM() != LEADRATE.nextRatePPM() && LEADRATE.nextChange() < block.timestamp) {
            LEADRATE.applyChange(); // there is a pending change to apply
        }
    }
}
