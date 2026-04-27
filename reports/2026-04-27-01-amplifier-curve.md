# Security Audit — AmplifierCurve / AmplifiedCurvePosition

**Date:** 2026-04-27
**Scope:**
- `contracts/amplifier/curve/AmplifierCurve.sol`
- `contracts/amplifier/curve/AmplifiedCurvePosition.sol`
- `contracts/amplifier/curve/helper/IAmplifierCurve.sol`
- `contracts/amplifier/curve/helper/IAmplifiedCurvePosition.sol`

**Commit:** 2f1039b

---

## Summary

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High     | 1 |
| Medium   | 3 |
| Low      | 2 |
| Info     | 4 |

---

## Findings

### [H-01] Reentrancy in `mint()` — state updated after external calls  *(High)*

**Location:** `AmplifiedCurvePosition.sol:56–78`

**Description:**
`mint()` follows this order:
1. `amp.borrowIntoPosition(...)` — external call that mints ZCHF and transfers collateral into the position
2. `pool.add_liquidity(...)` — external call to the Curve pool
3. `borrowed += zchfAmount` / `lpBalance += lpReceived` — state update

If the Curve pool (or a future pool with a receive hook) called back into `mint()` before step 3 completes, it would see stale `borrowed` and `lpBalance` values. A re-entrant `mint` call would pass the `onlyOwner` check (owner is unchanged), re-enter `borrowIntoPosition` (totalBorrowed is already updated in the amplifier so the limit check uses the correct value there, but `borrowed` in the position has not yet been incremented), and then both calls would write `borrowed += zchfAmount` — under-counting the total position debt by one cycle.

The crvUSD pool used today does not have transfer hooks, but the contract places no constraint on which pool is deployed against. A different TwoCrypto pool — or a future upgrade — could introduce this path.

**Recommendation:**
Update `borrowed` and `lpBalance` before the external calls (checks-effects-interactions):

```solidity
borrowed += zchfAmount;      // update state first
amp.borrowIntoPosition(...);
// ... approve, add_liquidity, reset approvals ...
lpBalance += lpReceived;
```

Alternatively add a `nonReentrant` guard from a trusted library.

---

### [M-01] `repay()` precision loss leaves dust debt permanently  *(Medium)*

**Location:** `AmplifierCurve.sol:136`

**Description:**
```solidity
zchfBurned = (borrowed * burnedLP) / totalLP;
```
Integer division truncates down. On partial burns, the remainder is never collected. A position with `borrowed = 3` and `totalLP = 3` that burns one LP at a time:
- Burn 1: `(3 * 1) / 3 = 1` — debt becomes 2, lpBalance becomes 2 ✓
- Burn 1: `(2 * 1) / 2 = 1` — debt becomes 1, lpBalance becomes 1 ✓
- Burn 1: `(1 * 1) / 1 = 1` — resolves cleanly ✓

However with non-round numbers, e.g. `borrowed = 10`, `totalLP = 3`:
- Burn 1: `(10 * 1) / 3 = 3` — debt becomes 7, lpBalance 2
- Burn 1: `(7 * 1) / 2 = 3` — debt becomes 4, lpBalance 1
- Burn 1: `(4 * 1) / 1 = 4` — resolves ✓

Still resolves in this case because the final burn always covers the remainder. But with very small `borrowed` and many partial burns, `zchfBurned` could round to 0, leaving `borrowed` stranded above 0 while `lpBalance` reaches 0. At that point `burn(0, ...)` would divide by zero (`totalLP = 0`).

**Recommendation:**
When `burnedLP == lpBalance` (full exit), burn the full remaining `borrowed` instead of using the proportion:

```solidity
zchfBurned = (burnedLP == lpBalance) ? borrowed : (borrowed * burnedLP) / lpBalance;
```

---

### [M-02] `totalBorrowed` can underflow if rounding causes `zchfBurned > totalBorrowed`  *(Medium)*

**Location:** `AmplifierCurve.sol:138`

**Description:**
`totalBorrowed -= zchfBurned` is unchecked against zero. In normal operation `zchfBurned <= position.borrowed <= totalBorrowed` holds. However if rounding in the final burn of one position yields a value that exceeds the remaining `totalBorrowed` (e.g. due to concurrent positions with complex partial-burn histories), the subtraction reverts under Solidity 0.8's checked arithmetic — permanently bricking all remaining repayments.

