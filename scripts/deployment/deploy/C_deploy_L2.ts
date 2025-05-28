import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { deployContract } from "../deployUtils";
import { L2Deployer } from "../../../typechain";
import { ethers } from "hardhat";
import { ITokenPool } from "../../../typechain/contracts/bridge/CCIPAdmin";
import { BridgedGovernance } from "../../../typechain";

const deploy: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const frankencoinParams = loadParamsFile(
    hre.network.config.chainId,
    "paramsFrankencoin.json"
  );
  const ccipParams = loadParamsFile(
    hre.network.config.chainId,
    "paramsCCIP.json"
  );
  let mainnetCcipParams = loadParamsFile(1, "paramsCCIP.json");
  if (hre.network.config.testnet) {
    mainnetCcipParams = loadParamsFile(11155111, "paramsCCIP.json");
  }

  const BridgedGovernanceArgs = [
    ccipParams["router"],
    mainnetCcipParams["chainSelector"],
    mainnetCcipParams["governanceSender"],
  ];

  console.log("BridgedGovernance ConstructorArgs");
  console.log(JSON.stringify(BridgedGovernanceArgs));
  console.log("");
  const bridgedGovernance = await deployContract<BridgedGovernance>(
    hre,
    "BridgedGovernance",
    BridgedGovernanceArgs
  );

  const L2DeployerConstructorArgs = [
    [
      ccipParams["router"],
      mainnetCcipParams["chainSelector"],
      ccipParams["linkToken"],
      ccipParams["tokenAdminRegistry"],
      ccipParams["rmnProxy"],
      ccipParams["registryModuleOwner"],
      getChainUpdates(hre),
    ],
    await bridgedGovernance.getAddress(),
    [
      frankencoinParams["minApplicationPeriod"],
      mainnetCcipParams["bridgeAccounting"],
      ccipParams["ccipAdmin"],
    ],
  ];

  console.log("L2 Deployer ConstructorArgs");
  console.log(JSON.stringify(L2DeployerConstructorArgs));

  const l2Deployer = await deployContract<L2Deployer>(
    hre,
    "L2Deployer",
    L2DeployerConstructorArgs
  );

  console.log("Deployment complete. Start verification");
  await verifyBridgedGovernance(
    bridgedGovernance,
    ccipParams,
    mainnetCcipParams
  );
  await verifyBridgedFrankencoin(
    await (await ethers.getSigners())[0].getAddress(),
    l2Deployer,
    await bridgedGovernance.getAddress(),
    ccipParams,
    mainnetCcipParams,
    frankencoinParams
  );
  await verifyCCIPAdmin(
    l2Deployer,
    await bridgedGovernance.getAddress(),
    ccipParams
  );
  await verifyTokenPool(l2Deployer, ccipParams);
  await verifyRegistration(l2Deployer, ccipParams);

  const l2TestMinter = await ethers.getContractAt(
    "L2TestMinter",
    await l2Deployer.testMinter()
  );
  verifyProperty(true, await l2TestMinter.used(), "Teset minter didn't mint");

  console.log("Deployed contracts");
  console.log(`BridgedGovernance: ${await bridgedGovernance.getAddress()}`);
  console.log(`BridgedFrankencoin: ${await l2Deployer.bridgedFrankencoin()}`);
  console.log(`CCIPAdmin: ${await l2Deployer.ccipAdmin()}`);
  console.log(`TokenPool: ${await l2Deployer.tokenPool()}`);
  console.log(`TestMinter: ${await l2Deployer.testMinter()}`);
  console.log("");
  // Etherscan verification
  console.log("Run these commands for etherscan verification");
  console.log(
    `npx hardhat verify --network ${
      hre.network.name
    } ${await bridgedGovernance.getAddress()} ${ccipParams["router"]} ${
      mainnetCcipParams["chainSelector"]
    } ${mainnetCcipParams["governanceSender"]}`
  );
  console.log(
    `npx hardhat verify --network ${
      hre.network.name
    } ${await l2Deployer.bridgedFrankencoin()} ${ccipParams["router"]} ${
      frankencoinParams["minApplicationPeriod"]
    } ${ccipParams["linkToken"]} ${mainnetCcipParams["chainSelector"]} ${
      mainnetCcipParams["bridgeAccounting"]
    } ${await l2Deployer.ccipAdmin()}`
  );
  console.log(
    `npx hardhat verify --network ${
      hre.network.name
    } ${await l2Deployer.ccipAdmin()} ${
      ccipParams["tokenAdminRegistry"]
    } ${await l2Deployer.bridgedFrankencoin()}`
  );
  console.log(
    `npx hardhat verify --network ${
      hre.network.name
    } ${await l2Deployer.testMinter()}`
  );
};

