// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BridgedFrankencoin} from "../stablecoin/BridgedFrankencoin.sol";
import {BridgedGovernance} from "../equity/BridgedGovernance.sol";
import {CCIPAdmin} from "../bridge/CCIPAdmin.sol";
import {TokenAdminRegistry} from "@chainlink/contracts-ccip/src/v0.8/ccip/tokenAdminRegistry/TokenAdminRegistry.sol";
import {BurnMintTokenPool} from "@chainlink/contracts-ccip/src/v0.8/ccip/pools/BurnMintTokenPool.sol";
import {IBurnMintERC20} from "@chainlink/contracts-ccip/src/v0.8/shared/token/ERC20/IBurnMintERC20.sol";
import {RegistryModuleOwnerCustom} from "@chainlink/contracts-ccip/src/v0.8/ccip/tokenAdminRegistry/RegistryModuleOwnerCustom.sol";
import {ITokenPool} from "../bridge/ITokenPool.sol";

contract L2Deployer {
    struct CCIPConfig {
        address router;
        uint64 mainnetChainSelector;
        address linkToken;
        TokenAdminRegistry tokenAdminRegistry;
        address rmnProxy;
        RegistryModuleOwnerCustom registryModuleOwnerCustom;
        ITokenPool.ChainUpdate[] chainsToAdd;
    }

    struct GovernanceConfig {
        address mainnetGovernanceSender;
    }

    struct FrankencoinConfig {
        uint256 minApplicationPeriod;
        address bridgeAccounting;
        address ccipAdmin;
    }

    BridgedGovernance public bridgedGovernance;
    BridgedFrankencoin public bridgedFrankencoin;
    CCIPAdmin public ccipAdmin;
    BurnMintTokenPool public tokenPool;

    error CCIPAdminMismatch(address expected, address actual);

    constructor(CCIPConfig memory _ccipConfig, GovernanceConfig memory _governanceConfig, FrankencoinConfig memory _frankencoinConfig) {
        // Deployment logic
        bridgedGovernance = new BridgedGovernance(_ccipConfig.router, _ccipConfig.mainnetChainSelector, _governanceConfig.mainnetGovernanceSender);
        bridgedFrankencoin = new BridgedFrankencoin(
            bridgedGovernance,
            _ccipConfig.router,
            _frankencoinConfig.minApplicationPeriod,
            _ccipConfig.linkToken,
            _ccipConfig.mainnetChainSelector,
            _frankencoinConfig.bridgeAccounting,
            _frankencoinConfig.ccipAdmin
        );
        ccipAdmin = new CCIPAdmin(_ccipConfig.tokenAdminRegistry, bridgedFrankencoin);
        if (_frankencoinConfig.ccipAdmin != address(ccipAdmin)) revert CCIPAdminMismatch(address(ccipAdmin), _frankencoinConfig.ccipAdmin);

        address[] memory allowlist = new address[](0);
        tokenPool = new BurnMintTokenPool(IBurnMintERC20(address(bridgedFrankencoin)), bridgedFrankencoin.decimals(), allowlist, _ccipConfig.rmnProxy, _ccipConfig.router);
        tokenPool.transferOwnership(address(ccipAdmin));

        address[] memory minters = new address[](1);
        minters[0] = address(tokenPool);

        string[] memory minterComments = new string[](1);
        minterComments[0] = "BurnMintTokenPool";
        bridgedFrankencoin.initialize(minters, minterComments);

        ccipAdmin.registerToken(_ccipConfig.registryModuleOwnerCustom, ITokenPool(address(tokenPool)), _ccipConfig.chainsToAdd);
    }
}
