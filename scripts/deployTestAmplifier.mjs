// Deploys the TestAmplifier (contracts/swap/FrankencoinTestMinter.sol) on mainnet. Its constructor deploys the
// UniswapAmplifier for the ZCHF-USDT pool internally. Plain ethers to avoid the hardhat-ethers pending-tx bug.
// Run: node scripts/deployTestAmplifier.mjs
import { ethers } from "ethers";
import { readFileSync } from "fs";
import dotenv from "dotenv";
dotenv.config();

const RPC = `https://eth-mainnet.g.alchemy.com/v2/${process.env.ALCHEMY_RPC_KEY}`;
const ZCHF = "0xB58E61C3098d85632Df34EecfB899A1Ed80921cB";
const POOL = "0x8e4318e2cb1ae291254b187001a59a1f8ac78cef"; // ZCHF-USDT 0.05%
const EXPECTED_DEPLOYER = "0x32Ad7fC7DE54e63971F85F25c691927c87F1A5d9";

const EXPIRATION_SECONDS = 30 * 24 * 60 * 60; // 30 days
const LIMIT = ethers.parseEther("10000"); // 10,000 ZCHF

const provider = new ethers.JsonRpcProvider(RPC);
const wallet = ethers.HDNodeWallet.fromPhrase(
  process.env.DEPLOYER_SEED,
  undefined,
  "m/44'/60'/0'/0/0"
).connect(provider);

const artifact = JSON.parse(
  readFileSync("artifacts/contracts/swap/FrankencoinTestMinter.sol/TestAmplifier.json", "utf8")
);

async function main() {
  if (wallet.address !== EXPECTED_DEPLOYER) {
    throw new Error(`Unexpected deployer ${wallet.address}, expected ${EXPECTED_DEPLOYER}`);
  }
  const balance = await provider.getBalance(wallet.address);
  console.log("Deployer:", wallet.address);
  console.log("Balance: ", ethers.formatEther(balance), "ETH");
  if (balance === 0n) throw new Error("Deployer has no ETH.");

  const expiration = Math.floor(Date.now() / 1000) + EXPIRATION_SECONDS;
  console.log("Expiration:", new Date(expiration * 1000).toISOString());
  console.log("Limit:     ", ethers.formatEther(LIMIT), "ZCHF");

  const factory = new ethers.ContractFactory(artifact.abi, artifact.bytecode, wallet);
  const deployTx = await factory.getDeployTransaction(POOL, ZCHF, expiration, LIMIT);

  const nonce = await provider.getTransactionCount(wallet.address);
  const predictedMinter = ethers.getCreateAddress({ from: wallet.address, nonce });
  const predictedAmp = ethers.getCreateAddress({ from: predictedMinter, nonce: 1 });
  console.log("\nPredicted TestAmplifier: ", predictedMinter);
  console.log("Predicted UniswapAmplifier (nonce 1 of minter):", predictedAmp);

  const sent = await wallet.sendTransaction(deployTx);
  console.log("Deployment tx:", sent.hash);

  let receipt = null;
  while (receipt === null) {
    await new Promise((r) => setTimeout(r, 5000));
    receipt = await provider.getTransactionReceipt(sent.hash);
    process.stdout.write(".");
  }
  console.log("\nStatus:", receipt.status === 1 ? "success" : "FAILED");
  const minterAddr = receipt.contractAddress;
  console.log("TestAmplifier deployed at:", minterAddr);

  const minter = new ethers.Contract(minterAddr, artifact.abi, provider);
  const ampAddr = await minter.AMP();
  console.log("UniswapAmplifier at:      ", ampAddr);

  // sanity reads on the amplifier
  const ampArtifact = JSON.parse(
    readFileSync("artifacts/contracts/swap/UniswapAmplifier.sol/UniswapAmplifier.json", "utf8")
  );
  const amp = new ethers.Contract(ampAddr, ampArtifact.abi, provider);
  console.log("\nSanity checks:");
  console.log("  ZCHF_IS_TOKEN0: ", await amp.ZCHF_IS_TOKEN0());
  console.log("  PRICE_ANCHOR_X96:", (await amp.PRICE_ANCHOR_X96()).toString());
  console.log("  MINIMUM_TICK:   ", (await amp.MINIMUM_TICK()).toString());
  console.log("  MAXIMUM_TICK:   ", (await amp.MAXIMUM_TICK()).toString());
  console.log("  EXPIRATION:     ", (await amp.EXPIRATION()).toString());
  console.log("  LIMIT:          ", ethers.formatEther(await amp.LIMIT()), "ZCHF");
  console.log("  USD:            ", await amp.USD());
  console.log("  ZCHF_MINTER:    ", await amp.ZCHF_MINTER(), "(should be TestAmplifier)");
  console.log("  exploitableAt:  ", ethers.formatEther(await amp.exploitableAt()), "CHF/USD");

  console.log("\nAddresses for verification:");
  console.log(JSON.stringify({ testAmplifier: minterAddr, uniswapAmplifier: ampAddr, expiration, limit: LIMIT.toString() }, null, 2));
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
