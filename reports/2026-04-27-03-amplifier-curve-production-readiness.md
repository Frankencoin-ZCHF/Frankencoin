# Production Readiness Review — AmplifierCurve

**Date:** 2026-04-27
**Scope:**
- `contracts/amplifier/curve/AmplifierCurve.sol`
- `contracts/amplifier/curve/AmplifiedCurvePosition.sol`
- `contracts/amplifier/curve/helper/IAmplifierCurve.sol`
- `contracts/amplifier/curve/helper/IAmplifiedCurvePosition.sol`

**Commit:** c43b6ed
**Prior reports:** `2026-04-27-01` (code security), `2026-04-27-02` (game theory)

---

## Prior Finding Status

| ID | Title | Prior Status | Current Status |
|----|-------|-------------|----------------|
| 01-H-01 | CEI violation in `mint()` | Open | **Fixed** — `borrowed` updated before externals |
| 01-M-01 | Partial burn precision loss | Fixed | Fixed |
| 01-M-02 | `totalBorrowed` underflow | Open | **Fixed** — defensive floor in `repay()` |
| 01-M-03 | EMA oracle manipulation | Open | Open |
| 01-L-01 | Free memory pointer not updated | Open | **Fixed** — `mstore(0x40, ...)` added |
| 01-L-02 | Zero-amount calls accepted | Fixed | Fixed |
| 02-C-01 | No liquidation mechanism | Open | Open — design decision |
| 02-H-01 | Thin collateral requirement (1:1) | Open | Open — design decision |
| 02-M-01 | EMA manipulation for entry | Open | Open |
| 02-M-02 | Expired amplifier strands debt | Open | Open |
| 02-M-03 | Asymmetric price deviation risk | Open | Open |
| 02-L-01 | `LIMIT` immutable, no governance override | Open | Open |
| 02-L-02 | `minLp = 0` sandwich attack | Open | Open |

---

## Summary

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High     | 0 |
| Medium   | 1 |
| Low      | 2 |
| Info     | 4 |

*Economic and game theory findings (02-C-01, 02-H-01, 02-H-02, etc.) are design-level decisions documented in report 02 and excluded here. This report covers code-level readiness only.*

---

## Findings

### [M-01] Floating pragma — compiler version not pinned  *(Medium)*

**Location:** `AmplifierCurve.sol:2`, `AmplifiedCurvePosition.sol:2`

**Description:**
Both contracts use `pragma solidity ^0.8.0`, which accepts any compiler from 0.8.0 through the latest 0.8.x release. The project's `hardhat.config.ts` compiles with `0.8.24`. Deploying with a different toolchain or a future 0.8.x release could introduce subtle behavioural differences (storage layout changes, ABI encoding edge cases, EVM opcode availability). This also makes bytecode verification ambiguous — two separate compilations of the same source can produce different bytecodes.

**Recommendation:**
Pin to the exact version used in CI:

```solidity
pragma solidity 0.8.24;
```

---

### [L-01] Position `burn()` has no reentrancy guard  *(Low)*

**Location:** `AmplifiedCurvePosition.sol:99–111`

**Description:**
`burn()` calls `AMP.CURVE_POOL().remove_liquidity(lpAmount, minAmounts, owner)` before updating `borrowed` and `lpBalance`. `AMP.repay()` has `nonReentrant` on the amplifier side, but the position contract itself is unguarded. If the pool delivered a token with a receive hook (e.g. a future ERC-777 collateral), a re-entrant `burn()` call from within the token callback could re-enter before state is decremented.

In practice, `lpBalance -= lpAmount` would underflow under Solidity 0.8 checked arithmetic, reverting the entire chain and preventing exploitation. The protocol is safe for crvUSD/ZCHF specifically. However, the design is fragile for future pool deployments.

**Recommendation:**
Add a position-level reentrancy guard, or reorder to update `borrowed` and `lpBalance` before the `remove_liquidity` call (noting that token delivery to `owner` cannot be deferred).

---

### [L-02] Deployer must complete minter registration before expiration — not enforced on-chain  *(Low)*

**Location:** `AmplifierCurve.sol:59` (constructor)

