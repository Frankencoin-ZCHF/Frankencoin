import hre, { ethers } from "hardhat";
import { ADDRESS } from "../exports/address.config";
import { mainnet } from "viem/chains";

// Arachnid deterministic deployment proxy — same address on all EVM chains.
// See: https://github.com/Arachnid/deterministic-deployment-proxy
const ARACHNID_FACTORY = "0x4e59b44847b379578588920cA78FbF26c0B4956C";

// Change this string only on breaking upgrades to get a fresh address.
const SALT = ethers.id("TransferWithAuthorization-v1");

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

async function main() {
  const execute = process.env.EXECUTE === "true";

  const privateKey = process.env.PRIVATE_KEY;
  if (!privateKey) throw new Error("Missing PRIVATE_KEY in .env");
  const deployer = new ethers.Wallet(privateKey, ethers.provider);
  const { chainId } = await ethers.provider.getNetwork();
  const chain   = Number(chainId);
  const network = hre.network.name;

  console.log(`\nUsage: EXECUTE=true npx hardhat run scripts/deployTransferWithAuthorization.ts --network <name>`);
  console.log(`\nMode:       ${execute ? "EXECUTE" : "dry run  (pass --execute to send transactions)"}`);
  console.log(`Network:    ${network} (chain ${chain})`);
  console.log("Deployer:  ", deployer.address);
  console.log(
    "Balance:   ",
    ethers.formatEther(await ethers.provider.getBalance(deployer.address)),
    "ETH"
  );

  // resolve asset address — mainnet uses native frankencoin, all others use the CCIP bridged token
  const chainAddresses = ADDRESS[chain as keyof typeof ADDRESS];
  if (!chainAddresses)
    throw new Error(`Chain ${chain} not found in address.config`);
  const asset =
    chain === mainnet.id
      ? (chainAddresses as { frankencoin: string }).frankencoin
      : (chainAddresses as { ccipBridgedFrankencoin: string })
          .ccipBridgedFrankencoin;
  if (!asset) throw new Error(`No asset address configured for chain ${chain}`);
  console.log("Asset:      ", asset);

  // ── 1. predict address ────────────────────────────────────────────────────
  const factory  = await ethers.getContractFactory("TransferWithAuthorization");
  const initCode = factory.bytecode; // no constructor args

  const predicted = ethers.getCreate2Address(
    ARACHNID_FACTORY,
    SALT,
    ethers.keccak256(initCode)
  );
  console.log("\nPredicted address:", predicted);

  // ── 2. deploy if not yet on-chain ─────────────────────────────────────────
  const existingCode = await ethers.provider.getCode(predicted);
  if (existingCode !== "0x") {
    console.log("Already deployed — skipping deploy step.");
  } else if (!execute) {
    console.log("[dry run] Would deploy via Arachnid factory.");
  } else {
    // The Arachnid factory is raw assembly — no function selector.
    // Calldata layout: [salt (32 bytes)][initcode]
    const tx = await deployer.sendTransaction({
      to: ARACHNID_FACTORY,
      data: ethers.concat([SALT, initCode]),
    });
    await tx.wait();
    console.log("Deployed in tx:", tx.hash);

    const deployedCode = await ethers.provider.getCode(predicted);
    if (deployedCode === "0x")
      throw new Error("Deployment failed — no code at predicted address.");
    console.log("Deployed to:", predicted);

    console.log("Waiting 30s for RPC propagation...");
    await sleep(30_000);
  }

  // ── 3. initialize if not yet done ─────────────────────────────────────────
  const liveCode = await ethers.provider.getCode(predicted);
  if (liveCode === "0x") {
    // Contract not on-chain yet (dry run skipped deploy)
    console.log("[dry run] Would initialize with asset:", asset);
  } else {
    const contract     = await ethers.getContractAt("TransferWithAuthorization", predicted);
    const currentAsset = await contract.asset();

    if (currentAsset !== ethers.ZeroAddress) {
      console.log("Already initialized with asset:", currentAsset);
    } else if (!execute) {
      console.log("[dry run] Would initialize with asset:", asset);
    } else {
      const tx = await contract.initialize(asset);
      await tx.wait();
      console.log("Initialized in tx:", tx.hash);
      console.log("Initialized with asset:", asset);

      console.log("Waiting 30s for Etherscan to index the contract...");
      await sleep(30_000);
    }
  }

  if (!execute) {
    console.log("\nDry run complete — no transactions sent. Pass --execute to deploy for real.\n");
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
