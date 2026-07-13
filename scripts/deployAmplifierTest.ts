import { ethers } from "hardhat";

// Test deployment of the UniswapAmplifier on mainnet using the FrankencoinTestMinter
// instead of the real Frankencoin minting rights. No governance proposal is needed;
// instead, ZCHF deposited into the test minter is handed out when positions borrow.

const ZCHF = "0xB58E61C3098d85632Df34EecfB899A1Ed80921cB";
const POOL = "0x8e4318e2cb1ae291254b187001a59a1f8ac78cef"; // ZCHF-USDT 0.05%

const EXPIRATION_SECONDS = 30 * 24 * 60 * 60; // 30 days
const LIMIT = ethers.parseEther("10000"); // 10,000 ZCHF

const Q96 = 2n ** 96n;

async function main() {
  const [deployer] = await ethers.getSigners();
  const { chainId } = await ethers.provider.getNetwork();
  const balance = await ethers.provider.getBalance(deployer.address);

  console.log("Deployer:", deployer.address);
  console.log("Balance: ", ethers.formatEther(balance), "ETH");
  console.log("Chain ID:", chainId.toString());

  if (chainId !== 1n) throw new Error("This script targets Ethereum mainnet (the ZCHF-USDT pool only exists there).");
  if (balance === 0n) throw new Error("Deployer has no ETH. Set your real DEPLOYER_SEED in .env.");

  // Read the live pool price the same way UniswapAmplifier.getPrice() does,
  // so the constructor's +/-1% sanity check always passes.
  const pool = await ethers.getContractAt(
    "contracts/swap/utils/IUniswapV3Pool.sol:IUniswapV3Pool",
    POOL
  );
  const slot0 = await pool.slot0();
  const expectedPriceQ96 = (slot0.sqrtPriceX96 * slot0.sqrtPriceX96) / Q96;
  console.log("Live pool price (Q96):", expectedPriceQ96.toString());

  const expiration = Math.floor(Date.now() / 1000) + EXPIRATION_SECONDS;
  console.log("Expiration:", new Date(expiration * 1000).toISOString());
  console.log("Limit:     ", ethers.formatEther(LIMIT), "ZCHF");

  // 1. Deploy the test minter
  const minterFactory = await ethers.getContractFactory("FrankencoinTestMinter");
  const minter = await minterFactory.deploy(ZCHF);
  await minter.waitForDeployment();
  console.log("\nFrankencoinTestMinter:", await minter.getAddress());

  // 2. Deploy the amplifier
  const amplifierFactory = await ethers.getContractFactory("UniswapAmplifier");
  const amplifier = await amplifierFactory.deploy(
    POOL,
    ZCHF,
    await minter.getAddress(),
    expectedPriceQ96,
    expiration,
    LIMIT
  );
  await amplifier.waitForDeployment();
  console.log("UniswapAmplifier:     ", await amplifier.getAddress());

  console.log("\nSanity checks:");
  console.log("  TICK_ANCHOR:     ", (await amplifier.TICK_ANCHOR()).toString());
  console.log("  PRICE_ANCHOR_X96:", (await amplifier.PRICE_ANCHOR_X96()).toString());
  console.log("  EXPIRATION:      ", (await amplifier.EXPIRATION()).toString());
  console.log("  LIMIT:           ", ethers.formatEther(await amplifier.LIMIT()), "ZCHF");
  console.log("  USD:             ", await amplifier.USD());

  console.log("\nNext steps:");
  console.log("  1. Approve the test minter for ZCHF and call deposit(amount).");
  console.log("  2. Approve the amplifier for USDT (and ZCHF, for repayments).");
  console.log("  3. createAmplifiedPosition(tickLow, tickHigh) and mint into it.");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
