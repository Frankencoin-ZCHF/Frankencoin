import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { deployContract } from "../deployUtils";

const deploy: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const {
    network,
    deployments: { get },
  } = hre;
  let chainId = hre.network.config["chainId"];
  let paramsArr = require(__dirname + `/../parameters/paramsCCIP.json`);
  // find config for current chain
  const params = paramsArr.find(
    (x: { chainId: number }) => x.chainId == chainId
  );

  let leadrateParamsArr = require(__dirname +
    `/../parameters/paramsLeadrate.json`);
  // find config for current chain
  const leadrateParams = leadrateParamsArr.find(
    (x: { chainId: number }) => x.chainId == chainId
  );

  const router = params["router"];
  const mainnetChainSelector = params["mainnetChainSelector"];
  const mainnetLeadrateSender = params["mainnetLeadrateSender"];
  const frankencoin = await get("BridgedFrankencoin");

  const bridgedSavings = await deployContract(hre, "BridgedSavings", [
    frankencoin.address,
    router,
    leadrateParams["initialRatePPM"],
    mainnetChainSelector,
    mainnetLeadrateSender,
  ]);

  console.log(`Verify bridgedSavings: 
    npx hardhat verify --network ${
      network.name
    } ${await bridgedSavings.getAddress()} ${frankencoin.address} ${router} ${
    leadrateParams["initialRatePPM"]
  } ${mainnetChainSelector} ${mainnetLeadrateSender}`);
};

export default deploy;
deploy.tags = ["l2"];
