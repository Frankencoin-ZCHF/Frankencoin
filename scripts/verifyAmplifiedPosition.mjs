// Verify an AmplifiedPosition created by the test UniswapAmplifier on Etherscan.
// Constructor args are read from the position itself.
// Usage: node scripts/verifyAmplifiedPosition.mjs <positionAddress>
import { ethers } from "ethers";
import { readFileSync } from "fs";
import dotenv from "dotenv";
dotenv.config();

const API = "https://api.etherscan.io/v2/api?chainid=1";
const KEY = process.env.ETHERSCAN_API;
const RPC = `https://eth-mainnet.g.alchemy.com/v2/${process.env.ALCHEMY_RPC_KEY}`;
const AMPLIFIER = "0x1a37135C07738aD9c7561A55011Fefea854751F5";
const BUILD_INFO = "artifacts/build-info/96fddcb510219d83a52ae26f2957512a.json";

const position = process.argv[2];
if (!position) throw new Error("Usage: node scripts/verifyAmplifiedPosition.mjs <positionAddress>");
if (!KEY) throw new Error("No ETHERSCAN_API in .env");

const provider = new ethers.JsonRpcProvider(RPC);

async function api(params) {
  const res = await fetch(API, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ apikey: KEY, ...params }),
  });
  return res.json();
}

async function main() {
  const pos = new ethers.Contract(position, [
    "function owner() view returns (address)",
    "function tickLow() view returns (int24)",
    "function tickHigh() view returns (int24)",
  ], provider);
  const amp = new ethers.Contract(AMPLIFIER, [
    "function positionCreationDate(address) view returns (uint256)",
  ], provider);

  const created = await amp.positionCreationDate(position);
  if (created === 0n) throw new Error("Not a position of the test amplifier");

  const [owner, tickLow, tickHigh] = await Promise.all([pos.owner(), pos.tickLow(), pos.tickHigh()]);
  console.log("Position:", position);
  console.log("Owner:   ", owner, "(assumed unchanged since creation)");
  console.log("Ticks:   ", tickLow.toString(), "to", tickHigh.toString());

  const args = ethers.AbiCoder.defaultAbiCoder().encode(
    ["address", "address", "int24", "int24"],
    [AMPLIFIER, owner, tickLow, tickHigh]
  );

  const buildInfo = JSON.parse(readFileSync(BUILD_INFO, "utf8"));
  const submit = await api({
    module: "contract",
    action: "verifysourcecode",
    codeformat: "solidity-standard-json-input",
    sourceCode: JSON.stringify(buildInfo.input),
    contractaddress: position,
    contractname: "contracts/swap/UniswapAmplifier.sol:AmplifiedPosition",
    compilerversion: `v${buildInfo.solcLongVersion}`,
    constructorArguements: args.slice(2),
  });
  console.log("Submit:", submit.status === "1" ? `OK, guid ${submit.result}` : submit.result);
  if (submit.status !== "1") return;

  for (let i = 0; i < 20; i++) {
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

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
