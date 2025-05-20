import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { deployContract } from "../deployUtils";

const deploy: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { network } = hre;
  let chainId = hre.network.config["chainId"];
  let paramsArr = require(__dirname + `/../parameters/paramsCCIP.json`);
  // find config for current chain
  const params = paramsArr.find((x: { chainId: number }) => x.chainId == chainId);

  const router = params["router"];
  const mainnetChainSelector = params["mainnetChainSelector"];
  const mainnetGovernanceSender = params["mainnetGovernanceSender"];

  const bridgedGovernance = await deployContract(hre, "BridgedGovernance", [
    router,
    mainnetChainSelector,
    mainnetGovernanceSender,
  ]);

  console.log(`Verify bridgedGovernance: 
    npx hardhat verify --network ${
      network.name
    } ${await bridgedGovernance.getAddress()} ${router} ${mainnetChainSelector} ${mainnetGovernanceSender}`);
};

export default deploy;
deploy.tags = ["l2"];
