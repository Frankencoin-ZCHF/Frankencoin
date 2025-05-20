import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { deployContract } from "../deployUtils";

const deploy: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const {
    deployments: { get },
  } = hre;
  let chainId = hre.network.config["chainId"];
  let ccipParamsFile = require(__dirname + `/../parameters/paramsCCIP.json`);
  // find config for current chain
  const ccipParams = ccipParamsFile.find(
    (x: { chainId: number }) => x.chainId == chainId
  );

  const tokenAdminRegistry = ccipParams["tokenAdminRegistry"];
  const zchfDeployment = await get("BridgedFrankencoin");

  const ccipAdmin = await deployContract(hre, "CCIPAdmin", [
    tokenAdminRegistry,
    zchfDeployment.address,
  ]);

  console.log(`Verify ccipadmin: 
    npx hardhat verify --network ${
      hre.network.name
    } ${await ccipAdmin.getAddress()} ${tokenAdminRegistry} ${
    zchfDeployment.address
  }
  `);
};

export default deploy;
deploy.tags = ["l2"];
