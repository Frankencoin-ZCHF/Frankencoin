// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {RateLimiter} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/RateLimiter.sol";

interface ITokenPool {
    
    struct ChainUpdate {
        uint64 remoteChainSelector; // Remote chain selector
        bytes[] remotePoolAddresses; // Address of the remote pool, ABI encoded in the case of a remote EVM chain.
        bytes remoteTokenAddress; // Address of the remote token, ABI encoded in the case of a remote EVM chain.
        RateLimiter.Config outboundRateLimiterConfig; // Outbound rate limited config, meaning the rate limits for all of the onRamps for the given chain
        RateLimiter.Config inboundRateLimiterConfig; // Inbound rate limited config, meaning the rate limits for all of the offRamps for the given chain
    }

    function addRemotePool(uint64 remoteChainSelector, bytes calldata remotePoolAddress) external;
    function removeRemotePool(uint64 remoteChainSelector, bytes calldata remotePoolAddress) external;

    function setChainRateLimiterConfig(
        uint64 remoteChainSelectors,
        RateLimiter.Config calldata outboundConfigs,
        RateLimiter.Config calldata inboundConfigs
    ) external;
    
    function applyChainUpdates(
        uint64[] calldata remoteChainSelectorsToRemove,
        ChainUpdate[] calldata chainsToAdd
    ) external;

    function acceptOwnership() external;
    function transferOwnership(address to) external;
}
