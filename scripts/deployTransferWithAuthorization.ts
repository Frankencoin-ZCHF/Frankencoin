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
  const [deployer] = await ethers.getSigners();
  const { chainId } = await ethers.provider.getNetwork();
  const chain = Number(chainId);

  console.log("Deployer:   ", deployer.address);
  console.log(
    "Balance:    ",
    ethers.formatEther(await ethers.provider.getBalance(deployer.address)),
    "ETH"
  );
  console.log("Chain ID:   ", chain);

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
  const factory = await ethers.getContractFactory("TransferWithAuthorization");
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
  const contract = await ethers.getContractAt(
    "TransferWithAuthorization",
    predicted
  );
  const currentAsset = await contract.asset();

  if (currentAsset !== ethers.ZeroAddress) {
    console.log("Already initialized with asset:", currentAsset);
  } else {
    const tx = await contract.initialize(asset);
    await tx.wait();
    console.log("Initialized in tx:", tx.hash);
    console.log("Initialized with asset:", asset);
  }

  console.log("Waiting 30s for Etherscan to index the contract...");
  await sleep(30_000);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
