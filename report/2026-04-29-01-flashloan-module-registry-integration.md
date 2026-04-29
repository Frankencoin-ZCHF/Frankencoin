# Security Audit — flashloan module-registry integration

**Date:** 2026-04-29
**Scope:**
- `contracts/flashloan/FrankencoinFlashloan.sol` — registry integration
- `contracts/flashloan/IFrankencoinFlashloan.sol` — registry/zchf getters added
- `contracts/flashloan/MockFlashloanRecipient.sol` — field rename, quote style
- `contracts/flashloan/ReentrantFlashloanMock.sol` — new test-only contract
- `test/FrankencoinFlashloanTests.ts` — new fork test suite

**Commit:** `252b064` + unstaged changes (registry integration)

---

## Summary

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High     | 0 |
| Medium   | 0 |
| Low      | 1 |
| Info     | 2 |

---

## Findings

### [L-01] `ReentrantFlashloanMock` is a test-only contract compiled into production artifacts  *(Low)*

**Location:** `contracts/flashloan/ReentrantFlashloanMock.sol`

**Description:**
`ReentrantFlashloanMock` serves no purpose beyond the reentrancy test. Placing it under
`contracts/flashloan/` means it is compiled into the Hardhat artifact output and included in
any deployment tooling that iterates `artifacts/`. It could be inadvertently deployed to a
production network, and its presence inflates the auditable surface for future reviewers.

**Recommendation:**
Move test-only contracts to a dedicated `contracts/test/` directory (or a sibling `test/contracts/`
folder) so they are clearly separated from deployable code. Most deployment scripts and audit
tools already honour this convention.

---

### [I-01] Constructor zero-address guard implicit but opaque  *(Info)*

**Location:** `contracts/flashloan/FrankencoinFlashloan.sol:31-33`

**Description:**
The previous audit flagged the absence of a zero-address check on `_zchf` (L-01). The new
constructor takes `IModuleRegistry registry_` and immediately calls `registry_.zchf()`. If
`address(0)` is passed, the external call succeeds (address(0) has no code, returns empty
bytes), but Solidity's ABI decoder then panics trying to decode a zero-length return as
`IBasicFrankencoin`, causing the deployment to revert. The deployment-time revert is strictly
better than the previous runtime failure, but the error message is an opaque ABI panic rather
than a readable revert reason.

**Recommendation:**
Add an explicit guard for a clear deployment-time error:
```solidity
constructor(IModuleRegistry registry_) {
    require(address(registry_) != address(0), "zero registry");
    registry = registry_;
    zchf     = registry_.zchf();
}
```

---

### [I-02] Module expiry creates a liveness dependency on governance renewal  *(Info)*

**Location:** `contracts/registry/ModuleRegistry.sol` — `moduleExpiry` mapping

**Description:**
`FrankencoinFlashloan` now relies on its entry in `moduleExpiry` being non-expired for every
call to `registry.moduleMint` and `registry.moduleBurn`. Once `moduleExpiry[flashloan]`
passes, all flash loans revert with `NotActive()`. Re-enabling requires a fresh governance
cycle (propose → 30-day veto → accept), meaning the provider could be down for over a month
if the TTL lapses unnoticed. This risk is shared by every module, but it is more acute for
a low-governance-overhead utility like a flash-loan provider.

**Recommendation:**
Monitor the module expiry off-chain and submit an Extension proposal well before the TTL
lapses. Consider documenting the expiry date prominently in the deployment registry and wiring
an on-chain event monitor or alert to fire at, say, 60 days before expiry.

---

## Notes

- **Previous L-01 resolved (implicitly).** The old zero-address issue on `_zchf` no longer
  applies; deployment-time revert is now enforced by the `registry_.zchf()` call.
- **Previous I-01 (`burnFrom` minter privilege) remains.** The privilege now flows through the
  registry's `moduleBurn`, not directly from this contract. The trust model is unchanged —
  an active, registry-approved module can burn from any address without allowance.
- **Previous I-02 (no fee) remains.** Flash loans are still free by design.
- **`zchf` immutable is view-only.** The `zchf` field is set and exposed for integrator
  convenience but is not used inside `flashloan()` — all minting and burning route through
  `registry.moduleMint`/`moduleBurn`. No functional concern.
- **Test suite is solid.** 13 tests covering constructor invariants, guard reverts, net-zero
  balance, supply invariance, callback emission, sequential loans, and reentrancy. The
  `ReentrantFlashloanMock` correctly validates the `nonReentrant` path.
