# CCIP Lane Scripts

Three scripts for managing which remote chains are supported by each CCIP token pool.

## Workflow

```
showLanes  ──────────────────────────────────────────→  read on-chain
applyLane.json  →  applyLane (propose)  →  7-day delay  →  applyAddChain / applyRemoveChain
```

> **Note:** Adding or removing a lane goes through a 7-day governance delay.
> `applyLane.ts` submits the proposal. Execution is done via the scripts in `scripts/ccip/`.

---

## `showLanes.ts` — Read on-chain state

Fetches active lanes from all token pools and displays them.

```bash
npx ts-node showLanes.ts

# Save a timestamped snapshot to lanes/
npx ts-node showLanes.ts --export
```

---

## `applyLane.json` — Desired lane config

Contains all 56 chain pairs (8 chains × 7 remotes). Set `active: true` to enable a lane, `false` to disable.

Each entry:

| Field                 | Description                                |
|-----------------------|--------------------------------------------|
| `chain`               | Source chain name                          |
| `chainId`             | Source chain ID                            |
| `ccipAdmin`           | CCIPAdmin contract on the source chain     |
| `tokenPool`           | Token pool on the source chain             |
| `remote`              | Remote chain name                          |
| `remoteChainSelector` | Remote chain CCIP selector                 |
| `remotePoolAddress`   | Token pool address on the remote chain     |
| `remoteTokenAddress`  | ZCHF token address on the remote chain     |
| `active`              | `true` = lane should exist, `false` = not  |

---

## `applyLane.ts` — Submit proposals

Reads `applyLane.json`, checks on-chain state, and submits `proposeAddChain` or `proposeRemoveChain` for any lanes that differ.

```bash
# Dry run — show diff only
npx ts-node applyLane.ts

# Filter by source chain
npx ts-node applyLane.ts Ethereum

# Filter by source and destination
npx ts-node applyLane.ts Ethereum Base

# Submit proposals on-chain
npx ts-node applyLane.ts --submit
npx ts-node applyLane.ts Ethereum --submit
```

Requires `PRIVATE_KEY` in `.env`. The caller must be a qualified governance voter.
Optionally `HELPERS` (comma-separated addresses) for governance qualification.

After 7 days, execute proposals using the existing scripts:

```bash
npx ts-node ../ccip/applyAddChain.ts    <chain> <ccipAdmin> <remote>
npx ts-node ../ccip/applyRemoveChain.ts <chain> <ccipAdmin> <remote>
```