function loadParamsFile(chainId: number | undefined, paramsFile: string) {
  if (!chainId) {
    throw new Error("No chainID provided");
  }

  let paramsArr = require(__dirname + `/../parameters/${paramsFile}`);
  // find config for current chain
  for (const params of paramsArr) {
    if (chainId === params.chainId) {
      return params;
    }
  }
  throw new Error(
    `No configuration found for chainID ${chainId} in ${paramsFile}`
  );
}

function getChainUpdates(
  hre: HardhatRuntimeEnvironment
): ITokenPool.ChainUpdateStruct[] {
  const chainUpdates: ITokenPool.ChainUpdateStruct[] = [];
  const abicoder = ethers.AbiCoder.defaultAbiCoder();
  for (const remoteNetworkName in hre.userConfig.networks) {
    const remoteNetwork = hre.userConfig.networks[remoteNetworkName];
    if (
      remoteNetwork?.testnet === hre.network.config.testnet &&
      remoteNetwork?.chainId !== hre.network.config.chainId
    ) {
      try {
        const ccipConfig = loadParamsFile(
          remoteNetwork?.chainId,
          "paramsCCIP.json"
        );

        if (
          ccipConfig["chainSelector"] &&
          ccipConfig["tokenPool"] &&
          ccipConfig["frankencoin"]
        ) {
          chainUpdates.push({
            inboundRateLimiterConfig: {
              isEnabled: false,
              capacity: 0,
              rate: 0,
            },
            outboundRateLimiterConfig: {
              isEnabled: false,
              capacity: 0,
              rate: 0,
            },
            remoteChainSelector: ccipConfig["chainSelector"],
            remotePoolAddresses: [
              abicoder.encode(["address"], [ccipConfig["tokenPool"]]),
            ],
            remoteTokenAddress: abicoder.encode(
              ["address"],
              [ccipConfig["frankencoin"]]
            ),
          });
        }
      } catch {
        // ignore because if a chain is not configured for ccip it doesn't mean we need to abort the deployment
      }
    }
  }
  return chainUpdates;
}

async function verifyBridgedGovernance(
  bridgedGovernance: BridgedGovernance,
  ccipParams: { [index: string]: any },
  mainnetCcipParams: { [index: string]: any }
) {
  console.log("Verify BridgedGovernance");
  verifyProperty(
    ccipParams["router"],
    await bridgedGovernance.getRouter(),
    "router"
  );
  verifyProperty(
    mainnetCcipParams["chainSelector"],
    await bridgedGovernance.MAINNET_CHAIN_SELECTOR(),
    "mainnetChainSelector"
  );
  verifyProperty(
    mainnetCcipParams["governanceSender"],
    await bridgedGovernance.MAINNET_GOVERNANCE_ADDRESS(),
    "governanceSender"
  );
  console.log("BridgedGovernance verified!");
  console.log("");
}

