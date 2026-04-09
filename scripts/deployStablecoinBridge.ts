import { ethers } from "hardhat";

const OTHER = "0xBD4DfC058eb95b8De5ceAF39966A1a70F5556F78";
const ZCHF = "0xB58E61C3098d85632Df34EecfB899A1Ed80921cB";
const LIMIT = ethers.parseEther("10000000"); // 10 million ZCHF

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying with:", deployer.address);
  console.log("Balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH");

  console.log("\nConstructor args:");
  console.log("  other:", OTHER);
  console.log("  zchf:", ZCHF);
  console.log("  limit:", ethers.formatEther(LIMIT), "ZCHF");

  const StablecoinBridge = await ethers.getContractFactory("StablecoinBridge");
  const bridge = await StablecoinBridge.deploy(OTHER, ZCHF, LIMIT);
  await bridge.waitForDeployment();

  const address = await bridge.getAddress();
  console.log("\nStablecoinBridge deployed to:", address);
  console.log(`\nVerify with:\nnpx hardhat verify --network mainnet ${address} ${OTHER} ${ZCHF} ${LIMIT}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
