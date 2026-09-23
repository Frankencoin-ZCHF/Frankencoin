
// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {CCIPSender} from "../bridge/CCIPSender.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";

contract CCIPSenderTest is CCIPSender {
    constructor(IRouterClient _router, address _link) CCIPSender(_router, _link) {}

    function toReceiver(address target) public pure returns (bytes memory) {
        return _toReceiver(target);
    }

    function constructMessage(
        bytes memory _receiver,
        bytes memory _payload,
        Client.EVMTokenAmount[] memory _tokenAmounts,
        bytes memory _extraArgs
    ) public view returns (Client.EVM2AnyMessage memory) {
        return _constructMessage(_receiver, _payload, _tokenAmounts, _extraArgs);
    }

    function constructMessage(
        bytes memory _receiver,
        bytes memory _payload,
        Client.EVMTokenAmount[] memory _tokenAmounts,
        bool nativeToken,
        bytes memory _extraArgs
    ) public view returns (Client.EVM2AnyMessage memory) {
        return _constructMessage(_receiver, _payload, _tokenAmounts, nativeToken, _extraArgs);
    }

    function calculateFee(uint64 chain, Client.EVM2AnyMessage memory message) public view returns (uint256) {
        return _calculateFee(chain, message);
    }

    function send(uint64 chain, Client.EVM2AnyMessage memory _message) public payable returns (bytes32, uint256) {
        return _send(chain, _message);
    }

    function guessFeeToken() public view returns (address) {
        return _guessFeeToken();
    }
}
