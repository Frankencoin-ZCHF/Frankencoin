import { config } from "dotenv";
config();

import { createPublicClient, createWalletClient, http, formatUnits } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arbitrum, avalanche, base, gnosis, mainnet, optimism, polygon, sonic } from "viem/chains";
import fs from "fs/promises";
import path from "path";

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

// ─── ABIs ─────────────────────────────────────────────────────────────────────

const RATE_LIMITER_TUPLE = {
  type: "tuple",
  components: [
    { name: "tokens",      type: "uint128" },
    { name: "lastUpdated", type: "uint32"  },
    { name: "isEnabled",   type: "bool"    },
    { name: "capacity",    type: "uint128" },
    { name: "rate",        type: "uint128" },
  ],
} as const;

const POOL_ABI = [
  {
    name: "getCurrentInboundRateLimiterState",
    type: "function",
    stateMutability: "view",
    inputs:  [{ name: "remoteChainSelector", type: "uint64" }],
    outputs: [RATE_LIMITER_TUPLE],
  },
  {
    name: "getCurrentOutboundRateLimiterState",
    type: "function",
    stateMutability: "view",
    inputs:  [{ name: "remoteChainSelector", type: "uint64" }],
    outputs: [RATE_LIMITER_TUPLE],
  },
] as const;

const CCIP_ADMIN_ABI = [
  {
    name: "applyRateLimit",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "chain", type: "uint64" },
      { name: "inbound",  type: "tuple", components: [{ name: "isEnabled", type: "bool" }, { name: "capacity", type: "uint128" }, { name: "rate", type: "uint128" }] },
      { name: "outbound", type: "tuple", components: [{ name: "isEnabled", type: "bool" }, { name: "capacity", type: "uint128" }, { name: "rate", type: "uint128" }] },
      { name: "helpers", type: "address[]" },
    ],
    outputs: [],
  },
] as const;

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

function fmtConfig(c: RateConfig): string {
  if (!c.isEnabled) return "bypassed";
  const cap = Number(formatUnits(BigInt(c.capacity), 18)).toLocaleString("en-US", { maximumFractionDigits: 0 });
  const rph = Number(formatUnits(BigInt(c.rate) * 3600n, 18)).toLocaleString("en-US", { maximumFractionDigits: 0 });
  return `${cap} | ${rph}ph`;
}

