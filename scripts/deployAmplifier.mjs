// Deploys the UniswapAmplifier with real minting rights, i.e. with the ZCHF token itself as the minter
// contract. The amplifier must subsequently be registered as a minter on the token before it can mint.
// Plain ethers to avoid the hardhat-ethers pending-tx bug.
//
// Run: node scripts/deployAmplifier.mjs <mainnet|optimism>
//
// Writes the deployment data needed for verification to scripts/deployments/amplifier-<network>.json.
// Verify afterwards with: node scripts/verifyAmplifier.mjs <mainnet|optimism>
import { ethers } from "ethers";
import { readFileSync, writeFileSync, mkdirSync } from "fs";
import dotenv from "dotenv";
dotenv.config();

const CONFIGS = {
  mainnet: {
    chainId: 1n,
    rpc: `https://eth-mainnet.g.alchemy.com/v2/${process.env.ALCHEMY_RPC_KEY}`,
    zchf: "0xB58E61C3098d85632Df34EecfB899A1Ed80921cB",
    pool: "0x8e4318e2cb1ae291254b187001a59a1f8ac78cef", // ZCHF-USDT 0.05%
    limit: ethers.parseEther("2500000"), // 2.5 million ZCHF
  },
  optimism: {
    chainId: 10n,
    rpc: `https://opt-mainnet.g.alchemy.com/v2/${process.env.ALCHEMY_RPC_KEY}`,
    zchf: "0xD4dD9e2F021BB459D5A5f6c24C12fE09c5D45553",
    pool: "0xC8A2E29D58B91C37a9d8DC6ab2535EB0b42C8F4b", // ZCHF-USDC 0.05% (native USDC)
    limit: ethers.parseEther("1000000"), // 1 million ZCHF
  },
};

const EXPIRATION = Math.floor(Date.parse("2027-03-31T23:59:59Z") / 1000);
const EXPECTED_DEPLOYER = "0x32Ad7fC7DE54e63971F85F25c691927c87F1A5d9";
const Q96 = 2n ** 96n;

const network = process.argv[2];
const config = CONFIGS[network];
if (!config) {
  console.error("Usage: node scripts/deployAmplifier.mjs <mainnet|optimism>");
  process.exit(1);
}

const provider = new ethers.JsonRpcProvider(config.rpc);
const wallet = ethers.HDNodeWallet.fromPhrase(
  process.env.DEPLOYER_SEED,
  undefined,
  "m/44'/60'/0'/0/0"
).connect(provider);

const artifact = JSON.parse(
  readFileSync("artifacts/contracts/swap/UniswapAmplifier.sol/UniswapAmplifier.json", "utf8")
);

const poolAbi = [
  "function token0() view returns (address)",
  "function token1() view returns (address)",
  "function fee() view returns (uint24)",
  "function slot0() view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool)",
];
const erc20Abi = [
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
];

