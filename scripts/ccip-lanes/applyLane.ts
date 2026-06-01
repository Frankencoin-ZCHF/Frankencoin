import { config } from "dotenv";
config();

import { createPublicClient, createWalletClient, http, encodeAbiParameters } from "viem";
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

const POOL_ABI = [
  {
    name: "isSupportedChain",
    type: "function",
    stateMutability: "view",
    inputs:  [{ name: "remoteChainSelector", type: "uint64" }],
    outputs: [{ type: "bool" }],
  },
] as const;

const DISABLED_RATE = { isEnabled: false, capacity: 0n, rate: 0n };

const CCIP_ADMIN_ABI = [
  {
    name: "proposeAddChain",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "config",
        type: "tuple",
        components: [
          { name: "remoteChainSelector",      type: "uint64"  },
          { name: "remotePoolAddresses",       type: "bytes[]" },
          { name: "remoteTokenAddress",        type: "bytes"   },
          { name: "outboundRateLimiterConfig", type: "tuple",  components: [{ name: "isEnabled", type: "bool" }, { name: "capacity", type: "uint128" }, { name: "rate", type: "uint128" }] },
          { name: "inboundRateLimiterConfig",  type: "tuple",  components: [{ name: "isEnabled", type: "bool" }, { name: "capacity", type: "uint128" }, { name: "rate", type: "uint128" }] },
        ],
      },
      { name: "helpers", type: "address[]" },
    ],
    outputs: [],
  },
  {
    name: "proposeRemoveChain",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "chainId",  type: "uint64"    },
      { name: "helpers",  type: "address[]" },
    ],
    outputs: [],
  },
] as const;

// ─── Types ────────────────────────────────────────────────────────────────────

type LaneConfig = {
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
  const argv = process.argv.slice(2);
  const doSubmit = argv.includes("--submit");
  const filterSource = argv.find((a) => !a.startsWith("--") && argv.indexOf(a) === 0);
  const filterDest   = argv.find((a) => !a.startsWith("--") && argv.indexOf(a) === 1);

  const jsonPath = path.join(__dirname, "applyLane.json");
  let lanes: LaneConfig[];
  try {
    lanes = JSON.parse(await fs.readFile(jsonPath, "utf-8"));
  } catch {
    console.error(`Cannot read ${jsonPath}`);
    process.exit(1);
  }

  const filtered = lanes.filter((l) => {
    if (filterSource && l.chain.toLowerCase()  !== filterSource.toLowerCase()) return false;
    if (filterDest   && l.remote.toLowerCase() !== filterDest.toLowerCase())   return false;
    return true;
  });

  if (filtered.length === 0) {
    console.error("No matching lanes found.");
    process.exit(1);
  }

  // ─── Read on-chain state ───────────────────────────────────────────────────

  console.log("\nFetching on-chain state...");

  type DiffRow = {
    Chain: string;
    Remote: string;
    Desired: string;
    OnChain: string;
    Action: string;
    lane: LaneConfig;
    needsAdd: boolean;
    needsRemove: boolean;
  };

  const rows: DiffRow[] = [];

  for (const lane of filtered) {
    const viemChain = CHAIN_BY_ID[lane.chainId];
    if (!viemChain) {
      console.warn(`  ⚠ Unknown chain id ${lane.chainId}, skipping`);
      continue;
    }

    const client = createPublicClient({ chain: viemChain, transport: http(ALCHEMY_RPC[lane.chainId]) });
    const selector = BigInt(lane.remoteChainSelector);

    try {
      const isSupported = await client.readContract({
        address: lane.tokenPool as `0x${string}`,
        abi: POOL_ABI,
        functionName: "isSupportedChain",
        args: [selector],
      });

      const needsAdd    = lane.active && !isSupported;
      const needsRemove = !lane.active && isSupported;
      const action      = needsAdd ? "proposeAdd" : needsRemove ? "proposeRemove" : "—";

      rows.push({
        Chain:   lane.chain,
        Remote:  lane.remote,
        Desired: lane.active ? "active" : "inactive",
        OnChain: isSupported  ? "active" : "inactive",
        Action:  action,
        lane,
        needsAdd,
        needsRemove,
      });
    } catch {
      console.warn(`  ⚠ isSupportedChain failed: ${lane.chain} → ${lane.remote}`);
    }
  }

  // ─── Print diff ───────────────────────────────────────────────────────────

  console.log(`\nLane diff (${doSubmit ? "SUBMITTING proposals" : "dry run"})\n`);
  console.table(rows.map(({ Chain, Remote, Desired, OnChain, Action }) => ({ Chain, Remote, Desired, OnChain, Action })));

  const toAdd    = rows.filter((r) => r.needsAdd);
  const toRemove = rows.filter((r) => r.needsRemove);
  console.log(`${toAdd.length} to propose-add, ${toRemove.length} to propose-remove, out of ${rows.length} checked.\n`);

  if (!doSubmit) {
    console.log("Dry run — pass --submit to submit proposals on-chain.");
    console.log("Note: proposeAddChain / proposeRemoveChain have a 7-day delay before execution.\n");
    return;
  }

  if (toAdd.length === 0 && toRemove.length === 0) {
    console.log("Nothing to do.\n");
    return;
  }

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

  // ─── Propose add ──────────────────────────────────────────────────────────

  for (const { lane } of toAdd) {
    const viemChain  = CHAIN_BY_ID[lane.chainId]!;
    const wallet     = createWalletClient({ account, chain: viemChain, transport: http(ALCHEMY_RPC[lane.chainId]) });
    const selector   = BigInt(lane.remoteChainSelector);
    const encodedPool  = encodeAbiParameters([{ type: "address" }], [lane.remotePoolAddress  as `0x${string}`]);
    const encodedToken = encodeAbiParameters([{ type: "address" }], [lane.remoteTokenAddress as `0x${string}`]);

    process.stdout.write(`  proposeAddChain ${lane.chain} → ${lane.remote} ... `);
    try {
      const hash = await wallet.writeContract({
        address: lane.ccipAdmin as `0x${string}`,
        abi: CCIP_ADMIN_ABI,
        functionName: "proposeAddChain",
        args: [
          {
            remoteChainSelector:      selector,
            remotePoolAddresses:      [encodedPool],
            remoteTokenAddress:       encodedToken,
            outboundRateLimiterConfig: DISABLED_RATE,
            inboundRateLimiterConfig:  DISABLED_RATE,
          },
          helpers,
        ],
      });
      console.log(`✓ ${hash}`);
    } catch (err: any) {
      console.log(`✗ ${err?.shortMessage ?? err?.message ?? err}`);
    }
  }

  // ─── Propose remove ───────────────────────────────────────────────────────

  for (const { lane } of toRemove) {
    const viemChain = CHAIN_BY_ID[lane.chainId]!;
    const wallet    = createWalletClient({ account, chain: viemChain, transport: http(ALCHEMY_RPC[lane.chainId]) });
    const selector  = BigInt(lane.remoteChainSelector);

    process.stdout.write(`  proposeRemoveChain ${lane.chain} → ${lane.remote} ... `);
    try {
      const hash = await wallet.writeContract({
        address: lane.ccipAdmin as `0x${string}`,
        abi: CCIP_ADMIN_ABI,
        functionName: "proposeRemoveChain",
        args: [selector, helpers],
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
