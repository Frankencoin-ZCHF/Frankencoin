# Security Audit — module-registry proxy functions

**Date:** 2026-04-28
**Scope:**
- `contracts/registry/ModuleRegistry.sol` — `moduleProfit`, `moduleLoss`, `moduleTransfer`
- `contracts/registry/IModuleRegistry.sol` — corresponding interface additions
**Commit:** `77c4a99` + unstaged `moduleTransfer` signature change

---

## Summary

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High     | 0 |
| Medium   | 1 |
| Low      | 0 |
| Info     | 1 |

---

## Findings

### [M-01] Three proxy functions allow active modules to move ZCHF from arbitrary addresses without consent  *(Medium)*

**Location:** `contracts/registry/ModuleRegistry.sol:172–190`

**Description:**
Three proxy functions can debit an arbitrary address's ZCHF balance without that address's
explicit approval, using different routes through Frankencoin's minter-privilege system:

| Function | Mechanism | Destination |
|---|---|---|
| `moduleBurn(owner, amount)` *(pre-existing)* | `burnFrom` — minter-only, no allowance | burned |
| `moduleProfit(source, amount)` | `collectProfits` → `_transfer(source, reserve, …)` — minter-only, no allowance | Equity reserve |
| `moduleTransfer(source, target, amount)` | `transferFrom` — `_allowance()` returns `INFINITY` for minters | arbitrary target |

All three bypass the normal ERC20 allowance model. `moduleTransfer` leverages
`Frankencoin._allowance()` (line 122), which returns `INFINITY` whenever the spender is a
registered minter, so `transferFrom(source, target, amount)` succeeds for the registry on any
source address without prior `approve`.

The threat model relies on the 30-day FPS-governed veto window as the sole control:
*an active module is trusted to exercise these privileges correctly.* Within that model the
behaviour is intentional, but the surface area has now grown to three functions capable of
silently moving third-party balances, and none of them emit a registry-level event (see [I-01]).

**Recommendation:**
Accept as a known trust-model property and document it in the contract header NatSpec.
If defence-in-depth is desired, constrain the `source` argument to `msg.sender` on
`moduleProfit` and `moduleTransfer`, ensuring modules can only operate on their own balances:

```solidity
function moduleProfit(address source, uint256 amount) external onlyRegisteredModule {
    if (source != msg.sender) revert SourceMustBeCaller();
    zchf.collectProfits(source, amount);
}

function moduleTransfer(address source, address target, uint256 amount) external onlyRegisteredModule {
    if (source != msg.sender) revert SourceMustBeCaller();
    zchf.transferFrom(source, target, amount);
}
```

This would still allow modules to forward their own profits and move their own holdings while
preventing a compromised module from draining third-party holders.

---

### ~~[L-01] `NotActive` error NatSpec does not mention `moduleTransfer`~~  *(Resolved)*

Fixed: `IModuleRegistry.sol:105` updated to list all five proxy functions.

---

### [I-01] No registry-level events emitted by proxy functions  *(Info)*

**Location:** `contracts/registry/ModuleRegistry.sol:168–190`

**Description:**
None of the five proxy functions (`moduleMint`, `moduleBurn`, `moduleProfit`, `moduleLoss`,
`moduleTransfer`) emit a registry-level event. Auditability of *which module* triggered a
given financial operation relies entirely on the Frankencoin contract's own events
(`Mint`, `Profit`, etc.) and on reconstructing the call chain from transaction traces.

For operational monitoring — especially for detecting misbehaving modules quickly — this
gap means an alert system cannot be built on logs alone. The risk is heightened now that
`moduleTransfer` can move ZCHF between any two arbitrary addresses with no on-chain trace
at the registry layer.

**Recommendation:**
Emit a lightweight event from each proxy call, e.g.:

```solidity
event ModuleAction(address indexed module, bytes4 indexed selector, address source, address target, uint256 amount);
```

and emit it at the start of each proxy body. This adds one log per call, captures the
responsible module and both counterparty addresses, and enables off-chain monitors and
subgraphs to attribute every financial operation to a specific registered module without
trace decoding.

---

## Notes

- **`moduleLoss` minting risk is pre-existing.** `moduleLoss` proxies `coverLoss`, which can
  mint ZCHF if the reserve is depleted. This is the same capability `moduleMint` already
  provided; no new attack surface is introduced.
- **`moduleTransfer` redesign** — the original implementation used `zchf.transfer(target, amount)`,
  limiting it to the registry's own balance. It was updated to `zchf.transferFrom(source, target, amount)`,
  granting it the same arbitrary-source power as `moduleProfit` and `moduleBurn`. This change is
  intentional and expands the proxy's utility for modules that need to move ZCHF between positions.
- **Gas:** `moduleProfit` (~39k) and `moduleTransfer` (~41k) are cheaper than `moduleMint` (~59k)
  since they perform a single internal transfer. `moduleLoss` (~61k) is comparable to `moduleMint`
  since it may mint into the reserve first.