function configsMatch(desired: RateConfig, actual: { isEnabled: boolean; capacity: bigint; rate: bigint }): boolean {
  return (
    desired.isEnabled === actual.isEnabled &&
    BigInt(desired.capacity) === actual.capacity &&
    BigInt(desired.rate) === actual.rate
  );
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  const args = process.argv.slice(2).filter((a) => !a.startsWith("--"));
  const doSubmit = process.argv.includes("--submit") || process.argv.includes("true");

  const sourceArg = args[0]; // optional — undefined = all
  const destArg   = args[1]; // optional

  // Load applyRates.json
  const inputFile = path.join(__dirname, "applyRates.json");
  let lanes: LaneConfig[];
  try {
    lanes = JSON.parse(await fs.readFile(inputFile, "utf-8"));
  } catch {
    console.error(`Cannot read ${inputFile}`);
    process.exit(1);
  }

  // Filter by source / destination args
  const filtered = lanes.filter((l) => {
    if (sourceArg && l.source.toLowerCase() !== sourceArg.toLowerCase()) return false;
    if (destArg   && l.destination.toLowerCase() !== destArg.toLowerCase()) return false;
    return true;
  });

  if (filtered.length === 0) {
    console.error(`No lanes found${sourceArg ? ` for source="${sourceArg}"` : ""}${destArg ? ` destination="${destArg}"` : ""}.`);
    console.error("Available sources:", [...new Set(lanes.map((l) => l.source))].join(", "));
    process.exit(1);
  }

  // Fetch current on-chain state for each lane
  console.log("\nFetching on-chain state...");

  type DiffRow = {
    Source: string;
    Destination: string;
    "Outgoing (desired)": string;
    "Incoming (desired)": string;
    Match: string;
    lane: LaneConfig;
    needsUpdate: boolean;
  };

  const rows: DiffRow[] = [];

  for (const lane of filtered) {
    const viemChain = CHAIN_BY_ID[lane.sourceChainId];
    if (!viemChain) {
      console.warn(`  ⚠ Unknown chain id ${lane.sourceChainId}, skipping`);
      continue;
    }

    const TOKEN_POOLS: Record<number, string> = {
      1:     "0x9359cd75549DaE00Cdd8D22297BC9B13FbBe4B79",
      10:    "0x7CBac118B3F299f8BE1C3DBA66368D96B37D7743",
      100:   "0x7CBac118B3F299f8BE1C3DBA66368D96B37D7743",
      137:   "0x7CBac118B3F299f8BE1C3DBA66368D96B37D7743",
      146:   "0x7CBac118B3F299f8BE1C3DBA66368D96B37D7743",
      8453:  "0x7CBac118B3F299f8BE1C3DBA66368D96B37D7743",
      42161: "0x7CBac118B3F299f8BE1C3DBA66368D96B37D7743",
      43114: "0x7CBac118B3F299f8BE1C3DBA66368D96B37D7743",
    };

    const tokenPool = TOKEN_POOLS[lane.sourceChainId] as `0x${string}` | undefined;
    if (!tokenPool) {
      console.warn(`  ⚠ No token pool for chain ${lane.sourceChainId}, skipping`);
      continue;
    }

    const client = createPublicClient({ chain: viemChain, transport: http(ALCHEMY_RPC[lane.sourceChainId]) });
    const selector = BigInt(lane.destinationSelector);

    try {
      const [inState, outState] = await Promise.all([
        client.readContract({ address: tokenPool, abi: POOL_ABI, functionName: "getCurrentInboundRateLimiterState",  args: [selector] }),
        client.readContract({ address: tokenPool, abi: POOL_ABI, functionName: "getCurrentOutboundRateLimiterState", args: [selector] }),
      ]);

      const inMatch  = configsMatch(lane.incoming, inState  as any);
      const outMatch = configsMatch(lane.outgoing, outState as any);
      const needsUpdate = !inMatch || !outMatch;

      rows.push({
        Source: lane.source,
        Destination: lane.destination,
        "Outgoing (desired)": fmtConfig(lane.outgoing),
        "Incoming (desired)": fmtConfig(lane.incoming),
        Match: needsUpdate ? "✗" : "✓",
        lane,
        needsUpdate,
      });
    } catch {
      console.warn(`  ⚠ Read failed: ${lane.source} → ${lane.destination}`);
    }
  }

  // Print diff table
  console.log(`\nRate limit diff (${doSubmit ? "SUBMITTING changes" : "dry run"})\n`);
  console.table(
    rows.map(({ Source, Destination, "Outgoing (desired)": out, "Incoming (desired)": inc, Match }) => ({
      Source,
      Destination,
      "Outgoing (desired)": out,
      "Incoming (desired)": inc,
      Match,
    }))
  );

  const toUpdate = rows.filter((r) => r.needsUpdate);
  console.log(`${toUpdate.length} of ${rows.length} lanes need updating.\n`);

  if (!doSubmit) {
    console.log("Dry run — pass --submit to apply changes on-chain.\n");
    return;
  }

  if (toUpdate.length === 0) {
    console.log("Nothing to do.\n");
    return;
  }

  // Wallet
  const privateKey = process.env.PRIVATE_KEY as `0x${string}` | undefined;
  if (!privateKey) {
    console.error("Missing PRIVATE_KEY in .env");
    process.exit(1);
  }
  const account = privateKeyToAccount(privateKey);

  const helpers = (process.env.HELPERS ?? "")
    .split(",")
    .map((h) => h.trim())
    .filter(Boolean) as `0x${string}`[];

  for (const { lane } of toUpdate) {
    const viemChain = CHAIN_BY_ID[lane.sourceChainId]!;
    const walletClient = createWalletClient({
      account,
      chain: viemChain,
      transport: http(ALCHEMY_RPC[lane.sourceChainId]),
    });

    // CCIPAdmin.applyRateLimit is from the remote chain's perspective:
    // CCIPAdmin.inbound = our outgoing, CCIPAdmin.outbound = our incoming.
    const inboundArg  = { isEnabled: lane.outgoing.isEnabled, capacity: BigInt(lane.outgoing.capacity), rate: BigInt(lane.outgoing.rate) };
    const outboundArg = { isEnabled: lane.incoming.isEnabled, capacity: BigInt(lane.incoming.capacity), rate: BigInt(lane.incoming.rate) };

    process.stdout.write(`Submitting ${lane.source} → ${lane.destination} ... `);
    try {
      const hash = await walletClient.writeContract({
        address: lane.ccipAdmin as `0x${string}`,
        abi: CCIP_ADMIN_ABI,
        functionName: "applyRateLimit",
        args: [BigInt(lane.destinationSelector), inboundArg, outboundArg, helpers],
      });
      console.log(`✓ ${hash}`);
    } catch (err: any) {
      console.log(`✗ ${err?.shortMessage ?? err?.message ?? err}`);
    }
  }

  console.log("");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