async function verifyBridgedFrankencoin(
  deployer: string,
  l2Deployer: L2Deployer,
  governance: string,
  ccipParams: { [index: string]: any },
  mainnetCcipParams: { [index: string]: any },
  frankencoinParams: { [index: string]: any }
) {
  console.log("Verify BridgedFrankencoin");
  const bridgedFrankencoin = await ethers.getContractAt(
    "BridgedFrankencoin",
    await l2Deployer.bridgedFrankencoin()
  );
  verifyProperty(governance, await bridgedFrankencoin.reserve(), "reserve");
  verifyProperty(
    ccipParams["router"],
    await bridgedFrankencoin.ROUTER(),
    "router"
  );
  verifyProperty(
    frankencoinParams["minApplicationPeriod"],
    await bridgedFrankencoin.MIN_APPLICATION_PERIOD(),
    "minApplicationPeriod"
  );
  verifyProperty(
    ccipParams["linkToken"],
    await bridgedFrankencoin.LINK(),
    "linkToken"
  );
  verifyProperty(
    mainnetCcipParams["chainSelector"],
    await bridgedFrankencoin.MAINNET_CHAIN_SELECTOR(),
    "mainnetChainSelector"
  );
  verifyProperty(
    mainnetCcipParams["bridgeAccounting"],
    await bridgedFrankencoin.BRIDGE_ACCOUNTING(),
    "bridgeAccounting"
  );
  verifyProperty(
    ccipParams["ccipAdmin"],
    await bridgedFrankencoin.getCCIPAdmin(),
    "ccipAdmin"
  );
  verifyProperty(
    true,
    await bridgedFrankencoin.isMinter(await l2Deployer.tokenPool()),
    "tokenpool minter"
  );
  verifyProperty(
    ethers.parseEther("1"),
    await bridgedFrankencoin.balanceOf(deployer),
    "Deployer doesn't have 1 ZCHF"
  );
  console.log("BridgedFrankencoin verified!");
  console.log("");
}

async function verifyCCIPAdmin(
  l2Deployer: L2Deployer,
  governance: string,
  ccipParams: { [index: string]: any }
) {
  console.log("Verify CCIPAdmin");
  const ccipAdmin = await ethers.getContractAt(
    "CCIPAdmin",
    await l2Deployer.ccipAdmin()
  );
  verifyProperty(governance, await ccipAdmin.GOVERNANCE(), "governance");
  verifyProperty(
    ccipParams["tokenAdminRegistry"],
    await ccipAdmin.TOKEN_ADMIN_REGISTRY(),
    "tokenAdminRegistry"
  );
  verifyProperty(
    await l2Deployer.bridgedFrankencoin(),
    await ccipAdmin.ZCHF(),
    "zchf"
  );
  console.log("CCIPAdmin verified!");
  console.log("");
}

async function verifyTokenPool(
  l2Deployer: L2Deployer,
  ccipParams: { [index: string]: any }
) {
  console.log("Verify TokenPool");
  const tokenPool = await ethers.getContractAt(
    "BurnMintTokenPool",
    await l2Deployer.tokenPool()
  );
  verifyProperty(
    await l2Deployer.bridgedFrankencoin(),
    await tokenPool.getToken(),
    "token"
  );
  verifyProperty(18, await tokenPool.getTokenDecimals(), "decimals");
  verifyProperty(false, await tokenPool.getAllowListEnabled(), "decimals");
  verifyProperty(
    ccipParams["rmnProxy"],
    await tokenPool.getRmnProxy(),
    "rmnProxy"
  );
  verifyProperty(ccipParams["router"], await tokenPool.getRouter(), "router");
  verifyProperty(
    await l2Deployer.ccipAdmin(),
    await tokenPool.owner(),
    "owner"
  );
  console.log("TokenPool verified!");
  console.log("");
}

async function verifyRegistration(
  l2Deployer: L2Deployer,
  ccipParams: { [index: string]: any }
) {
  console.log("Verify Registration");
  const tokenAdminRegistry = await ethers.getContractAt(
    "TokenAdminRegistry",
    ccipParams["tokenAdminRegistry"]
  );
  verifyProperty(
    true,
    await tokenAdminRegistry.isAdministrator(
      await l2Deployer.bridgedFrankencoin(),
      await l2Deployer.ccipAdmin()
    ),
    "administrator"
  );

  console.log("Registration verified!");
  console.log("");
}

function verifyProperty(
  expected: string | bigint | number | boolean,
  given: string | bigint | number | boolean,
  property: string
) {
  // lose comparison so we don't need to match the exact type
  if (expected != given) {
    throw new Error(
      `${property} doesn't match! Expected: ${expected} / Given: ${given}`
    );
  }
}

export default deploy;
deploy.tags = ["l2"];
