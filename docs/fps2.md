# Frankencoin Pool Shares II (FPS2)

FPS2 wraps the existing Frankencoin Pool Share (FPS1) to form a "shareholder agreement" among participating holders. No one is forced to join, but doing so grants access to improved governance mechanics and a modern redemption mechanism. FPS2 follows the ERC-4626 tokenized vault standard, making it compatible with wallets and DeFi integrations that support it.

## Governance

FPS2 lowers the veto threshold from 2% of all votes (FPS1) to 1%, making it easier for a minority of holders to block harmful minter proposals. Additionally, the minimum minter application fee is raised to 5,000 ZCHF and the minimum application period to 90 days, giving holders more time and raising the cost of frivolous proposals.

### Vote Accumulation

Votes grow linearly with both the number of FPS2 held and the time they have been held. Specifically, an address holding *n* FPS2 for *t* seconds accumulates *n* &times; *t* votes. This rewards long-term commitment: a holder who has been in the system for a year has far more governance weight than someone who just arrived with the same number of shares.

To prevent lost or inactive addresses from accumulating votes indefinitely, anyone can cap a holder's effective holding duration at one year. This ensures that no address gains unbounded governance power simply by being forgotten.

When FPS2 tokens are transferred, the recipient's vote anchor is adjusted so that their existing votes are preserved but the newly received tokens start accumulating from zero. This prevents vote manipulation through circular transfers.

### Veto Rights

Any holder (or group of holders via delegation) that controls at least 1% of total votes can veto a pending minter proposal. Delegation is additive: delegating your votes to someone does not reduce your own voting power, it simply allows the delegate to count your votes when exercising a veto. Indirect delegation chains are supported (A delegates to B, B delegates to C -- C can count both).

Minters that were not proposed through the FPS2 governance contract can be vetoed by anyone, with a bounty of 10% of the reward pool paid to the caller. This creates an incentive for MEV bots to enforce the requirement that all minters go through the proper application process.

### Vote Destruction

FPS2 includes an `attack` function that allows a holder to sacrifice their own votes in order to destroy an equal number of votes belonging to other addresses. This is a defensive mechanism: if a hostile party accumulates votes, other holders can coordinate to neutralize the threat at a cost to themselves.

When FPS2 is binding (see below), the contract can also `shoot` FPS1 holders who have not wrapped their shares, destroying their FPS1 votes entirely. This prevents outsiders from undermining FPS2 governance.

## Issuance and Redemption

### Issuance

FPS2 can be obtained in two ways:

1. **Wrapping FPS1:** Existing FPS1 holders can wrap their tokens 1:1 into FPS2 via the `wrap` function. Accumulated FPS1 votes carry over, so long-term holders do not lose their governance weight by joining.

2. **Minting with ZCHF:** Anyone can deposit ZCHF to receive new FPS2. The ZCHF is invested into the underlying Equity contract (FPS1) at the current FPS1 price, and the resulting FPS1 shares are held by the FPS2 contract. The investment price (the "ask") equals the FPS1 price.

New investments also reduce the weighted recent redemption counter, helping the bid price recover faster after a period of selling.

### Redemption

FPS2 can be redeemed for ZCHF at any time -- there is no 90-day holding requirement like in FPS1. However, the redemption price (the "bid") is subject to a discount that depends on recent redemption activity.

**How the discount works:**

The contract tracks the volume of recent redemptions, weighted by recency. This counter decays linearly to zero over a 7-day recovery period. When someone redeems, the effective proceeds are:

> effective proceeds = raw FPS1 proceeds &times; discount factor

The discount factor is calculated as:

> discount = ((supply - shares/2) / (supply + recentRedemptions))^4

where *supply* is the current FPS2 supply, *shares* is the number being redeemed, and *recentRedemptions* is the time-weighted recent redemption volume.

The 4th-power curve means that small redemptions in calm markets face only a minor haircut (around 2% for 1% of supply), but large or rapid redemptions face steep discounts. The portion of proceeds not paid to the redeemer (the "spread") flows back into the Equity contract, benefiting all remaining holders.

In practice, this means:

- **Isolated small redemption:** If you redeem 100 out of 10,000 FPS2 with no recent activity, you receive about 98% of the underlying FPS1 value.
- **Sustained selling at 100/day:** The discount deepens over time as the redemption memory accumulates. By day 10, the discount factor drops to about 81%, and by day 20 to about 74%.
- **Recovery:** After selling stops, the discount decays back to zero over 7 days.

### Stress Scenario

Consider 10,000 FPS2 in circulation backed by 4,000,000 ZCHF in equity (FPS price: 1,200 ZCHF). An imminent loss of 1,000,000 ZCHF is about to hit the protocol. Without the FPS2 mechanism, rational holders would race to redeem before the loss materializes.

**Without FPS2 (plain FPS1):** The cubic pricing curve in FPS1 means early redeemers extract disproportionate value. In equilibrium, nearly all holders redeem (9,900 out of 10,000), draining essentially all equity. When the 1,000,000 loss hits, the system is insolvent. A 25% loss destroys the entire reserve.

**With FPS2 (4th-power discount):** The discount ramps up with each redemption, making it progressively less attractive to exit. In equilibrium, only about 900 holders redeem (9%), extracting 838,000 ZCHF at an average price of 931 ZCHF per share. The remaining 9,100 holders absorb the 1,000,000 loss with 2,162,000 ZCHF of equity left, resulting in a post-loss price of 713 ZCHF. This is 21% below the fair post-loss price of 900, but the system remains solvent and functional.

The discount mechanism converts a destructive bank run into a self-limiting process: early sellers get a reasonable price, but each redemption makes the next one less attractive until holding becomes the rational choice.

## Relation to FPS1

FPS2 holds FPS1 tokens on behalf of its holders. Each FPS2 is backed 1:1 by an FPS1 token in the contract. The FPS1 voting power of the FPS2 contract is delegated to the governance contract, which exercises it on behalf of FPS2 holders.

FPS2 becomes **binding** when the contract controls more than 50% of all FPS1 votes. Once binding:

- Holders cannot unwrap their FPS2 back to FPS1 (they are committed to the agreement).
- The contract can `shoot` FPS1 holders who remain outside the agreement, destroying their votes to prevent them from interfering with governance.
- Holders can still redeem FPS2 for ZCHF at any time (subject to the discount), but they cannot extract the underlying FPS1 tokens.

FPS2 can become unbinding again if enough FPS2 are redeemed or enough new FPS1 are minted outside the contract, pushing the vote share below 50%.

In a critical scenario where equity falls very low, qualified FPS2 holders (1% of votes with delegation) can trigger a cap table restructuring that burns the shares of specified FPS1 and FPS2 holders. This is an emergency mechanism of last resort.
