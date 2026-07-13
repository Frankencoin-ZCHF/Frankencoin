import { config } from "dotenv";
config();

import { createPublicClient, http, decodeAbiParameters } from "viem";
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

const SELECTOR_TO_ENTRY = Object.fromEntries(
  Object.values(ADDRESS).map((a) => [a.chainSelector, a])
);

// ─── ABI ──────────────────────────────────────────────────────────────────────

const POOL_ABI = [
  {
    name: "getSupportedChains",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint64[]" }],
  },
  {
    name: "getRemotePools",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "remoteChainSelector", type: "uint64" }],
    outputs: [{ type: "bytes[]" }],
  },
  {
    name: "getRemoteToken",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "remoteChainSelector", type: "uint64" }],
    outputs: [{ type: "bytes" }],
  },
] as const;

// ─── Helpers ──────────────────────────────────────────────────────────────────

function decodeAddress(encoded: `0x${string}`): string {
  try {
    const [addr] = decodeAbiParameters([{ type: "address" }], encoded);
    return addr;
  } catch {
    return encoded;
  }
}

function chainName(chainId: number): string {
  return CHAIN_BY_ID[chainId]?.name ?? String(chainId);
}

// ─── Types ────────────────────────────────────────────────────────────────────

type LaneSnapshot = {
  chain: string;
  chainId: number;
  ccipAdmin: string;
  tokenPool: string;
  remote: string;
  remoteChainId: number | null;
  remoteChainSelector: string;
  remotePoolAddress: string;
  remoteTokenAddress: string;
  active: boolean;
};

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  const doExport = process.argv.includes("--export");

  const rows: Record<string, string>[] = [];
  const lanes: LaneSnapshot[] = [];

  for (const entry of Object.values(ADDRESS)) {
    const pool = entry.ccipTokenPool as `0x${string}` | undefined;
    if (!pool) continue;

    const chain = CHAIN_BY_ID[entry.chainId];
    if (!chain) continue;

    const client = createPublicClient({ chain, transport: http(ALCHEMY_RPC[entry.chainId]) });

    let selectors: readonly bigint[];
    try {
      selectors = await client.readContract({ address: pool, abi: POOL_ABI, functionName: "getSupportedChains" });
    } catch {
      console.warn(`  ⚠ getSupportedChains failed on ${chain.name}`);
      continue;
    }

    for (const selector of selectors) {
      const remoteEntry = SELECTOR_TO_ENTRY[selector.toString()];
      const remoteChainId = remoteEntry?.chainId ?? null;

      try {
        const [remotePools, remoteToken] = await Promise.all([
          client.readContract({ address: pool, abi: POOL_ABI, functionName: "getRemotePools", args: [selector] }),
          client.readContract({ address: pool, abi: POOL_ABI, functionName: "getRemoteToken",  args: [selector] }),
        ]);

        const remotePoolAddr  = remotePools.length > 0 ? decodeAddress(remotePools[0] as `0x${string}`) : "unknown";
        const remoteTokenAddr = decodeAddress(remoteToken as `0x${string}`);
        const remoteName      = remoteChainId ? chainName(remoteChainId) : selector.toString();

        rows.push({
          Chain:  chain.name,
          Remote: remoteName,
          "Remote Pool":  remotePoolAddr,
          "Remote Token": remoteTokenAddr,
        });

        lanes.push({
          chain:               chain.name,
          chainId:             entry.chainId,
          ccipAdmin:           (entry as any).ccipAdmin ?? "",
          tokenPool:           pool,
          remote:              remoteName,
          remoteChainId,
          remoteChainSelector: selector.toString(),
          remotePoolAddress:   remotePoolAddr,
          remoteTokenAddress:  remoteTokenAddr,
          active:              true,
        });
      } catch {
        console.warn(`  ⚠ read failed: ${chain.name} → ${remoteChainId ? chainName(remoteChainId) : selector}`);
      }
    }
  }

  lanes.sort((a, b) => a.chain.localeCompare(b.chain) || a.remote.localeCompare(b.remote));
  rows.sort((a, b) => a["Chain"].localeCompare(b["Chain"]) || a["Remote"].localeCompare(b["Remote"]));

  console.log("\nCCIP Active Lanes\n");
  console.table(rows);
  console.log(`${lanes.length} active lane(s) across all chains.\n`);

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
    const lanesDir = path.join(__dirname, "lanes");
    await fs.mkdir(lanesDir, { recursive: true });
    const outFile = path.join(lanesDir, `lanes-${stamp}.json`);
    await fs.writeFile(outFile, JSON.stringify(lanes, null, 2));
    console.log(`Snapshot saved → ${outFile}`);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
