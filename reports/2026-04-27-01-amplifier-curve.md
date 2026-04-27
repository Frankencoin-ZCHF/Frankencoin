# Security Audit — AmplifierCurve / AmplifiedCurvePosition

**Date:** 2026-04-27
**Last updated:** 2026-04-27 (post-refactor)
**Scope:**
- `contracts/amplifier/curve/AmplifierCurve.sol`
- `contracts/amplifier/curve/AmplifiedCurvePosition.sol`
- `contracts/amplifier/curve/helper/IAmplifierCurve.sol`
- `contracts/amplifier/curve/helper/IAmplifiedCurvePosition.sol`

**Commit:** 2f1039b → updated at current HEAD

---

## Changelog

| Finding | Status |
|---------|--------|
| M-01 | Partially mitigated — full-exit guard added |
| L-02 | Fixed — `ZeroAmount` error added to `mint()` and `burn()` |
| Notes (amp cache) | Stale — local cache was removed in refactor |

---

## Summary

| Severity | Count | Open |
|----------|-------|------|
| Critical | 0 | 0 |
| High     | 1 | 1 |
| Medium   | 3 | 3 |
| Low      | 2 | 1 |
| Info     | 4 | 4 |

---

## Findings

### [H-01] Reentrancy in `mint()` — state updated after external calls  *(High — Open)*

**Location:** `AmplifiedCurvePosition.sol:57–78`

**Description:**
`mint()` follows this order:
1. `AMP.borrowIntoPosition(...)` — external call that mints ZCHF and transfers collateral into the position
2. `pool.add_liquidity(...)` — external call to the Curve pool
3. `borrowed += zchfAmount` / `lpBalance += lpReceived` — state update

If the Curve pool (or a future pool with a receive hook) called back into `mint()` before step 3 completes, it would see stale `borrowed` and `lpBalance` values. A re-entrant `mint` call would pass the `onlyOwner` check (owner is unchanged), re-enter `borrowIntoPosition` (`totalBorrowed` is already updated in the amplifier so the limit check uses the correct value there, but `borrowed` in the position has not yet been incremented), and then both calls would write `borrowed += zchfAmount` — under-counting the total position debt by one cycle.

The crvUSD pool used today does not have transfer hooks, but the contract places no constraint on which pool is deployed against.

**Recommendation:**
Update `borrowed` and `lpBalance` before the external calls (checks-effects-interactions):

```solidity
borrowed += zchfAmount;      // update state first
AMP.borrowIntoPosition(...);
// ... approve, add_liquidity, reset approvals ...
lpBalance += lpReceived;
```

Alternatively add a `nonReentrant` guard from a trusted library.

---

### [M-01] Partial burn precision loss — full-exit case mitigated, intermediate burns still truncate  *(Medium — Partially mitigated)*

**Location:** `AmplifiedCurvePosition.sol:93–95`

**Description:**
The proportional repayment calculation moved from `AmplifierCurve.repay()` to `AmplifiedCurvePosition.burn()` as part of the `repay` simplification:

```solidity
uint256 zchfRepay = (borrowed * lpAmount) / lpBalance;
if (lpAmount == lpBalance) zchfRepay = borrowed;   // ← full-exit guard added
```

The full-exit guard (`lpAmount == lpBalance → zchfRepay = borrowed`) correctly resolves the previously reported stranded-debt case where the final burn could leave non-zero `borrowed` with `lpBalance = 0`.

**Remaining risk:** Intermediate partial burns still use integer division, which truncates down. Across many small partial burns, rounding accumulates such that `borrowed` decreases more slowly than `lpBalance`. Extreme example: `borrowed = 1 wei`, `lpBalance = 1000` — burning 1 LP at a time yields `zchfRepay = 0` for the first 999 burns. The final burn resolves it correctly (`1 * 1 / 1 = 1`), but all intermediate burns are no-ops on the debt side. The position owner gets LP value back without incrementally reducing debt.

**Recommendation:**
Round up rather than down for partial burns:

```solidity
zchfRepay = lpAmount == lpBalance
    ? borrowed
    : (borrowed * lpAmount + lpBalance - 1) / lpBalance;  // ceiling division
```

