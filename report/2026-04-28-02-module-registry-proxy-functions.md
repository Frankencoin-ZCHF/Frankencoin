# Security Audit — module-registry proxy functions

**Date:** 2026-04-28
**Scope:**
- `contracts/registry/ModuleRegistry.sol` — `moduleProfit`, `moduleLoss`, `moduleTransfer`
- `contracts/registry/IModuleRegistry.sol` — corresponding interface additions
**Commit:** `66a920b`

---

## Summary

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High     | 0 |
| Medium   | 1 |
| Low      | 1 |
| Info     | 1 |

---

## Findings

### [M-01] `moduleProfit` allows active modules to drain arbitrary user balances without consent  *(Medium)*

**Location:** `contracts/registry/ModuleRegistry.sol:183–185`

**Description:**
`moduleProfit(source, amount)` proxies to `zchf.collectProfits(source, amount)`, which calls
the internal `_transfer(source, reserve, amount)` inside Frankencoin — bypassing the ERC20
allowance mechanism entirely. Any currently active module can call
`moduleProfit(victimAddress, victimBalance)` to silently sweep an arbitrary user's entire ZCHF
balance into the Equity reserve without the victim's approval or knowledge.

This is structurally identical to the pre-existing `moduleBurn`, which can equally drain any
address's balance (burning rather than forwarding to the reserve). Both rely on the system-level
trust axiom: *an active module is fully trusted because it passed a 30-day FPS-governed veto
window.* Within that model the behaviour is intentional, but the surface area has now grown
from one such function to two.

The concern is compounded by the lack of any registry-level event (see [I-01]), which means
an off-chain monitor cannot distinguish a legitimate module operating on its own accounting
from a compromised module draining third-party holders.

**Recommendation:**
Accept as a known trust-model property and document it explicitly in the contract header
NatSpec ("active modules may transfer ZCHF from any address via minter-privilege functions
without on-chain consent"). If stricter isolation is desired, constrain `moduleProfit` so that
`source` must equal `msg.sender` (the calling module itself), preventing it from being used
against third-party holders. This is safe because a module that wants to collect profits from
its own positions should be the one holding those funds anyway.

```solidity
// Stricter variant — source must be the calling module
function moduleProfit(address source, uint256 amount) external onlyRegisteredModule {
    require(source == msg.sender, "source must be caller");
    zchf.collectProfits(source, amount);
}
```

---

### [L-01] `NotActive` error NatSpec does not mention `moduleTransfer`  *(Low)*

**Location:** `contracts/registry/IModuleRegistry.sol:105`

**Description:**
The `NotActive` error is documented as:
> "Thrown by moduleMint(), moduleBurn(), moduleProfit(), or moduleLoss() when the caller is not an active module."

`moduleTransfer` also reverts `NotActive` via `onlyRegisteredModule` but is absent from this
list, making the documentation incomplete for integrators.

**Recommendation:**
Add `moduleTransfer()` to the error's NatSpec:
```solidity
/// @notice Thrown by moduleMint(), moduleBurn(), moduleProfit(), moduleLoss(), or moduleTransfer() when the caller is not an active module.
error NotActive();
```

---

### [I-01] No registry-level events emitted by proxy functions  *(Info)*

**Location:** `contracts/registry/ModuleRegistry.sol:168–190`

**Description:**
None of the five proxy functions (`moduleMint`, `moduleBurn`, `moduleProfit`, `moduleLoss`,
`moduleTransfer`) emit a registry-level event. Auditability of *which module* triggered a
given financial operation relies entirely on the Frankencoin contract's own events
(`Mint`, `Profit`, etc.) and on reconstructing the call chain from transaction traces.

For operational monitoring — especially for detecting misbehaving modules quickly — this
gap means an alert system cannot be built on logs alone.

**Recommendation:**
Emit a lightweight event from each proxy call, e.g.:

```solidity
event ModuleAction(address indexed module, bytes4 indexed selector, address target, uint256 amount);
```

and emit it at the start of each proxy body. This adds one log per call, captures the
responsible module, and enables off-chain monitors and subgraphs to attribute every
financial operation to a specific registered module without trace decoding.

---

## Notes

- **`moduleLoss` minting risk is pre-existing.** `moduleLoss` proxies `coverLoss`, which can
  mint ZCHF if the reserve is depleted. This is the same capability `moduleMint` already
  provided; no new attack surface is introduced.
- **`moduleTransfer` is limited to the registry's own balance** — it cannot access any other
  address's funds. The registry's ZCHF balance consists only of transiently escrowed proposal
  fees (which are always cleared by `accept`/`revoke`). No stranded-balance risk in normal
  operation.
- **Gas:** `moduleProfit` (~39k gas) is cheaper than `moduleMint` (~59k) since `collectProfits`
  performs a single internal transfer rather than minting. `moduleLoss` (~61k) is comparable
  to `moduleMint` since it may need to mint into the reserve first.
