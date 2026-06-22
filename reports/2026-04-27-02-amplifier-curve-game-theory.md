# Security Audit — AmplifierCurve: Game Theory & Economic Vectors

**Date:** 2026-04-27
**Scope:**
- `contracts/amplifier/curve/AmplifierCurve.sol`
- `contracts/amplifier/curve/AmplifiedCurvePosition.sol`
- `contracts/stablecoin/Frankencoin.sol` (reserve mechanics, mint path)

**Commit:** c4341f5 → updated at current HEAD
**Focus:** Price deviation, walk-away incentives, oracle manipulation

---

## Changelog

All findings in this report remain **open**. Subsequent code changes (simplified `repay`, `ZeroAmount` guards, `mint` return value) address code quality and correctness issues only — none of the economic or game-theoretic vectors described here were modified.

---

## Summary

| Severity | Count |
|----------|-------|
| Critical | 1 |
| High     | 1 |
| Medium   | 3 |
| Low      | 2 |
| Info     | 2 |

---

## Findings

### [C-01] No liquidation mechanism — abandoned positions create permanent unbacked ZCHF  *(Critical)*

**Location:** `AmplifierCurve.sol`, `AmplifiedCurvePosition.sol`

**Description:**
`burn()` is `onlyOwner`. No keeper, oracle, or governance function can force an underwater position to close. If a position owner walks away, the borrowed ZCHF remains minted forever with no backing and no path to recovery.

**Walk-away scenario:**
1. Owner borrows 100,000 ZCHF, deposits ~100,000 crvUSD at anchor price.
2. Over time ZCHF appreciates 25% vs crvUSD (legitimate market movement).
3. The LP position now contains ~80,000 ZCHF + ~95,000 crvUSD (due to TwoCrypto IL).
4. Repaying requires 100,000 ZCHF; the position only returns ~80,000.
5. Owner must buy 20,000 ZCHF at elevated market price to close. Net cost > net LP value.
6. Rational actor abandons the position — 100,000 ZCHF permanently orphaned in circulation.

Multiplied across all positions up to `LIMIT`, the maximum unrecoverable loss to the protocol equals `LIMIT` ZCHF.

**Recommendation:**
Introduce a liquidation path callable by anyone when the position is demonstrably underwater:

```solidity
function liquidate(address positionAddr) external {
    AmplifiedCurvePosition pos = AmplifiedCurvePosition(positionAddr);
    require(isPosition[positionAddr]);
    // verify LP value < borrowed at current oracle price
    uint256 lpValue = _estimateLpValueInZCHF(pos.lpBalance());
    require(lpValue < pos.borrowed(), "not underwater");
    // force-remove liquidity, burn what can be burned, cover shortfall from reserve
    ...
}
```

At minimum, add a `coverLoss` call path so that protocol equity can absorb orphaned debt via `ZCHF.coverLoss`.

---

### [H-01] Minimum collateral check provides no safety margin for IL or price drift  *(High)*

**Location:** `AmplifierCurve.sol:89` (`getMinimumCollateral`)

**Description:**
The collateral requirement is 1:1 value at the current oracle price — exactly the break-even point. There is zero margin for:

- **Impermanent loss:** TwoCrypto pools concentrate liquidity and rebalance aggressively. When ZCHF/crvUSD deviates, the LP holder bears IL. At a 20% price deviation (the maximum allowed by `checkPrice`), IL in a TwoCrypto pool can reach 5–10% of position value.
- **Price movement after deposit:** The anchor is fixed at deployment, not at deposit time. As the anchor ages, the gap between anchor price and deposit price can widen.
- **The walk-away threshold is effectively 0%:** Any positive ZCHF appreciation makes positions progressively more underwater. The protocol has no cushion before rational abandonment begins.

**Recommendation:**
Require collateral to exceed minimum by a meaningful margin (e.g. 120% — `minCollateral * 12 / 10`). This provides a buffer for IL and gives the oracle time to detect drift before positions are fully underwater. This is standard collateralisation practice in all CDP systems.

---

### [M-01] Oracle EMA can be gradually manipulated for favorable entry terms  *(Medium)*

**Location:** `AmplifierCurve.sol:94` (`checkPrice`)

**Description:**
`price_oracle()` is a Curve EMA with a `ma_time` window (typically 600–866 seconds on mainnet). An attacker with sufficient capital can:

1. Continuously trade ZCHF → crvUSD in the pool, pushing the instantaneous price down (ZCHF cheaper).
2. Over several `ma_time` windows, the EMA drifts downward.
3. When `price_oracle()` is depressed, `getMinimumCollateral(zchfAmount)` returns a lower value (less collateral required for the same ZCHF borrow — ZCHF is coin[1]).
4. Attacker opens a maximally leveraged position with artificially low collateral requirements.
5. EMA naturally reverts; attacker's position is now undercollateralised.
6. Attacker abandons — protocol absorbs the loss (C-01).

