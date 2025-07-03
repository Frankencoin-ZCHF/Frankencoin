import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { deployContract } from "../deployUtils";

/*
    //see package.json
    export PK=12...
    // deploy according to config (see package.json), e.g., 
    npm run redeploynotesttoken:network sepolia
    // mint ZCHF via scripts/maintenance/mintCHF.ts (adjust StableCoinBridge address in mintCHF.ts header) 
    ts-node scripts/maintenance/mintCHF.ts
    // verify on https://sepolia.etherscan.io/
    // deploy positions (inspect script A_deploy_...)
    npm run-script deployPositions:network sepolia
*/
const deploy: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const paramFile = "paramsFrankencoin.json";
  let chainId = hre.network.config["chainId"];
  let paramsArr = require(__dirname + `/../parameters/${paramFile}`);

  // find config for current chain
  for (var k = 0; k < paramsArr.length && paramsArr[k].chainId != chainId; k++);
  let params = paramsArr[k];
  if (chainId != params.chainId) {
    throw new Error("ChainId doesn't match");
  }

  let minApplicationPeriod = params["minApplicationPeriod"];
  console.log("\nMin application period =", minApplicationPeriod);

  let FC = await deployContract(hre, "Frankencoin", [
    minApplicationPeriod
  ]);
  console.log(`Verify zchf: 
      npx hardhat verify --network ${hre.network.name} ${await FC.getAddress()} ${minApplicationPeriod}`);

  let reserve = await FC.reserve();
  console.log(
    `Verify Equity:\nnpx hardhat verify --network ${hre.network.name} ${reserve} ${await FC.getAddress()}\n`
  );
};
export default deploy;
deploy.tags = ["main", "Frankencoin"];
