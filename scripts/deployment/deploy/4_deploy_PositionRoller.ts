import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { deployContract } from "../deployUtils";

const deploy: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const {
    deployments: { get },
    ethers,
  } = hre;
  const zchfDeployment = await get("Frankencoin");
  let positionRollerContract = await deployContract(hre, "PositionRoller", [
    zchfDeployment.address,
  ]);

  console.log(`Verify mintingHubContract: 
    npx hardhat verify --network ${hre.network.name} ${await positionRollerContract.getAddress()} ${zchfDeployment.address}
  `);
};

export default deploy;
deploy.tags = ["main", "PositionRoller"];
