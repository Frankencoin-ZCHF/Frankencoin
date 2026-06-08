# CCIP Lane Scripts

Four scripts for managing which remote chains are supported by each CCIP token pool.

## Setup

All scripts must be run from this directory, or extend the command with the correct path to the files:

```bash
cd scripts/ccip-lanes
```

---

## Workflow

```
showLanes   ──────────────────────────────────────────→  read on-chain
applyLanes.json  →  applyLanes (propose)  →  7-day delay  →  enactLanes (execute)
```

> **Note:** Adding or removing a lane goes through a 7-day governance delay.
> `applyLanes.ts` submits the proposal. `enactLanes.ts` executes it once the delay has passed.

---

## `showLanes.ts` — Read on-chain state

Fetches active lanes from all token pools and displays them.

```bash
npx ts-node showLanes.ts

# Save a timestamped snapshot to lanes/
npx ts-node showLanes.ts --export
```

---

## `applyLanes.json` — Desired lane config

Contains all 56 chain pairs (8 chains × 7 remotes). Set `active: true` to enable a lane, `false` to disable.

Each entry:

| Field                 | Description                               |
| --------------------- | ----------------------------------------- |
| `chain`               | Source chain name                         |
| `chainId`             | Source chain ID                           |
| `ccipAdmin`           | CCIPAdmin contract on the source chain    |
| `tokenPool`           | Token pool on the source chain            |
| `remote`              | Remote chain name                         |
| `remoteChainSelector` | Remote chain CCIP selector                |
| `remotePoolAddress`   | Token pool address on the remote chain    |
| `remoteTokenAddress`  | ZCHF token address on the remote chain    |
| `active`              | `true` = lane should exist, `false` = not |

---

## `applyLanes.ts` — Submit proposals

Reads `applyLanes.json`, checks on-chain state, and submits `proposeAddChain` or `proposeRemoveChain` for any lanes that differ.

```bash
# Dry run — show diff only
npx ts-node applyLanes.ts

# Filter by source chain
npx ts-node applyLanes.ts Ethereum

# Filter by source and destination
npx ts-node applyLanes.ts Ethereum Base

# Submit proposals on-chain
npx ts-node applyLanes.ts --submit
npx ts-node applyLanes.ts Ethereum --submit
```

Requires `PRIVATE_KEY` in `.env`. The caller must be a qualified governance voter.
Optionally `HELPERS` (comma-separated addresses) for governance qualification.

---

## `enactLanes.ts` — Execute proposals

Fetches pending proposals from the Frankencoin API and executes any that have passed the 7-day delay by calling `applyAddChain` or `applyRemoveChain` on the appropriate CCIPAdmin contract.

```bash
# Dry run — show all pending proposals
npx ts-node enactLanes.ts

# Filter to one source chain (dry run)
npx ts-node enactLanes.ts Ethereum

# Enact all ready proposals
npx ts-node enactLanes.ts --submit

# Enact only Ethereum proposals
npx ts-node enactLanes.ts Ethereum --submit
```

The table shows each proposal's `Ready` status (✓/✗) and `ETA` (time remaining in the delay). Proposals still inside the delay window are displayed but skipped even with `--submit`.

Requires `PRIVATE_KEY` in `.env`.
