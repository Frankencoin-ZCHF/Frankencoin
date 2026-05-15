// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./MinterGovernance.sol";
import "../IGovernance.sol";
import "../../stablecoin/IFrankencoin.sol";
import "../../minting/IPosition.sol";
import {ITokenPool} from "../../bridge/ITokenPool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/RateLimiter.sol";

/**
 * Allows qualified FPS2 holders to participate CCIP governance like qualified FPS1 holders.
 */
contract CCIPGovernance is GovernanceModule, ICCIPAdmin {

    ICCIPAdmin public immutable CCIP_ADMIN;

    constructor(IGovernance gov, address mainnetFPS2_, ICCIPAdmin ccipAdmin_) GovernanceModule(gov, mainnetFPS2_) {
        CCIP_ADMIN = ccipAdmin_;
    }

    // ==================== CCIPAdmin governance ====================

    function proposeRemotePoolUpdate(ICCIPAdmin.RemotePoolUpdate memory update, address[] calldata helpers) external onlyQualified(helpers) {
        CCIP_ADMIN.proposeRemotePoolUpdate(update, defaultHelper());
    }

    function proposeRemoveChain(uint64 chainId, address[] calldata helpers) external onlyQualified(helpers) {
        CCIP_ADMIN.proposeRemoveChain(chainId, defaultHelper());
    }

    function proposeAddChain(ITokenPool.ChainUpdate calldata config, address[] calldata helpers) external onlyQualified(helpers) {
        CCIP_ADMIN.proposeAddChain(config, defaultHelper());
    }

    function proposeAdminTransfer(address newAdmin, address[] calldata helpers) external onlyQualified(helpers) {
        CCIP_ADMIN.proposeAdminTransfer(newAdmin, defaultHelper());
    }

    function applyRateLimit(uint64 chain, RateLimiter.Config calldata outbound, RateLimiter.Config calldata inbound, address[] calldata helpers) external onlyQualified(helpers) {
        CCIP_ADMIN.applyRateLimit(chain, outbound, inbound, defaultHelper());
    }

    function applyRateLimit(uint64[] calldata chains, RateLimiter.Config calldata outbound, RateLimiter.Config calldata inbound, address[] calldata helpers) external onlyQualified(helpers) {
        address[] memory asHelper = defaultHelper();
        for (uint256 i = 0; i < chains.length; i++) {
            CCIP_ADMIN.applyRateLimit(chains[i], outbound, inbound, asHelper);
        }
    }

    function deny(bytes32 hash, address[] calldata helpers) external onlyQualified(helpers) {
        CCIP_ADMIN.deny(hash, defaultHelper());
    }

    function deny(bytes32[] calldata hashes, address[] calldata helpers) external onlyQualified(helpers) {
        address[] memory asHelper = defaultHelper();
        for (uint256 i = 0; i < hashes.length; i++) {
            CCIP_ADMIN.deny(hashes[i], asHelper);
        }
    }

}

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