This is unlikely in practice but not impossible given integer truncation across multiple positions.

**Recommendation:**
Use `totalBorrowed = zchfBurned > totalBorrowed ? 0 : totalBorrowed - zchfBurned;` as a defensive floor, or apply the same "full exit = use remaining borrowed" fix from M-01, which also eliminates this class of error.

---

### [M-03] `price_oracle()` is a manipulable EMA — not a manipulation-proof price  *(Medium)*

**Location:** `AmplifierCurve.sol:70, 94`

**Description:**
`PRICE_ANCHOR` is set at construction from `CURVE_POOL.price_oracle()`, and `checkPrice()` compares live `price_oracle()` against it at every borrow. Curve's `price_oracle` is an exponential moving average (EMA), not an instantaneous spot price, which provides some manipulation resistance. However:

1. A well-capitalised attacker can move the EMA over time by sustained trading.
2. The ±20% band is wide enough that significant collateral-ratio degradation is possible before `checkPrice` reverts.
3. The anchor is fixed at deploy time. If the long-run price of ZCHF/crvUSD drifts more than 20% post-deployment (legitimately), all new borrows are permanently blocked even though the protocol is solvent.

**Recommendation:**
Consider whether a TWAP-based oracle or secondary price source would be more appropriate. At minimum, document that the ±20% band is intentionally wide and that the EMA's `ma_time` parameter of the pool determines manipulation cost. Expose `checkPrice()` as a pre-check that callers can query off-chain.

---

### [L-01] `_clone()` does not update the free memory pointer  *(Low)*

**Location:** `AmplifierCurve.sol:154–163`

**Description:**
The assembly block reads `mload(0x40)` (the free memory pointer) to determine where to write the proxy bytecode, but never updates `0x40` to `add(clone, 0x37)` after use. Any subsequent Solidity memory allocation in the same call frame (e.g. inside `initialize`) could theoretically overwrite the region before `create` completes. In the current call sequence `create` executes before any further allocation, so this is safe in practice, but it violates Solidity's documented memory model and will break if code is reordered.

**Recommendation:**
Add `mstore(0x40, add(clone, 0x37))` inside the assembly block after the three `mstore` calls.

---

### [L-02] `collateralAmount = 0` is accepted when `zchfAmount = 0`  *(Low)*

**Location:** `AmplifierCurve.sol:109–123`

**Description:**
`borrowIntoPosition` allows `zchfAmount = 0` with `collateralAmount = 0`. `getMinimumCollateral(0)` returns 0, the limit check passes (`newTotal + 0 ≤ LIMIT`), and a no-op borrow is registered: `ZCHF.mint(position, 0)` and `COLLATERAL.safeTransferFrom(owner, position, 0)`. While harmless today, zero-value mints generate a `Borrowed` event with `amount = 0` that can pollute off-chain accounting.

**Recommendation:**
Add `require(zchfAmount > 0)` at the top of `borrowIntoPosition`.

---

## Notes

**Gas: multiple external calls to `amp` in `mint()`**
`mint()` makes five external calls to retrieve `CURVE_POOL`, `ZCHF`, `COLLATERAL`, `ZCHF_INDEX`, and `borrowIntoPosition`. Caching `amp = AMP` (already done) is good; consider also caching the pool/token addresses in local variables to avoid repeated `SLOAD` + `CALL` overhead on each invocation, or reading them from the single `amp` call.

**`initialize()` is callable by anyone on a fresh clone before the factory's `isPosition` write**
Between `_clone()` returning and `isPosition[position] = true` being set, the clone is unregistered and `initialize` is callable by anyone. In practice this is atomic within a single transaction so no external party can interleave, but it is worth documenting as a constraint: `createAmplifiedPosition` must never be split across transactions.

**`Ownable._setOwner` rejects `address(0)` but no other validation**
`transferOwnership(address(0))` reverts, which is correct. However, ownership can be transferred to any non-zero address — including contracts that cannot call `mint`/`burn`. Consider adding a two-step ownership transfer pattern if positions are expected to be managed by complex multisigs.

**`EXPIRATION` is `uint40`** — maximum value ≈ year 36812. No practical risk, but it is a non-standard width that callers should be aware of when constructing deployment arguments.
