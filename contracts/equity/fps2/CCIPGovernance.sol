// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./MinterGovernance.sol";
import "../IGovernance.sol";
import "../../stablecoin/IFrankencoin.sol";
import "../../minting/IPosition.sol";
import {ITokenPool} from "../../bridge/ITokenPool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/RateLimiter.sol";

/**
 * @notice Base governance contract for FPS2 equity, used on all chains.
 * Provides position denial, CCIP admin governance, and minter suggestion/veto (via MinterGovernance).
 * Veto power requires 1% of the votes. (2% in earlier versions, namely FPS1 governance)
 *
 * Extended by MainnetFPS2Governance (leadrate proposals + vote syncing) on mainnet
 * and BridgedFPS2Governance (vote reception) on bridged chains.
 */
abstract contract CCIPGovernance is MinterGovernance {

    ICCIPAdmin public immutable CCIP_ADMIN;

    constructor(address mainnetFPS2_, IFrankencoin zchf_, ICCIPAdmin ccipAdmin_) MinterGovernance(zchf_, mainnetFPS2_) {
        CCIP_ADMIN = ccipAdmin_;
    }

    // ==================== CCIPAdmin governance ====================

    function ccipProposeRemotePoolUpdate(ICCIPAdmin.RemotePoolUpdate memory update, address[] calldata helpers) external {
        checkQualified(msg.sender, helpers);
        CCIP_ADMIN.proposeRemotePoolUpdate(update, fps2AsHelper());
    }

    function ccipProposeRemoveChain(uint64 chainId, address[] calldata helpers) external {
        checkQualified(msg.sender, helpers);
        CCIP_ADMIN.proposeRemoveChain(chainId, fps2AsHelper());
    }

    function ccipProposeAddChain(ITokenPool.ChainUpdate calldata config, address[] calldata helpers) external {
        checkQualified(msg.sender, helpers);
        CCIP_ADMIN.proposeAddChain(config, fps2AsHelper());
    }

    function ccipProposeAdminTransfer(address newAdmin, address[] calldata helpers) external {
        checkQualified(msg.sender, helpers);
        CCIP_ADMIN.proposeAdminTransfer(newAdmin, fps2AsHelper());
    }

    function ccipApplyRateLimit(uint64 chain, RateLimiter.Config calldata inbound, RateLimiter.Config calldata outbound, address[] calldata helpers) external {
        checkQualified(msg.sender, helpers);
        CCIP_ADMIN.applyRateLimit(chain, inbound, outbound, fps2AsHelper());
    }

    function ccipApplyRateLimit(uint64[] calldata chains, RateLimiter.Config calldata inbound, RateLimiter.Config calldata outbound, address[] calldata helpers) external {
        checkQualified(msg.sender, helpers);
        address[] memory asHelper = fps2AsHelper();
        for (uint256 i = 0; i < chains.length; i++) {
            CCIP_ADMIN.applyRateLimit(chains[i], inbound, outbound, asHelper);
        }
    }

    function ccipDenyProposal(bytes32 hash, address[] calldata helpers) external {
        checkQualified(msg.sender, helpers);
        CCIP_ADMIN.deny(hash, fps2AsHelper());
    }

    function ccipDenyProposal(bytes32[] calldata hashes, address[] calldata helpers) external {
        checkQualified(msg.sender, helpers);
        address[] memory asHelper = fps2AsHelper();
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
    function applyRateLimit(uint64 chain, RateLimiter.Config calldata inbound, RateLimiter.Config calldata outbound, address[] calldata helpers) external;
    function deny(bytes32 hash, address[] calldata helpers) external;
}