async function main() {
  if (wallet.address !== EXPECTED_DEPLOYER) {
    throw new Error(`Unexpected deployer ${wallet.address}, expected ${EXPECTED_DEPLOYER}`);
  }
  const { chainId } = await provider.getNetwork();
  if (chainId !== config.chainId) {
    throw new Error(`RPC is chain ${chainId}, expected ${config.chainId}`);
  }
  const balance = await provider.getBalance(wallet.address);
  console.log("Network: ", network, `(chain ${chainId})`);
  console.log("Deployer:", wallet.address);
  console.log("Balance: ", ethers.formatEther(balance), "ETH");
  if (balance === 0n) throw new Error("Deployer has no ETH.");

  // Preview the pool state. The live price becomes the immutable anchor, so eyeball it before deploying
  // and verify PRICE_ANCHOR_X96 against the market rate afterwards, before proposing the minter.
  const pool = new ethers.Contract(config.pool, poolAbi, provider);
  const [token0, token1, slot0] = await Promise.all([pool.token0(), pool.token1(), pool.slot0()]);
  const zchfIsToken0 = token0.toLowerCase() === config.zchf.toLowerCase();
  if (!zchfIsToken0 && token1.toLowerCase() !== config.zchf.toLowerCase()) {
    throw new Error("ZCHF is neither token0 nor token1 of the pool");
  }
  const usdToken = new ethers.Contract(zchfIsToken0 ? token1 : token0, erc20Abi, provider);
  const [usdSymbol, usdDecimals] = await Promise.all([usdToken.symbol(), usdToken.decimals()]);
  const priceX96 = (slot0.sqrtPriceX96 * slot0.sqrtPriceX96) / Q96;
  const usdPerZchfX96 = zchfIsToken0 ? priceX96 : (Q96 * Q96) / priceX96; // USD base units per ZCHF base unit
  const usdPerChf = (Number(usdPerZchfX96) / Number(Q96)) * 10 ** (18 - Number(usdDecimals));
  console.log("\nPool:      ", config.pool, `(ZCHF-${usdSymbol})`);
  console.log("Live price:", usdPerChf.toFixed(4), `${usdSymbol} per ZCHF <-- becomes the anchor, sanity check this!`);
  console.log("Expiration:", new Date(EXPIRATION * 1000).toISOString());
  console.log("Limit:     ", ethers.formatEther(config.limit), "ZCHF");

  const factory = new ethers.ContractFactory(artifact.abi, artifact.bytecode, wallet);
  const deployTx = await factory.getDeployTransaction(
    config.pool,
    config.zchf,
    config.zchf, // the ZCHF token itself acts as the minter contract
    EXPIRATION,
    config.limit
  );

  const nonce = await provider.getTransactionCount(wallet.address);
  console.log("\nPredicted UniswapAmplifier:", ethers.getCreateAddress({ from: wallet.address, nonce }));

  const sent = await wallet.sendTransaction(deployTx);
  console.log("Deployment tx:", sent.hash);

  let receipt = null;
  while (receipt === null) {
    await new Promise((r) => setTimeout(r, 5000));
    receipt = await provider.getTransactionReceipt(sent.hash);
    process.stdout.write(".");
  }
  console.log("\nStatus:", receipt.status === 1 ? "success" : "FAILED");
  if (receipt.status !== 1) throw new Error("Deployment reverted");
  const ampAddr = receipt.contractAddress;
  console.log("UniswapAmplifier deployed at:", ampAddr);

  const amp = new ethers.Contract(ampAddr, artifact.abi, provider);
  const positionImplementation = await amp.positionImplementation();
  console.log("AmplifiedPosition implementation:", positionImplementation);

  const anchorX96 = await amp.PRICE_ANCHOR_X96();
  console.log("\nSanity checks:");
  console.log("  ZCHF_IS_TOKEN0:  ", await amp.ZCHF_IS_TOKEN0());
  console.log("  PRICE_ANCHOR_X96:", anchorX96.toString());
  console.log("  anchor as price: ", ((Number(anchorX96) / Number(Q96)) * 10 ** (18 - Number(usdDecimals))).toFixed(4), `${usdSymbol} per ZCHF`);
  console.log("  MINIMUM_TICK:    ", (await amp.MINIMUM_TICK()).toString());
  console.log("  MAXIMUM_TICK:    ", (await amp.MAXIMUM_TICK()).toString());
  console.log("  EXPIRATION:      ", (await amp.EXPIRATION()).toString());
  console.log("  LIMIT:           ", ethers.formatEther(await amp.LIMIT()), "ZCHF");
  console.log("  USD:             ", await amp.USD());
  console.log("  ZCHF_MINTER:     ", await amp.ZCHF_MINTER(), "(should be the ZCHF token)");
  console.log("  exploitableAt:   ", ethers.formatEther(await amp.exploitableAt()), "CHF/USD");

  mkdirSync("scripts/deployments", { recursive: true });
  const file = `scripts/deployments/amplifier-${network}.json`;
  writeFileSync(
    file,
    JSON.stringify(
      {
        network,
        chainId: chainId.toString(),
        uniswapAmplifier: ampAddr,
        positionImplementation,
        pool: config.pool,
        zchf: config.zchf,
        zchfMinter: config.zchf,
        expiration: EXPIRATION,
        limit: config.limit.toString(),
        deploymentTx: sent.hash,
        priceAnchorX96: anchorX96.toString(),
      },
      null,
      2
    )
  );
  console.log("\nDeployment data written to", file);
  console.log("Verify with: node scripts/verifyAmplifier.mjs", network);
  console.log("\nNext steps:");
  console.log("  1. Verify PRICE_ANCHOR_X96 against the market USD/CHF rate.");
  console.log("  2. Register the amplifier as a minter on the ZCHF token.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
