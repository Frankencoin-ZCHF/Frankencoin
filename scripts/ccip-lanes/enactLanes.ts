import { config } from "dotenv";
config();

import { createWalletClient, http, encodeAbiParameters } from "viem";
import { privateKeyToAccount } from "viem/accounts";
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

// Selector → ADDRESS entry (for resolving remote chain names)
const SELECTOR_TO_ENTRY = Object.fromEntries(
  Object.values(ADDRESS).map((a) => [a.chainSelector, a])
);

// ChainId → ccipAdmin (derived from ADDRESS config)
const CHAIN_ID_TO_CCIP_ADMIN = Object.fromEntries(
  Object.values(ADDRESS)
    .filter((a) => (a as any).ccipAdmin)
    .map((a) => [a.chainId, (a as any).ccipAdmin as string])
);

// ─── ABIs ─────────────────────────────────────────────────────────────────────

const DISABLED_RATE = { isEnabled: false, capacity: 0n, rate: 0n };

const CCIP_ADMIN_ABI = [
  {
    name: "applyAddChain",
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
    ],
    outputs: [],
  },
  {
    name: "applyRemoveChain",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [{ name: "chainId", type: "uint64" }],
    outputs: [],
  },
] as const;

// ─── API types ────────────────────────────────────────────────────────────────

type ApiProposal = {
  chainId: number;
  hash: string;
  type: "AddChain" | "RemoveChain";
  deadline: number;
  status: string;
  details: string; // JSON: { chain: string (selector), pool?: string, token?: string }
};

type ApiResponse = { list: ApiProposal[] };

// ─── Main ─────────────────────────────────────────────────────────────────────

const API_URL = "https://api.frankencoin.com/bridge/proposals/pending";

