import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying with:", deployer.address);
  console.log("Balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH");

  const Autobidder = await ethers.getContractFactory("Autobidder");
  const autobidder = await Autobidder.deploy();
  await autobidder.waitForDeployment();

  const address = await autobidder.getAddress();
  console.log("Autobidder deployed to:", address);
  console.log(`\nVerify with:\nnpx hardhat verify --network mainnet ${address}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
