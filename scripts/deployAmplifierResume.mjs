// Resume script for the amplifier test deployment: the FrankencoinTestMinter was already
// deployed (nonce 0); this deploys the UniswapAmplifier with plain ethers, avoiding the
// hardhat-ethers formatting bug on pending contract-creation transactions.
// Run with: node scripts/deployAmplifierResume.mjs
import { ethers } from "ethers";
import { readFileSync } from "fs";
import dotenv from "dotenv";
dotenv.config();

const RPC = `https://eth-mainnet.g.alchemy.com/v2/${process.env.ALCHEMY_RPC_KEY}`;
const ZCHF = "0xB58E61C3098d85632Df34EecfB899A1Ed80921cB";
const POOL = "0x8e4318e2cb1ae291254b187001a59a1f8ac78cef"; // ZCHF-USDT 0.05%
const MINTER = "0x15CE921192ad967Eb65ea1cc508DfA21120F0d8F"; // deployed at nonce 0
const EXPECTED_DEPLOYER = "0x32Ad7fC7DE54e63971F85F25c691927c87F1A5d9";

const EXPIRATION_SECONDS = 30 * 24 * 60 * 60; // 30 days
const LIMIT = ethers.parseEther("10000"); // 10,000 ZCHF
const Q96 = 2n ** 96n;

const provider = new ethers.JsonRpcProvider(RPC);
const wallet = ethers.HDNodeWallet.fromPhrase(
  process.env.DEPLOYER_SEED,
  undefined,
  "m/44'/60'/0'/0/0"
).connect(provider);

const artifact = JSON.parse(
  readFileSync("artifacts/contracts/swap/UniswapAmplifier.sol/UniswapAmplifier.json", "utf8")
);

async function main() {
  if (wallet.address !== EXPECTED_DEPLOYER) {
    throw new Error(`Unexpected deployer ${wallet.address}, expected ${EXPECTED_DEPLOYER}`);
  }
  console.log("Deployer:", wallet.address);
  console.log("Balance: ", ethers.formatEther(await provider.getBalance(wallet.address)), "ETH");

  // Live pool price, same math as UniswapAmplifier.getPrice()
  const pool = new ethers.Contract(POOL, [
    "function slot0() view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool)",
  ], provider);
  const slot0 = await pool.slot0();
  const expectedPriceQ96 = (slot0.sqrtPriceX96 * slot0.sqrtPriceX96) / Q96;
  console.log("Live pool price (Q96):", expectedPriceQ96.toString());

  const expiration = Math.floor(Date.now() / 1000) + EXPIRATION_SECONDS;
  console.log("Expiration:", new Date(expiration * 1000).toISOString());

  const factory = new ethers.ContractFactory(artifact.abi, artifact.bytecode, wallet);
  const deployTx = await factory.getDeployTransaction(
    POOL, ZCHF, MINTER, expectedPriceQ96, expiration, LIMIT
  );

  const nonce = await provider.getTransactionCount(wallet.address);
  const predicted = ethers.getCreateAddress({ from: wallet.address, nonce });
  console.log("Predicted amplifier address:", predicted);

  const sent = await wallet.sendTransaction(deployTx);
  console.log("Deployment tx:", sent.hash);

  // Poll the receipt directly instead of tx.wait() to sidestep pending-tx formatting issues
  let receipt = null;
  while (receipt === null) {
    await new Promise((r) => setTimeout(r, 5000));
    receipt = await provider.getTransactionReceipt(sent.hash);
    process.stdout.write(".");
  }
  console.log("\nStatus:", receipt.status === 1 ? "success" : "FAILED");
  console.log("Amplifier deployed at:", receipt.contractAddress);

  const amp = new ethers.Contract(receipt.contractAddress, artifact.abi, provider);
  console.log("\nSanity checks:");
  console.log("  TICK_ANCHOR:     ", (await amp.TICK_ANCHOR()).toString());
  console.log("  PRICE_ANCHOR_X96:", (await amp.PRICE_ANCHOR_X96()).toString());
  console.log("  EXPIRATION:      ", (await amp.EXPIRATION()).toString());
  console.log("  LIMIT:           ", ethers.formatEther(await amp.LIMIT()), "ZCHF");
  console.log("  USD:             ", await amp.USD());
  console.log("  ZCHF_MINTER:     ", await amp.ZCHF_MINTER());
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
