# Security Audit — EIP-3009 Ignition Module & Contract Refactor

**Date:** 2026-05-26
**Scope:** `ignition/modules/transfer/ZCHFTransferWithAuthorization.ts`, `contracts/transfer/ZCHFTransferWithAuthorization.sol`
**Commit:** `48d425a` (module + report), `96ae3c3` (contract refactor)
**Project type:** smartcontract

---

## Summary

| Severity | Count |
| -------- | ----- |
| Critical | 0     |
| High     | 0     |
| Medium   | 0     |
| Low      | 0     |
| Info     | 1     |

---

## Findings

### [I-01] Previous finding I-01 resolved — domain separator now fork-safe _(Info)_

**Location:** `contracts/transfer/ZCHFTransferWithAuthorization.sol:50–59`

**Description:** Audit `2026-05-26-01` flagged the immutable `DOMAIN_SEPARATOR` as stale after a chain fork. This has been resolved: `DOMAIN_SEPARATOR()` is now a `view` function that reads `block.chainid` live on every call, identical to the pattern in `ERC20PermitLight.sol`. The domain was also simplified to `EIP712Domain(uint256 chainId,address verifyingContract)` matching the existing codebase convention.

No action required.

---

## Notes

**Contract refactor correctness:** The rename of `ZCHF` → `token` is purely cosmetic and introduces no behavioral change. All CEI ordering, nonce consumption, and signature verification logic is unchanged and remains correct.

**Domain type hash:** `0x47e79534a245952e8b16893a336b85a3d9ea9fa8c573f3d803afb92a79469218` is the correct keccak256 of `"EIP712Domain(uint256 chainId,address verifyingContract)"`, matching `ERC20PermitLight.sol`. ✓

**Previous findings status from `2026-05-26-01`:**

| Finding                           | Status                  |
| --------------------------------- | ----------------------- |
| L-01 Misleading NatSpec           | Fixed in `96ae3c3`      |
| L-02 No minter-liveness guard     | Declined (intentional)  |
| I-01 Stale domain separator       | Resolved in `96ae3c3`   |
| I-02 verifyingContract is sidecar | Accepted / known        |
| I-03 Minter privilege scope       | Accepted / acknowledged |
