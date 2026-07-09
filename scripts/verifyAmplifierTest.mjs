// Verify the two test-deployment contracts on Etherscan via the v2 API,
// using the exact standard-JSON compiler input from Hardhat's build info.
import { ethers } from "ethers";
import { readFileSync } from "fs";
import dotenv from "dotenv";
dotenv.config();

const API = "https://api.etherscan.io/v2/api?chainid=1";
const KEY = process.env.ETHERSCAN_API;
if (!KEY) throw new Error("No ETHERSCAN_API in .env");

const abiCoder = ethers.AbiCoder.defaultAbiCoder();

const jobs = [
  {
    name: "FrankencoinTestMinter",
    address: "0x15CE921192ad967Eb65ea1cc508DfA21120F0d8F",
    contract: "contracts/test/FrankencoinTestMinter.sol:FrankencoinTestMinter",
    buildInfo: "artifacts/build-info/3f30c23b28061f18570d7f3bb05006d9.json",
    args: abiCoder.encode(["address"], ["0xB58E61C3098d85632Df34EecfB899A1Ed80921cB"]),
  },
  {
    name: "UniswapAmplifier",
    address: "0x1a37135C07738aD9c7561A55011Fefea854751F5",
    contract: "contracts/swap/UniswapAmplifier.sol:UniswapAmplifier",
    buildInfo: "artifacts/build-info/96fddcb510219d83a52ae26f2957512a.json",
    args: abiCoder.encode(
      ["address", "address", "address", "uint160", "uint40", "uint256"],
      [
        "0x8e4318e2cb1ae291254b187001a59a1f8ac78cef",
        "0xB58E61C3098d85632Df34EecfB899A1Ed80921cB",
        "0x15CE921192ad967Eb65ea1cc508DfA21120F0d8F",
        98575206862638400n,
        1785947543n,
        ethers.parseEther("10000"),
      ]
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

async function verify(job) {
  const buildInfo = JSON.parse(readFileSync(job.buildInfo, "utf8"));
  console.log(`\n=== ${job.name} at ${job.address} ===`);

  const submit = await api({
    module: "contract",
    action: "verifysourcecode",
    codeformat: "solidity-standard-json-input",
    sourceCode: JSON.stringify(buildInfo.input),
    contractaddress: job.address,
    contractname: job.contract,
    compilerversion: `v${buildInfo.solcLongVersion}`,
    constructorArguements: job.args.slice(2), // Etherscan's (sic) param name, hex without 0x
  });
  console.log("Submit:", submit.status === "1" ? `OK, guid ${submit.result}` : submit.result);
  if (submit.status !== "1") {
    if (String(submit.result).includes("already verified")) return;
    throw new Error(submit.result);
  }

  for (let i = 0; i < 20; i++) {
    await new Promise((r) => setTimeout(r, 5000));
    const check = await api({
      module: "contract",
      action: "checkverifystatus",
      guid: submit.result,
    });
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
