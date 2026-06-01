import { config } from "dotenv";
config();

import { parseEther, formatUnits } from "viem";
import { arbitrum, avalanche, base, gnosis, mainnet, optimism, polygon, sonic } from "viem/chains";
import fs from "fs/promises";
import path from "path";

// ─── Chain registry ───────────────────────────────────────────────────────────

const CHAINS = [mainnet, polygon, arbitrum, optimism, base, avalanche, gnosis, sonic];

// ─── Types ────────────────────────────────────────────────────────────────────

type RateConfig = { isEnabled: boolean; capacity: string; rate: string };

type LaneConfig = {
  source: string;
  sourceChainId: number;
  ccipAdmin: string;
  destination: string;
  destinationChainId: number | null;
  destinationSelector: string;
  incoming: RateConfig;
  outgoing: RateConfig;
};

// ─── Helpers ──────────────────────────────────────────────────────────────────

function resolveChainName(name: string): string | "all" {
  if (name.toLowerCase() === "all") return "all";
  const match = CHAINS.find((c) => c.name.toLowerCase() === name.toLowerCase());
  if (!match) {
    console.error(`Unknown chain: "${name}"`);
    console.error("Available:", CHAINS.map((c) => c.name).join(", "));
    process.exit(1);
  }
  return match.name;
}

function fmtRate(ratePerSec: bigint): string {
  const perHour = Number(formatUnits(ratePerSec * 3600n, 18)).toLocaleString("en-US", { maximumFractionDigits: 2 });
  return `${perHour} ZCHF/h`;
}

function fmtCap(capacity: bigint): string {
  return Number(formatUnits(capacity, 18)).toLocaleString("en-US", { maximumFractionDigits: 2 }) + " ZCHF";
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  const argv = process.argv.slice(2).filter((a) => !a.startsWith("--"));

  if (argv.length < 4) {
    console.error("Usage: ts-node setRate.ts <source> <destination> <limit> <rate>");
    console.error("  source      chain name or 'all'  (tokens flow FROM here)");
    console.error("  destination chain name or 'all'  (tokens flow TO here)");
    console.error("  limit       bucket capacity in ZCHF (e.g. 500000)");
    console.error("  rate        refill rate in ZCHF/hour (e.g. 10000)");
    console.error("\nAvailable chains:", CHAINS.map((c) => c.name).join(", "));
    process.exit(1);
  }

  const [sourceName, destName, limitStr, rateStr] = argv;

  const srcName = resolveChainName(sourceName);
  const dstName = resolveChainName(destName);

  const capacity   = parseEther(limitStr);
  const ratePerSec = parseEther(rateStr) / 3600n;

  const newConfig: RateConfig = {
    isEnabled: true,
    capacity:  capacity.toString(),
    rate:      ratePerSec.toString(),
  };

  // Load applyRates.json
  const jsonPath = path.join(__dirname, "applyRates.json");
  let lanes: LaneConfig[];
  try {
    lanes = JSON.parse(await fs.readFile(jsonPath, "utf-8"));
  } catch {
    console.error(`Cannot read ${jsonPath}`);
    process.exit(1);
  }

  // For each lane, determine whether the source→destination direction
  // matches this lane's outgoing flow or its incoming flow.
  //
  // Lane (source=A, dest=B):
  //   outgoing = tokens leaving A toward B  → matches direction srcName→dstName when A=src, B=dst
  //   incoming = tokens arriving at A from B → matches direction srcName→dstName when B=src, A=dst
  //
  // "all" acts as a wildcard for either side.

  let changed = 0;

  for (const lane of lanes) {
    const touchOutgoing =
      (srcName === "all" || lane.source      === srcName) &&
      (dstName === "all" || lane.destination === dstName);

    const touchIncoming =
      (srcName === "all" || lane.destination === srcName) &&
      (dstName === "all" || lane.source      === dstName);

    if (touchOutgoing) lane.outgoing = newConfig;
    if (touchIncoming) lane.incoming = newConfig;
    if (touchOutgoing || touchIncoming) changed++;
  }

  if (changed === 0) {
    console.error(`No matching lanes found for "${sourceName}" → "${destName}".`);
    process.exit(1);
  }

  await fs.writeFile(jsonPath, JSON.stringify(lanes, null, 2));

  console.log(`\nUpdated ${changed} lane(s) in applyRates.json`);
  console.log(`  Direction : ${sourceName} → ${destName}`);
  console.log(`  Capacity  : ${fmtCap(capacity)}`);
  console.log(`  Rate      : ${fmtRate(ratePerSec)}`);
  console.log(`\nRun 'ts-node applyRates.ts --submit' to push on-chain.\n`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
