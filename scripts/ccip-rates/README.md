# CCIP Rate Limit Scripts

Three scripts for managing CCIP token pool rate limits across all supported chains.

## Workflow

```
setRate → applyRates.json → applyRates → on-chain
showRates                              → read on-chain
```

---

## `setRate.ts` — Update config file

Sets the rate limit config for one or more lanes in `applyRates.json`.

```bash
npx ts-node setRate.ts <source> <destination> <limit> <rate>
```

| Arg           | Description                               |
|---------------|-------------------------------------------|
| `source`      | Chain tokens flow **from**, or `all`      |
| `destination` | Chain tokens flow **to**, or `all`        |
| `limit`       | Bucket capacity in ZCHF (e.g. `500000`)  |
| `rate`        | Refill rate in ZCHF/hour (e.g. `10000`)  |

Chain names: `Ethereum`, `Base`, `Arbitrum One`, `OP Mainnet`, `Polygon`, `Avalanche`, `Gnosis`, `Sonic`

The args define a **directional flow**. `Ethereum Base` configures the Ethereum→Base direction:
- Lane `source=Ethereum, dest=Base` → sets `outgoing`
- Lane `source=Base, dest=Ethereum` → sets `incoming`

```bash
# Ethereum → Base direction only
npx ts-node setRate.ts Ethereum Base 500000 10000

# All outflows from Ethereum (Ethereum → every other chain)
npx ts-node setRate.ts Ethereum all 500000 10000

# All inflows to Ethereum (every chain → Ethereum)
npx ts-node setRate.ts all Ethereum 500000 10000

# All directions on every lane
npx ts-node setRate.ts all all 500000 10000
```

---

## `applyRates.ts` — Push config on-chain

Reads `applyRates.json`, compares against on-chain state, and submits transactions for lanes that differ.

```bash
# Dry run — show diff only
npx ts-node applyRates.ts

# Apply all changes
npx ts-node applyRates.ts --submit

# Filter by chain
npx ts-node applyRates.ts Ethereum
npx ts-node applyRates.ts Ethereum Base
```

Requires `PRIVATE_KEY` in `.env`. Optionally `HELPERS` (comma-separated addresses).

---

## `showRates.ts` — Read on-chain state

Fetches and prints the current rate limits from all pools.

```bash
npx ts-node showRates.ts

# Export snapshot to rates/
npx ts-node showRates.ts --export
```
