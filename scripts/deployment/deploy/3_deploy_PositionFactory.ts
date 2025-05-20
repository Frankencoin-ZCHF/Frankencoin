import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { deployContract } from "../deployUtils";

const deploy: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const {
    deployments: { get },
  } = hre;
  await deployContract(hre, "PositionFactory");

  const positionFactoryDeployment = await get("PositionFactory");
  console.log(
    `Verify PositionFactory:\nnpx hardhat verify --network ${hre.network.name} ${positionFactoryDeployment.address}\n`
  );
};
export default deploy;
deploy.tags = ["main", "PositionFactory"];
