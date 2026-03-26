// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./MainnetGovernance.sol";
import "./BridgedGovernance.sol";

/**
 * @title GovernanceFactory
 * @notice Deploys either MainnetGovernance or BridgedGovernance at a deterministic address.
 *
 * This factory must be deployed via CREATE2 at the same address on all chains. The first
 * (and only) contract it creates via CREATE uses nonce 1, producing an identical address
 * regardless of which governance variant is deployed. This ensures that the MainnetGovernance
 * on mainnet and BridgedGovernance on L2s share the same address, which is required for the
 * synced FPS1 delegation to remain valid across chains.
 *
 * Deployment flow:
 * 1. Deploy this factory via CREATE2 (same address on all chains).
 * 2. On mainnet: call deployMainnet(...) after FPS2 is deployed.
 * 3. On each L2: call deployBridged(...).
 * 4. On mainnet: delegate FPS1 votes to the governance address (fps1.delegateVoteTo(governance)).
 */
contract GovernanceFactory {

    /**
     * @notice Deploy MainnetGovernance (call on mainnet only, once).
     */
    function deployMainnet(
        address fps2_,
        IFrankencoin zchf_,
        ICCIPAdmin ccipAdmin_,
        ILeadrateProposal borrowingLeadrate_,
        ILeadrateProposal savingsLeadrate_,
        IRouterClient router_,
        address linkToken_
    ) external returns (address) {
        MainnetGovernance gov = new MainnetGovernance(fps2_, zchf_, ccipAdmin_, borrowingLeadrate_, savingsLeadrate_, router_, linkToken_);
        return address(gov);
    }

    /**
     * @notice Deploy BridgedGovernance (call on each L2, once).
     * The mainnetSender is automatically set to the predicted governance address,
     * since MainnetGovernance on mainnet will be at the same address.
     */
    function deployBridged(
        address mainnetFPS2_,
        IFrankencoin zchf_,
        ICCIPAdmin ccipAdmin_,
        address router_,
        uint64 mainnetChainSelector_
    ) external returns (address) {
        BridgedGovernance gov = new BridgedGovernance(mainnetFPS2_, zchf_, ccipAdmin_, router_, mainnetChainSelector_);
        return address(gov);
    }

}