---

### [M-02] `totalBorrowed` underflow risk if position passes inflated `zchfAmount` to `repay()`  *(Medium — Open)*

**Location:** `AmplifierCurve.sol:134` (`repay`)

**Description:**
`totalBorrowed -= zchfAmount` trusts the calling position to pass a value no greater than `totalBorrowed`. With the simplified `repay(address, uint256)` interface, the amplifier no longer calculates the proportional amount itself — it accepts whatever the position sends.

In normal operation `zchfAmount = (position.borrowed * lpAmount) / position.lpBalance` with the full-exit guard, so `zchfAmount ≤ position.borrowed ≤ totalBorrowed`. However, due to rounding across concurrent positions with interleaved partial burns, a final repayment could theoretically exceed the remaining `totalBorrowed`, causing a revert under Solidity 0.8 checked arithmetic and permanently bricking all remaining repayments on all other positions.

**Recommendation:**
Apply a defensive floor:

```solidity
totalBorrowed = zchfAmount > totalBorrowed ? 0 : totalBorrowed - zchfAmount;
```

---

### [M-03] `price_oracle()` is a manipulable EMA — not a manipulation-proof price  *(Medium — Open)*

**Location:** `AmplifierCurve.sol:70, 94`

**Description:**
`PRICE_ANCHOR` is set at construction from `CURVE_POOL.price_oracle()`, and `checkPrice()` compares live `price_oracle()` against it at every borrow. Curve's `price_oracle` is an exponential moving average (EMA), not an instantaneous spot price, which provides some manipulation resistance. However:

1. A well-capitalised attacker can move the EMA over time by sustained trading.
2. The ±20% band is wide enough that significant collateral-ratio degradation is possible before `checkPrice` reverts.
3. The anchor is fixed at deploy time. If the long-run price of ZCHF/crvUSD drifts more than 20% post-deployment (legitimately), all new borrows are permanently blocked even though the protocol is solvent.

**Recommendation:**
Consider whether a TWAP-based oracle or secondary price source would be more appropriate. At minimum, document that the ±20% band is intentionally wide and that the EMA's `ma_time` parameter of the pool determines manipulation cost. Expose `checkPrice()` as a pre-check that callers can query off-chain.

---

### [L-01] `_clone()` does not update the free memory pointer  *(Low — Open)*

**Location:** `AmplifierCurve.sol:154–163`

**Description:**
The assembly block reads `mload(0x40)` to determine where to write the proxy bytecode, but never advances the pointer to `add(clone, 0x37)`. Safe in the current call sequence but violates Solidity's documented memory model.

**Recommendation:**
Add `mstore(0x40, add(clone, 0x37))` inside the assembly block after the three `mstore` calls.

---

### [L-02] Zero-amount calls accepted  *(Low — Fixed)*

**Fixed in:** `AmplifiedCurvePosition.sol:57, 91` — `ZeroAmount` error added

`mint()` now reverts if `zchfAmount == 0 || collateralAmount == 0`. `burn()` now reverts if `lpAmount == 0`. Both checks fire before any external calls. The `ZeroAmount` error is declared in `IAmplifiedCurvePosition` as the single source of truth.

---

## Notes

**`mint()` now returns `lpReceived`**
The `mint()` function was updated to return the LP tokens received from `add_liquidity`. Callers no longer need to diff `lpBalance` before and after to determine how many LP tokens were issued.

**`initialize()` is callable by anyone on a fresh clone before the factory's `isPosition` write**
Between `_clone()` returning and `isPosition[position] = true` being set, the clone is unregistered and `initialize` is callable by anyone. In practice this is atomic within a single transaction so no external party can interleave, but `createAmplifiedPosition` must never be split across transactions.

**`Ownable._setOwner` rejects `address(0)` but no other validation**
Ownership can be transferred to any non-zero address — including contracts that cannot call `mint`/`burn`. Consider adding a two-step ownership transfer pattern if positions are expected to be managed by complex multisigs.

**`EXPIRATION` is `uint40`** — maximum value ≈ year 36812. No practical risk, but it is a non-standard width that callers should be aware of when constructing deployment arguments.
