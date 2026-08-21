import hre, { ethers } from "hardhat";
import { ADDRESS } from "../exports/address.config";
import { mainnet } from "viem/chains";

// Arachnid deterministic deployment proxy — same address on all EVM chains.
// See: https://github.com/Arachnid/deterministic-deployment-proxy
const ARACHNID_FACTORY = "0x4e59b44847b379578588920cA78FbF26c0B4956C";

const SALT = ethers.id("TransferWithAuthorization-v2");

// Must match `_deployer` in TransferWithAuthorizationV2 — it is the only address `initialize`
// accepts. CREATE2 through the Arachnid factory is permissionless, so deploying with any other
// key strands an uninitialisable contract at the deterministic address.
const EXPECTED_DEPLOYER = "0x045a8395FE21CE34f0eC34d242c342ade4Ded5be";

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

async function main() {
  const execute = process.env.EXECUTE === "true";

  const privateKey = process.env.PRIVATE_KEY;
  if (!privateKey) throw new Error("Missing PRIVATE_KEY in .env");
  const deployer = new ethers.Wallet(privateKey, ethers.provider);
  if (
    ethers.getAddress(deployer.address) !== ethers.getAddress(EXPECTED_DEPLOYER)
  ) {
    throw new Error(
      `PRIVATE_KEY resolves to ${deployer.address}, but the contract only accepts ${EXPECTED_DEPLOYER} as initializer.`
    );
  }
  const { chainId } = await ethers.provider.getNetwork();
  const chain = Number(chainId);
  const network = hre.network.name;

  console.log(
    `\nUsage: EXECUTE=true npx hardhat run scripts/deployTransferWithAuthorizationV2.ts --network <name>`
  );
  console.log(
    `\nMode:       ${execute ? "EXECUTE" : "dry run  (set EXECUTE=true to send transactions)"}`
  );
  console.log(`Network:    ${network} (chain ${chain})`);
  console.log("Deployer:  ", deployer.address);
  console.log(
    "Balance:   ",
    ethers.formatEther(await ethers.provider.getBalance(deployer.address)),
    "ETH"
  );

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

  const factory = await ethers.getContractFactory(
    "TransferWithAuthorizationV2"
  );
  const initCode = factory.bytecode;

  const predicted = ethers.getCreate2Address(
    ARACHNID_FACTORY,
    SALT,
    ethers.keccak256(initCode)
  );
  console.log("\nPredicted address:", predicted);

  const existingCode = await ethers.provider.getCode(predicted);
  if (existingCode !== "0x") {
    console.log("Already deployed — skipping deploy step.");
  } else if (!execute) {
    console.log("[dry run] Would deploy via Arachnid factory.");
  } else {
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

  const liveCode = await ethers.provider.getCode(predicted);
  if (liveCode === "0x") {
    console.log("[dry run] Would initialize with asset:", asset);
  } else {
    const contract = await ethers.getContractAt(
      "TransferWithAuthorizationV2",
      predicted,
      deployer
    );
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
    console.log(
      "\nDry run complete — no transactions sent. Set EXECUTE=true to deploy for real.\n"
    );
  }

  // Deploying and initializing is not enough: the sidecar moves funds through the implicit
  // infinite allowance that the token grants its minters, so every authorization reverts until
  // governance has approved it.
  console.log(
    `\nNEXT STEP — the sidecar stays inert until it is an approved minter:\n` +
      `  ZCHF.suggestMinter(${predicted}, ZCHF.MIN_APPLICATION_PERIOD(), ZCHF.MIN_FEE(), "EIP-3009 sidecar V2")\n` +
      `  The caller must hold ZCHF.MIN_FEE(); the application period must then pass without a qualified veto.\n` +
      `  Live once ZCHF.isMinter(${predicted}) == true.\n`
  );
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
