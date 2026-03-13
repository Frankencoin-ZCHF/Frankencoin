import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { deployContract } from "../deployUtils";

const deploy: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  let autobidderContract = await deployContract(hre, "Autobidder", []);

  console.log(`Verify Autobidder:
npx hardhat verify --network ${hre.network.name} ${await autobidderContract.getAddress()}
`);
};
export default deploy;
deploy.tags = ["Autobidder"];
