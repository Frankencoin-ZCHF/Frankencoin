import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { ethers } from "ethers";

function getChainUpdate(ccipParams: any, chainName: string) {
  const chainCcipParams = ccipParams.find(
    (x: { chainName: string }) =>
      x.chainName.toLowerCase() == chainName.toLowerCase()
  );
  if (
    chainCcipParams["zchf"] &&
    chainCcipParams["tokenPool"] &&
    chainCcipParams["chainSelector"]
  ) {
    const abiCoder = ethers.AbiCoder.defaultAbiCoder();
    return {
      remoteChainSelector: chainCcipParams["chainSelector"],
      remotePoolAddresses: [
        abiCoder.encode(["address"], [chainCcipParams["tokenPool"]]),
      ],
      remoteTokenAddress: abiCoder.encode(
        ["address"],
        [chainCcipParams["zchf"]]
      ),
      outboundRateLimiterConfig: {
        isEnabled: false,
        capacity: 0,
        rate: 0,
      },
      inboundRateLimiterConfig: {
        isEnabled: false,
        capacity: 0,
        rate: 0,
      },
    };
  }
  return undefined;
}

const deploy: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const {
    deployments: { get },
    ethers,
  } = hre;
  let chainId = hre.network.config["chainId"];
  let ccipParamsFile = require(__dirname + `/../parameters/paramsCCIP.json`);
  // find config for current chain
  const ccipParams = ccipParamsFile.find(
    (x: { chainId: number }) => x.chainId == chainId
  );

  const registryModuleOwnerAddress = ccipParams["registryModuleOwner"];
  const ccipAdminDeployment = await get("CCIPAdmin");
  const tokenPoolDeployment = await get("BurnMintTokenPool");
  const savingsDeployment = await get("BridgedSavings");
  const zchfDeployment = await get("BridgedFrankencoin");

  const ccipAdmin = await ethers.getContractAt(
    "CCIPAdmin",
    ccipAdminDeployment.address
  );

  let zchfContract = await ethers.getContractAt(
    "BridgedFrankencoin",
    zchfDeployment.address
  );

  const chainUpdates = (ccipParams["remoteChains"] as string[])
    .map((chain: string) => getChainUpdate(ccipParamsFile, chain))
    .filter((x) => x !== undefined);

  console.log("Add pool and savings as minters...");
  const txMinter = await zchfContract.initialize(
    [tokenPoolDeployment.address, savingsDeployment.address],
    ["CCIP Token Pool", "Bridged Savings"]
  );
  await txMinter.wait();
  console.log("Add pool and savings as minters... Done");
  console.log("Registering token...");
  const adminRegisterTx = await ccipAdmin.registerToken(
    registryModuleOwnerAddress,
    tokenPoolDeployment.address,
    chainUpdates
  );
  console.log(`TX: ${adminRegisterTx.hash}`);
  await adminRegisterTx.wait();
  console.log("Registering token... Done");
};

export default deploy;
deploy.tags = ["l2"];
