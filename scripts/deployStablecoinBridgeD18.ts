import { ethers } from "hardhat";
import { ADDRESS } from "../exports/address.config";

// dry-run (default): npx hardhat run scripts/deployStablecoinBridgeD18.ts --network <network>
// submit:            DEPLOY=true npx hardhat run scripts/deployStablecoinBridgeD18.ts --network <network>
const SUBMIT = process.env.DEPLOY === "true";

const OTHER = "0x1fcA74D9ef54a6AC80ffE7D3b14e76c4330Fd5D8"; // source stablecoin (18 decimals), per chain
const LIMIT = ethers.parseEther("1000000"); // max outstanding source stablecoins
const HORIZON_DAYS = 365 + 60; // bridge expires this many days after deployment

async function main() {
  const [deployer] = await ethers.getSigners();
  const chainId = Number((await ethers.provider.getNetwork()).chainId);
  const entry: any = (ADDRESS as any)[chainId];
  const ZCHF: string = entry?.frankencoin ?? entry?.ccipBridgedFrankencoin;
  if (!ZCHF)
    throw new Error(`No Frankencoin address configured for chain ${chainId}`);

  const token = await ethers.getContractAt(
    "contracts/erc20/IERC20.sol:IERC20",
    OTHER
  );
  if ((await token.decimals()) != 18n)
    throw new Error("Source token must have 18 decimals");

  const block = await ethers.provider.getBlock("latest");
  const HORIZON = BigInt(block!.timestamp) + BigInt(HORIZON_DAYS) * 86400n;

  console.log("Deploying with:", deployer.address, "on chain", chainId);
  console.log(
    "Balance:",
    ethers.formatEther(await ethers.provider.getBalance(deployer.address)),
    "ETH"
  );

  console.log("\nConstructor args:");
  console.log("  other:  ", OTHER);
  console.log("  zchf:   ", ZCHF);
  console.log("  limit:  ", ethers.formatEther(LIMIT));
  console.log(
    "  horizon:",
    HORIZON.toString(),
    `(${new Date(Number(HORIZON) * 1000).toISOString()})`
  );

  const StablecoinBridge = await ethers.getContractFactory(
    "StablecoinBridgeD18"
  );

  if (!SUBMIT) {
    const tx = await StablecoinBridge.getDeployTransaction(
      OTHER,
      ZCHF,
      LIMIT,
      HORIZON
    );
    const gas = await ethers.provider.estimateGas({
      ...tx,
      from: deployer.address,
    });
    console.log(
      "\nDRY RUN: deployment would succeed, estimated gas:",
      gas.toString()
    );
    console.log("Set DEPLOY=true to submit.");
    return;
  }

  const bridge = await StablecoinBridge.deploy(OTHER, ZCHF, LIMIT, HORIZON);
  await bridge.waitForDeployment();

  const address = await bridge.getAddress();
  console.log("\nStablecoinBridgeD18 deployed to:", address);
  console.log(
    `\nVerify with:\nnpx hardhat verify --network <network> ${address} ${OTHER} ${ZCHF} ${LIMIT} ${HORIZON}`
  );
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