async function main() {
  const argv        = process.argv.slice(2);
  const doSubmit    = argv.includes("--submit");
  const filterChain = argv.find((a) => !a.startsWith("--"));

  // ─── Fetch ────────────────────────────────────────────────────────────────

  console.log(`\nFetching pending proposals from ${API_URL} ...`);
  let raw: ApiProposal[];
  try {
    const res = await fetch(API_URL);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const body = (await res.json()) as ApiResponse;
    raw = body.list ?? [];
  } catch (err: any) {
    console.error(`Failed to fetch proposals: ${err?.message ?? err}`);
    process.exit(1);
  }

  // ─── Resolve names ────────────────────────────────────────────────────────

  type Row = {
    chain: string;
    chainId: number;
    ccipAdmin: string;
    remote: string;
    remoteChainSelector: string;
    remotePoolAddress: string;
    remoteTokenAddress: string;
    action: "AddChain" | "RemoveChain";
    deadline: number;
  };

  const rows: Row[] = [];

  for (const p of raw) {
    const viemChain = CHAIN_BY_ID[p.chainId];
    if (!viemChain) {
      console.warn(`  ⚠ Unknown chainId ${p.chainId}, skipping`);
      continue;
    }

    const ccipAdmin = CHAIN_ID_TO_CCIP_ADMIN[p.chainId];
    if (!ccipAdmin) {
      console.warn(`  ⚠ No ccipAdmin for chainId ${p.chainId}, skipping`);
      continue;
    }

    let details: { chain: string; pool?: string; token?: string };
    try {
      details = JSON.parse(p.details);
    } catch {
      console.warn(`  ⚠ Invalid details JSON for proposal ${p.hash}, skipping`);
      continue;
    }

    const remoteSelector = details.chain;
    const remoteEntry    = SELECTOR_TO_ENTRY[remoteSelector];
    const remoteName     = remoteEntry
      ? (CHAIN_BY_ID[remoteEntry.chainId]?.name ?? String(remoteEntry.chainId))
      : remoteSelector;

    if (filterChain && viemChain.name.toLowerCase() !== filterChain.toLowerCase()) continue;

    rows.push({
      chain:               viemChain.name,
      chainId:             p.chainId,
      ccipAdmin,
      remote:              remoteName,
      remoteChainSelector: remoteSelector,
      remotePoolAddress:   details.pool  ?? "",
      remoteTokenAddress:  details.token ?? "",
      action:              p.type,
      deadline:            p.deadline,
    });
  }

  if (rows.length === 0) {
    console.log(`No pending proposals${filterChain ? ` for chain "${filterChain}"` : ""}.\n`);
    return;
  }

  // ─── Print table ──────────────────────────────────────────────────────────

  const now = Math.floor(Date.now() / 1000);

  console.log(`\nPending lane proposals (${doSubmit ? "ENACTING" : "dry run"})\n`);
  console.table(
    rows.map((r) => {
      const secsLeft = r.deadline - now;
      const isReady  = secsLeft <= 0;
      const eta      = isReady
        ? "ready"
        : secsLeft < 3600
          ? `${Math.ceil(secsLeft / 60)}m`
          : `${Math.ceil(secsLeft / 3600)}h`;
      return {
        Chain:  r.chain,
        Remote: r.remote,
        Action: r.action,
        Ready:  isReady ? "✓" : "✗",
        ETA:    eta,
      };
    })
  );

  const ready   = rows.filter((r) => r.deadline - now <= 0);
  const waiting = rows.filter((r) => r.deadline - now > 0);
  console.log(`${ready.length} ready to enact, ${waiting.length} still in delay, ${rows.length} total.\n`);

  if (!doSubmit) {
    console.log("Dry run — pass --submit to enact ready proposals on-chain.\n");
    return;
  }

  if (ready.length === 0) {
    console.log("No proposals are ready to enact yet.\n");
    return;
  }

  // ─── Wallet ────────────────────────────────────────────────────────────────

  const privateKey = process.env.PRIVATE_KEY as `0x${string}` | undefined;
  if (!privateKey) {
    console.error("Missing PRIVATE_KEY in .env");
    process.exit(1);
  }
  const account = privateKeyToAccount(privateKey);

  // ─── Enact ─────────────────────────────────────────────────────────────────

  for (const row of ready) {
    const viemChain = CHAIN_BY_ID[row.chainId]!;
    const wallet    = createWalletClient({ account, chain: viemChain, transport: http(ALCHEMY_RPC[row.chainId]) });
    const selector  = BigInt(row.remoteChainSelector);

    if (row.action === "AddChain") {
      const encodedPool  = encodeAbiParameters([{ type: "address" }], [row.remotePoolAddress  as `0x${string}`]);
      const encodedToken = encodeAbiParameters([{ type: "address" }], [row.remoteTokenAddress as `0x${string}`]);

      process.stdout.write(`  applyAddChain ${row.chain} → ${row.remote} ... `);
      try {
        const hash = await wallet.writeContract({
          address: row.ccipAdmin as `0x${string}`,
          abi: CCIP_ADMIN_ABI,
          functionName: "applyAddChain",
          args: [{
            remoteChainSelector:      selector,
            remotePoolAddresses:      [encodedPool],
            remoteTokenAddress:       encodedToken,
            outboundRateLimiterConfig: DISABLED_RATE,
            inboundRateLimiterConfig:  DISABLED_RATE,
          }],
        });
        console.log(`✓ ${hash}`);
      } catch (err: any) {
        console.log(`✗ ${err?.shortMessage ?? err?.message ?? err}`);
      }

    } else {
      process.stdout.write(`  applyRemoveChain ${row.chain} → ${row.remote} ... `);
      try {
        const hash = await wallet.writeContract({
          address: row.ccipAdmin as `0x${string}`,
          abi: CCIP_ADMIN_ABI,
          functionName: "applyRemoveChain",
          args: [selector],
        });
        console.log(`✓ ${hash}`);
      } catch (err: any) {
        console.log(`✗ ${err?.shortMessage ?? err?.message ?? err}`);
      }
    }
  }

  console.log("");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
