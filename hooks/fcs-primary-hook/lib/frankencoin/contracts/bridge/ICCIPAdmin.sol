// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {ITokenPool} from "./ITokenPool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/RateLimiter.sol";

interface ICCIPAdmin {

    struct RemotePoolUpdate {
        bool add;
        uint64 chain;
        bytes poolAddress;
    }
    function proposeRemotePoolUpdate(RemotePoolUpdate memory update, address[] calldata helpers) external;
    function proposeRemoveChain(uint64 chainId, address[] calldata helpers) external;
    function proposeAddChain(ITokenPool.ChainUpdate calldata config, address[] calldata helpers) external;
    function proposeAdminTransfer(address newAdmin, address[] calldata helpers) external;
    function applyRateLimit(uint64 chain, RateLimiter.Config calldata outbound, RateLimiter.Config calldata inbound, address[] calldata helpers) external;
    function deny(bytes32 hash, address[] calldata helpers) external;
}