**Cost to attack:** Depends on pool depth and ma_time. For a deep pool this requires sustained capital and incurs trading fees, but the upside (abandoning a position with `LIMIT`-sized free mint) can exceed the cost.

**Recommendation:**
- Use `price_scale()` (the pool's internal rebalancing price, harder to manipulate than the oracle) as an additional sanity check alongside `price_oracle()`.
- Tighten the allowed band from ±20% to ±10%, reducing the manipulation window.
- Consider requiring the TWAP to be stable for N blocks before allowing a new borrow.

---

### [M-02] Expired amplifier leaves positions open with no repayment deadline  *(Medium)*

**Location:** `AmplifierCurve.sol:171` (`notExpired`)

**Description:**
`notExpired` blocks new borrows and position creation after `EXPIRATION`. However, all positions opened before expiry remain valid indefinitely — there is no forced close or grace period. Combined with C-01, this means:

- An amplifier approaching expiry with many open positions has no mechanism to wind down.
- Orphaned positions after expiry contribute to permanent unbacked ZCHF, but there is no event or monitoring hook that signals this to the protocol.
- A rational actor waiting near expiry can open a position and then simply wait, knowing that after expiry the protocol has even less leverage over them.

**Recommendation:**
Add a `closingDeadline` — a fixed window after `EXPIRATION` (e.g. 30 days) after which positions can be liquidated by anyone. This creates a forced wind-down schedule and bounds the time window of orphaned debt.

---

### [M-03] Upward ZCHF price deviation maximises protocol loss asymmetrically  *(Medium)*

**Location:** `AmplifierCurve.sol:93–98` (`checkPrice`)

**Description:**
Price deviation is symmetric in the check (±20%), but the economic impact is heavily asymmetric:

- **ZCHF depreciation (price falls):** LP position returns more ZCHF than was borrowed. Owners are in profit, all positions are incentivised to repay. Protocol is safe.
- **ZCHF appreciation (price rises):** LP position returns less ZCHF than was borrowed due to IL and unfavourable rebalancing. Owners face a loss. As appreciation increases beyond ~5–10% (IL), the rational choice transitions to abandonment.

The ±20% band allows enough upward drift to push every open position into the walk-away zone simultaneously. A correlated market event (e.g. CHF strengthening, crvUSD depeg) could trigger mass abandonment against a single amplifier, exhausting the full `LIMIT`.

**Recommendation:**
Consider an asymmetric band: tighter on the upside (e.g. +10%) where protocol risk accumulates, wider on the downside (e.g. -20%) where owners are incentivised to stay. Alternatively, `checkPrice` should also gate `repay()` — if price has drifted severely, forcing the owner to close at current price rather than the favourably-priced anchor.

---

### [L-01] `LIMIT` is the only bound on maximum protocol loss  *(Low)*

**Location:** `AmplifierCurve.sol:37, 116`

**Description:**
`LIMIT` is set once at deployment by the deployer with no governance override. If set too high relative to the pool's depth or the protocol's reserve, a single compromised or abandoned amplifier can exhaust a large fraction of the Frankencoin reserve. There is no on-chain mechanism to reduce `LIMIT` after deployment in response to changing market conditions.

**Recommendation:**
Add a governance-callable `reduceLimitTo(uint256 newLimit)` function that can only decrease (never increase) the limit. This allows the protocol to respond to deteriorating conditions without requiring a new deployment.

---

### [L-02] `minLp = 0` exposes position owners to sandwich attacks on mint  *(Low)*

**Location:** `AmplifiedCurvePosition.sol:56`

**Description:**
`mint(zchfAmount, collateralAmount, minLp)` passes `minLp` directly to `pool.add_liquidity`. If the caller passes `minLp = 0`, there is no slippage protection. An MEV bot can sandwich the deposit: manipulate the Curve pool price immediately before, extract value, then restore after. The position owner receives fewer LP tokens for the same debt, meaning their collateral efficiency is silently degraded.

This doesn't directly harm the protocol (the same ZCHF is burned on repayment regardless), but it degrades position health and pushes owners closer to the walk-away threshold.

**Recommendation:**
Compute and enforce a sensible minimum on-chain: e.g. require `minLp >= pool.calc_token_amount(amounts, true) * 99 / 100`.

---

## Notes

**`burn()` is callable on public burn path**
`Frankencoin.burn(uint256)` is publicly callable by anyone holding ZCHF. This means a third party *can* voluntarily burn ZCHF to reduce unbacked supply (e.g. a whitehacker or the protocol team). This is a useful escape hatch but not a substitute for a liquidation mechanism.

**LIMIT should be calibrated conservatively**
`LIMIT` caps the maximum unbacked ZCHF if all positions walk away. It should be sized relative to the protocol's capacity to absorb loss — not set to the maximum technically allowed.
