// Verifies the UniswapAmplifier and its AmplifiedPosition implementation on Etherscan (v2 API),
// using the deployment data written by scripts/deployAmplifier.mjs.
// Run: node scripts/verifyAmplifier.mjs <mainnet|optimism>
import { ethers } from "ethers";
import { readFileSync } from "fs";
import { dirname, join } from "path";
import dotenv from "dotenv";
dotenv.config();

const CHAIN_IDS = { mainnet: 1, optimism: 10 };

const network = process.argv[2];
if (!CHAIN_IDS[network]) {
  console.error("Usage: node scripts/verifyAmplifier.mjs <mainnet|optimism>");
  process.exit(1);
}

const API = `https://api.etherscan.io/v2/api?chainid=${CHAIN_IDS[network]}`;
const KEY = process.env.ETHERSCAN_API;
if (!KEY) throw new Error("No ETHERSCAN_API in .env");

const deployment = JSON.parse(readFileSync(`scripts/deployments/amplifier-${network}.json`, "utf8"));

// Locate the build info of the current UniswapAmplifier artifact. This only matches the deployed
// bytecode if the contract has not been recompiled from different sources since the deployment.
const dbgPath = "artifacts/contracts/swap/UniswapAmplifier.sol/UniswapAmplifier.dbg.json";
const dbg = JSON.parse(readFileSync(dbgPath, "utf8"));
const buildInfo = JSON.parse(readFileSync(join(dirname(dbgPath), dbg.buildInfo), "utf8"));

const abiCoder = ethers.AbiCoder.defaultAbiCoder();

const jobs = [
  {
    name: "UniswapAmplifier",
    address: deployment.uniswapAmplifier,
    contract: "contracts/swap/UniswapAmplifier.sol:UniswapAmplifier",
    args: abiCoder.encode(
      ["address", "address", "address", "uint40", "uint256"],
      [deployment.pool, deployment.zchf, deployment.zchfMinter, deployment.expiration, deployment.limit]
    ),
  },
  {
    name: "AmplifiedPosition (implementation)",
    address: deployment.positionImplementation,
    contract: "contracts/swap/UniswapAmplifier.sol:AmplifiedPosition",
    args: abiCoder.encode(["address"], [deployment.uniswapAmplifier]),
  },
];

async function api(params) {
  const res = await fetch(API, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ apikey: KEY, ...params }),
  });
  return res.json();
}

async function verify(job) {
  console.log(`\n=== ${job.name} at ${job.address} ===`);
  const submit = await api({
    module: "contract",
    action: "verifysourcecode",
    codeformat: "solidity-standard-json-input",
    sourceCode: JSON.stringify(buildInfo.input),
    contractaddress: job.address,
    contractname: job.contract,
    compilerversion: `v${buildInfo.solcLongVersion}`,
    constructorArguements: job.args.slice(2),
  });
  console.log("Submit:", submit.status === "1" ? `OK, guid ${submit.result}` : submit.result);
  if (submit.status !== "1") return;
  for (let i = 0; i < 24; i++) {
    await new Promise((r) => setTimeout(r, 5000));
    const check = await api({ module: "contract", action: "checkverifystatus", guid: submit.result });
    if (String(check.result).includes("Pending")) {
      process.stdout.write(".");
      continue;
    }
    console.log("\nResult:", check.result);
    return;
  }
  console.log("\nTimed out waiting for verification status.");
}

for (const job of jobs) {
  await verify(job);
}
