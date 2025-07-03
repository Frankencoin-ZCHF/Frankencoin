import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { deployContract, sleep } from "../deployUtils";
import { floatToDec18 } from "../../math";
import { StablecoinBridge } from "../../../typechain";
var prompt = require("prompt");

async function getAddress() {
  // local node address
  let addr = "0x5FC8d32690cc91D4c39d9d3abcBD16989F875707";

  console.log("Is this address for MOCKCHF ok? [y,N]", addr);
  prompt.start();
  const { isOk } = await prompt.get(["isOk"]);
  if (isOk != "y" && isOk != "Y") {
    return "";
  }
  return addr;
}

const deploy: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const limit = 10_000_000;
  const {
    deployments: { get },
    ethers,
  } = hre;
  let xchfAddress;
  let applicationMsg;
  if (["hardhat", "localhost", "${hre.network.name}"].includes(hre.network.name)) {
    console.log("Setting Mock-XCHF-Token Bridge");
    try {
      const xchfDeployment = await get("TestToken");
      xchfAddress = xchfDeployment.address;
    } catch (err: unknown) {
      xchfAddress = await getAddress();
      if (xchfAddress == "") {
        throw err;
      }
    }

    applicationMsg = "MockXCHF Token Bridge";
  } else {
    console.log("Deploying XCHF-Token Bridge");
    xchfAddress = "0xb4272071ecadd69d933adcd19ca99fe80664fc08";
    applicationMsg = "XCHF Bridge";
  }
  const ZCHFDeployment = await get("Frankencoin");
  let zchfContract = await ethers.getContractAt(
    "Frankencoin",
    ZCHFDeployment.address
  );

  let dLimit = floatToDec18(limit);
  console.log("\nDeploying StablecoinBridge with limit = ", limit, "CHF");
  await deployContract(hre, "StablecoinBridge", [
    xchfAddress,
    ZCHFDeployment.address,
    dLimit,
  ]);

  // suggest minter
  const bridgeDeployment = await get("StablecoinBridge");
  let bridgeAddr: string = bridgeDeployment.address;

  console.log(
    `Verify StablecoinBridge:\nnpx hardhat verify --network ${hre.network.name} ${bridgeAddr} ${xchfAddress} ${ZCHFDeployment.address} ${dLimit}\n`
  );

  let isAlreadyMinter = await zchfContract.isMinter(bridgeAddr);
  if (isAlreadyMinter) {
    console.log(bridgeDeployment.address, "already is a minter");
  } else {
    let msg = "XCHF Bridge";
    console.log(
      "Apply for the bridge ",
      bridgeDeployment.address,
      "to be minter via zchf.initialize"
    );
    let tx = await zchfContract.initialize(bridgeDeployment.address, msg);
    console.log("tx hash = ", tx.hash);
    await tx.wait();
    let isMinter = false;
    let trial = 0;
    while (!isMinter && trial < 5) {
      console.log("Waiting 20s...");
      await sleep(20 * 1000);
      isMinter = await zchfContract.isMinter(bridgeAddr, {
        gasLimit: 1_000_000,
      });
      console.log("Is minter? ", isMinter);
      trial += 1;
    }
  }

/*   if (["hardhat", "localhost", "${hre.network.name}"].includes(hre.network.name)) {
    let amount = floatToDec18(20_000);
    const mockXCHF = await ethers.getContractAt("TestToken", xchfAddress);
    await mockXCHF.approve(bridgeAddr, amount);
    const bridge = await ethers.getContractAt("StablecoinBridge", bridgeAddr);
    await bridge.mint(amount);
  } */
};
export default deploy;
deploy.tags = ["main", "XCHFBridge"];
