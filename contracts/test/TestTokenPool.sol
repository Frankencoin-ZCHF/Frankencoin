// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {ITokenPool} from "../bridge/ITokenPool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/RateLimiter.sol";

contract TestTokenPool is ITokenPool {
    event FunctionCalled(string name, bytes args);

    function addRemotePool(uint64 remoteChainSelector, bytes calldata remotePoolAddress) external {
        emit FunctionCalled("addRemotePool", abi.encode(remoteChainSelector, remotePoolAddress));
    }
    function removeRemotePool(uint64 remoteChainSelector, bytes calldata remotePoolAddress) external {
        emit FunctionCalled("removeRemotePool", abi.encode(remoteChainSelector, remotePoolAddress));
    }
    function setChainRateLimiterConfig(
        uint64 remoteChainSelectors,
        RateLimiter.Config calldata outboundConfigs,
        RateLimiter.Config calldata inboundConfigs
    ) external {
        emit FunctionCalled(
            "setChainRateLimiterConfig",
            abi.encode(remoteChainSelectors, outboundConfigs, inboundConfigs)
        );
    }
    function applyChainUpdates(
        uint64[] calldata remoteChainSelectorsToRemove,
        ChainUpdate[] calldata chainsToAdd
    ) external {
        emit FunctionCalled("applyChainUpdates", abi.encode(remoteChainSelectorsToRemove, chainsToAdd));
    }

    function acceptOwnership() external {
        emit FunctionCalled("acceptOwnership", "");
    }
    function transferOwnership(address to) external {
        emit FunctionCalled("transferOwnership", abi.encode(to));
    }
}
