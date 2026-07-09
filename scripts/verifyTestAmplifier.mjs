// Verify the TestAmplifier and its internally-deployed UniswapAmplifier on Etherscan (v2 API).
// Run: node scripts/verifyTestAmplifier.mjs
import { ethers } from "ethers";
import { readFileSync } from "fs";
import dotenv from "dotenv";
dotenv.config();

const API = "https://api.etherscan.io/v2/api?chainid=1";
const KEY = process.env.ETHERSCAN_API;
if (!KEY) throw new Error("No ETHERSCAN_API in .env");

const ZCHF = "0xB58E61C3098d85632Df34EecfB899A1Ed80921cB";
const POOL = "0x8e4318e2cb1ae291254b187001a59a1f8ac78cef";
const TEST_AMPLIFIER = "0xD6341D6C72210f13e5D5fF814c823ebf6d9342E0";
const UNISWAP_AMPLIFIER = "0x5B67Ec8F63bEB0Fd9FDbeCe4BbbA94A044f28Db6";
const EXPIRATION = 1786185960n;
const LIMIT = 10_000_000000000000000000n; // 10,000 ZCHF

const BUILD_INFO = "artifacts/build-info/178822312f2287affca6560a29d982f4.json";
const abiCoder = ethers.AbiCoder.defaultAbiCoder();

const jobs = [
  {
    name: "TestAmplifier",
    address: TEST_AMPLIFIER,
    contract: "contracts/swap/FrankencoinTestMinter.sol:TestAmplifier",
    args: abiCoder.encode(
      ["address", "address", "uint40", "uint256"],
      [POOL, ZCHF, EXPIRATION, LIMIT]
    ),
  },
  {
    name: "UniswapAmplifier",
    address: UNISWAP_AMPLIFIER,
    contract: "contracts/swap/UniswapAmplifier.sol:UniswapAmplifier",
    args: abiCoder.encode(
      ["address", "address", "address", "uint40", "uint256"],
      [POOL, ZCHF, TEST_AMPLIFIER, EXPIRATION, LIMIT]
    ),
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

async function verify(job, buildInfo) {
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
  if (submit.status !== "1") {
    if (String(submit.result).includes("already verified")) return;
    return;
  }
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

const buildInfo = JSON.parse(readFileSync(BUILD_INFO, "utf8"));
for (const job of jobs) {
  await verify(job, buildInfo);
}