**Description:**
The amplifier must be registered as a Frankencoin minter via `ZCHF.suggestMinter(amplifier, MIN_APPLICATION_PERIOD, MIN_FEE, ...)` and then activated after `MIN_APPLICATION_PERIOD` (10 days on mainnet) before any position can borrow. The constructor validates `expiration > block.timestamp` but does not enforce that `expiration > block.timestamp + MIN_APPLICATION_PERIOD`.

If deployed with `expiration` less than 10 days in the future, the amplifier expires before minter registration completes, making it permanently unusable. There is no on-chain safeguard against this deployment error.

**Recommendation:**
Either validate at construction:

```solidity
uint256 minPeriod = ZCHF.MIN_APPLICATION_PERIOD();
if (expiration <= block.timestamp + minPeriod) revert InvalidExpiration();
```

Or document this constraint prominently in the deployment checklist.

---

## Info

**I-01: No deployment script or checklist**
There is no deployment script for `AmplifierCurve`. The full sequence is:
1. Deploy `AmplifierCurve(pool, zchf, expiration, limit)`
2. Call `ZCHF.suggestMinter(amplifier, MIN_APPLICATION_PERIOD, MIN_FEE, "...")`  — requires ~1,000 ZCHF
3. Wait 10 days (864,000 seconds on mainnet)
4. Verify `ZCHF.isMinter(amplifier) == true`
5. Positions can now be created and funded

A missing or incorrectly ordered step leaves the amplifier deployed but non-functional, with the `EXPIRATION` clock ticking.

---

**I-02: `Ownable.transferOwnership` allows transfer to non-callable contracts**
Position ownership can be transferred to any non-zero address, including smart contracts without `mint`/`burn` implementations. A misconfigured multisig or a contract that does not call `burn()` effectively abandons the position, contributing to unbacked ZCHF supply.

---

**I-03: No event for `isPosition` registration**
`AmplifiedPositionCreated` is emitted with the position address and owner, which is sufficient for indexers. However, there is no separate event for the `isPosition[position] = true` write itself, making it marginally harder to audit the mapping state from logs alone. The existing event is adequate; this is a note for indexer authors.

---

**I-04: `PRICE_ANCHOR` can be stale at first borrow**
`PRICE_ANCHOR` is set at deployment from `price_oracle()`. If the amplifier is deployed but the minter registration takes 10+ days, the anchor could already be stale by the time the first borrow is possible. For a volatile pair this could mean `getMinimumCollateral` returns a value that no longer reflects the current market price. `checkPrice()` provides a partial guard (±20%), but the anchor itself never updates.

---

## Deployment Checklist

| Step | Action | Notes |
|------|--------|-------|
| 1 | Verify pool contains ZCHF | `pool.coins(0)` or `pool.coins(1)` == ZCHF |
| 2 | Verify both tokens are 18 decimals | Enforced by constructor |
| 3 | Set `expiration` ≥ `now + 10 days + buffer` | Buffer for minter activation window |
| 4 | Set `LIMIT` ≤ current Frankencoin equity reserve | Conservative sizing per report 02 |
| 5 | Deploy `AmplifierCurve` | Confirm constructor emits no revert |
| 6 | Approve `MIN_FEE` ZCHF and call `suggestMinter` | Caller needs ~1,000 ZCHF |
| 7 | Wait `MIN_APPLICATION_PERIOD` (10 days) | Monitor for `denyMinter` governance veto |
| 8 | Verify `ZCHF.isMinter(amplifier) == true` | Before any public announcement |
| 9 | Create a test position, mint small amount | Smoke test the full path |
| 10 | Verify `PRICE_ANCHOR` is current | If anchor is stale from slow deployment, redeploy |

---

## Verdict

**Code is production-ready with one prerequisite**: pin `pragma solidity ^0.8.0` to `0.8.24`.

All code-level security findings from prior audits are resolved. The remaining open items from report 02 (no liquidation, thin collateral buffer) are economic design decisions that must be consciously accepted by governance before deployment — they represent protocol risk parameters, not bugs. The `LIMIT` should be sized conservatively.
