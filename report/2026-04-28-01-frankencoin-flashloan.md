# Security Audit — FrankencoinFlashloan

**Date:** 2026-04-28
**Scope:**

- `contracts/flashloan/FrankencoinFlashloan.sol`
- `contracts/flashloan/IFrankencoinFlashloan.sol`
- `contracts/flashloan/IFrankencoinFlashloanCallback.sol`
- `contracts/flashloan/MockFlashloanRecipient.sol`

**Commit:** `9afcb7a` + unstaged changes
**Project type:** smartcontract

---

## Summary

| Severity | Count |
| -------- | ----- |
| Critical | 0     |
| High     | 0     |
| Medium   | 0     |
| Low      | 1     |
| Info     | 2     |

---

## Findings

### [L-01] No zero-address check on `_zchf` in constructor *(Low)* — Accepted

**Location:** `FrankencoinFlashloan.sol:27-29`

**Description:**
`zchf` is set to the raw constructor argument without validation. A deployment with `address(0)` will compile and deploy successfully but revert on every call with an opaque low-level error rather than a helpful message.

**Recommendation:**
```solidity
constructor(address _zchf) {
    require(_zchf != address(0), "zero address");
    zchf = IBasicFrankencoin(_zchf);
}
```

---

### [I-01] `burnFrom` burns without ERC-20 allowance — minter privilege is broad *(Info)* — Known

**Location:** `FrankencoinFlashloan.sol:38`, `Frankencoin.sol:204`

**Description:**
`burnFrom(address _owner, uint256 _amount)` in Frankencoin is `minterOnly` and calls `_burn(_owner, _amount)` directly, bypassing all ERC-20 allowance checks. `FrankencoinFlashloan` — once registered as a minter — can burn ZCHF from any address unconditionally. In the flash-loan context this is intentional: it enforces repayment without requiring the caller to approve anything. The contract exposes no other function that calls `burnFrom`, so this power is unused outside the flash-loan flow.

---

### [I-02] No fee mechanism — flash loans are free *(Info)* — Intentional

**Location:** `FrankencoinFlashloan.sol:31-41`

**Description:**
The contract charges no fee. Minting and burning happen at no cost to the borrower beyond gas. This is a deliberate design choice.

---

## Notes

- **M-01 resolved:** The previous `minterReserve()` cap has been removed. The import has been tightened from `IFrankencoin` to `IBasicFrankencoin`, which is the correct minimal interface for this contract.
- **Mock improvement:** `MockFlashloanRecipient` now uses a typed `NotFlashloan(address)` custom error instead of `require`, consistent with the rest of the codebase.
- The `nonReentrant` guard on `flashloan()` is correct and necessary — it prevents a malicious callback from re-entering to compound minted supply before the first burn.
- The event is emitted after `burnFrom`, so it only fires on successful completion.
- The `IBasicFrankencoin` import is the right minimal surface — `IFrankencoin` (with reserve/fee helpers) is not needed and was correctly dropped.
