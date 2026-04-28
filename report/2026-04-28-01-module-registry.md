# Security Audit — module-registry

**Date:** 2026-04-28
**Scope:** `contracts/registry/ModuleRegistry.sol`, `contracts/registry/IModuleRegistry.sol`, `contracts/registry/IModule.sol`
**Commit:** bbd61a3 (docs: NatSpec + sender field on ModuleRevoked/ModuleAccepted events), d1f71d0 (feat: add ModuleRegistry)

---

## Summary

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High     | 0 |
| Medium   | 1 |
| Low      | 0 |
| Info     | 0 |

---

## Findings

### [M-01] No upper bound on `expiration` — **Fixed**  *(Medium → Resolved)*

**Location:** `contracts/registry/ModuleRegistry.sol`

**Description:** Extension and New proposals had no ceiling on `expiration`, allowing a module to be registered effectively forever (`type(uint64).max`).

**Fix applied:** Added `MAX_MODULE_LIFETIME = 100 * 365 days` constant. Both New and Extension branches in `propose()` now revert `InvalidExpiration` when `expiration > block.timestamp + MAX_MODULE_LIFETIME`.

---

### [M-02] Shared registry allowance — *Known / by design*

`moduleBurn` calls `zchf.burnFrom(owner, registry)`, so burn-capable modules require users to approve the registry rather than the individual module contract. This is the intended single-choke-point architecture. Active modules are fully trusted by design.

---

## Fixed

| ID | Change |
|----|--------|
| M-03 (expiration cap) | `MAX_MODULE_LIFETIME = 100 * 365 days` added; `propose()` enforces it for New and Extension categories |
| L-03 (type mismatch) | `moduleExpiry` changed from `mapping(address => uint256)` to `mapping(address => uint64)`; narrowing cast in `propose()` removed |

---

## Notes

- **CEI pattern correctly applied:** Both `revoke()` and `accept()` delete proposal state before external calls, preventing reentrancy.
- **Struct packing is correct:** Two-slot layout (`address + uint96`, `uint64 + uint64`) matches Solidity packing rules.
- **Timestamp arithmetic is safe:** All `uint64(block.timestamp + ...)` casts are safe well beyond any realistic timeline.
- **`accept()` is permissionless by design:** No griefing is possible; outcome is identical regardless of caller.
