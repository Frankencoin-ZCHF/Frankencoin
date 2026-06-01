import { config } from "dotenv";
config();

import { createPublicClient, http, formatUnits } from "viem";
import fs from "fs/promises";
import path from "path";
import { arbitrum, avalanche, base, gnosis, mainnet, optimism, polygon, sonic } from "viem/chains";
import { ADDRESS } from "../../exports/address.config";

// ─── Chain registry ───────────────────────────────────────────────────────────

const CHAINS = [mainnet, polygon, arbitrum, optimism, base, avalanche, gnosis, sonic];

const CHAIN_BY_ID = Object.fromEntries(CHAINS.map((c) => [c.id, c]));

const key = process.env.ALCHEMY_RPC_KEY ?? "";

const ALCHEMY_RPC: Record<number, string> = {
  [mainnet.id]:   `https://eth-mainnet.g.alchemy.com/v2/${key}`,
  [polygon.id]:   `https://polygon-mainnet.g.alchemy.com/v2/${key}`,
  [arbitrum.id]:  `https://arb-mainnet.g.alchemy.com/v2/${key}`,
  [optimism.id]:  `https://opt-mainnet.g.alchemy.com/v2/${key}`,
  [base.id]:      `https://base-mainnet.g.alchemy.com/v2/${key}`,
  [avalanche.id]: `https://avax-mainnet.g.alchemy.com/v2/${key}`,
  [gnosis.id]:    `https://gnosis-mainnet.g.alchemy.com/v2/${key}`,
  [sonic.id]:     `https://sonic-mainnet.g.alchemy.com/v2/${key}`,
};

// Build selector → chainId map from address config
const SELECTOR_TO_CHAIN_ID = Object.fromEntries(
  Object.values(ADDRESS).map((a) => [a.chainSelector, a.chainId])
);

// ─── ABI ──────────────────────────────────────────────────────────────────────

const POOL_ABI = [
  {
    name: "getSupportedChains",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint64[]" }],
  },
  {
    name: "getCurrentInboundRateLimiterState",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "remoteChainSelector", type: "uint64" }],
    outputs: [
      {
        type: "tuple",
        components: [
          { name: "tokens", type: "uint128" },
          { name: "lastUpdated", type: "uint32" },
          { name: "isEnabled", type: "bool" },
          { name: "capacity", type: "uint128" },
          { name: "rate", type: "uint128" },
        ],
      },
    ],
  },
  {
    name: "getCurrentOutboundRateLimiterState",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "remoteChainSelector", type: "uint64" }],
    outputs: [
      {
        type: "tuple",
        components: [
          { name: "tokens", type: "uint128" },
          { name: "lastUpdated", type: "uint32" },
          { name: "isEnabled", type: "bool" },
          { name: "capacity", type: "uint128" },
          { name: "rate", type: "uint128" },
        ],
      },
    ],
  },
] as const;

// ─── Helpers ──────────────────────────────────────────────────────────────────

function fmtLimit(isEnabled: boolean, capacity: bigint, rate: bigint): string {
  if (!isEnabled) return "bypassed";
  const cap = Number(formatUnits(capacity, 18)).toLocaleString("en-US", { maximumFractionDigits: 0 });
  const rph = Number(formatUnits(rate * 3600n, 18)).toLocaleString("en-US", { maximumFractionDigits: 0 });
  return `${cap} ZCHF cap / ${rph} per h`;
}

function chainName(chainId: number): string {
  return CHAIN_BY_ID[chainId]?.name ?? String(chainId);
}

// ─── Main ─────────────────────────────────────────────────────────────────────

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

async function main() {
  const doExport = process.argv.includes("--export") || process.argv.includes("true");

  const rows: Record<string, string>[] = [];
  const lanes: LaneConfig[] = [];

  for (const entry of Object.values(ADDRESS)) {
    const pool = entry.ccipTokenPool as `0x${string}` | undefined;
    if (!pool) continue;

    const chain = CHAIN_BY_ID[entry.chainId];
    if (!chain) continue;

    const client = createPublicClient({ chain, transport: http(ALCHEMY_RPC[entry.chainId]) });

    let selectors: readonly bigint[];
    try {
      selectors = await client.readContract({
        address: pool,
        abi: POOL_ABI,
        functionName: "getSupportedChains",
      });
    } catch {
      console.warn(`  ⚠ getSupportedChains failed on ${chain.name}`);
      continue;
    }

    for (const selector of selectors) {
      const destChainId = SELECTOR_TO_CHAIN_ID[selector.toString()];

      try {
        const [inState, outState] = await Promise.all([
          client.readContract({
            address: pool,
            abi: POOL_ABI,
            functionName: "getCurrentInboundRateLimiterState",
            args: [selector],
          }),
          client.readContract({
            address: pool,
            abi: POOL_ABI,
            functionName: "getCurrentOutboundRateLimiterState",
            args: [selector],
          }),
        ]);

        const destName = destChainId ? chainName(destChainId) : selector.toString();

        rows.push({
          Source: chainName(entry.chainId),
          Destination: destName,
          Outgoing: fmtLimit(outState.isEnabled, outState.capacity, outState.rate),
          Incoming: fmtLimit(inState.isEnabled, inState.capacity, inState.rate),
        });

        lanes.push({
          source: chainName(entry.chainId),
          sourceChainId: entry.chainId,
          ccipAdmin: (entry as any).ccipAdmin ?? "",
          destination: destName,
          destinationChainId: destChainId ?? null,
          destinationSelector: selector.toString(),
          incoming: {
            isEnabled: inState.isEnabled,
            capacity: inState.capacity.toString(),
            rate: inState.rate.toString(),
          },
          outgoing: {
            isEnabled: outState.isEnabled,
            capacity: outState.capacity.toString(),
            rate: outState.rate.toString(),
          },
        });
      } catch {
        console.warn(`  ⚠ rate limit read failed on ${chain.name} → ${destChainId ? chainName(destChainId) : selector}`);
      }
    }
  }

  // Sort by source chain name, then destination
  rows.sort((a, b) => a["Source"].localeCompare(b["Source"]) || a["Destination"].localeCompare(b["Destination"]));

  lanes.sort((a, b) => a.source.localeCompare(b.source) || a.destination.localeCompare(b.destination));
  rows.sort((a, b) => a["Source"].localeCompare(b["Source"]) || a["Destination"].localeCompare(b["Destination"]));

  console.log("\nCCIP Rate Limit Configuration\n");
  console.table(rows);

  if (doExport) {
    const now = new Date();
    const stamp = [
      now.getFullYear(),
      String(now.getMonth() + 1).padStart(2, "0"),
      String(now.getDate()).padStart(2, "0"),
      String(now.getHours()).padStart(2, "0"),
      String(now.getMinutes()).padStart(2, "0"),
      String(now.getSeconds()).padStart(2, "0"),
    ].join("-");
    const ratesDir = path.join(__dirname, "rates");
    await fs.mkdir(ratesDir, { recursive: true });
    const outFile = path.join(ratesDir, `rates-${stamp}.json`);
    await fs.writeFile(outFile, JSON.stringify(lanes, null, 2));
    console.log(`\nSnapshot saved → ${outFile}`);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
