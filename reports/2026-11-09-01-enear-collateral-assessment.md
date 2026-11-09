# eNear (NEAR via Rainbow Bridge) as Frankencoin collateral

Date: 2026-11-09 · Token: `0x85F17Cf997934a597031b2E18a9aB6ebD4B9f6a4` · Chain: Ethereum mainnet
Measured at block ~26,376,993. Tests: `test/collaterals/NearCollateralTests.ts` (69 passing, fork block 26,376,900).

## Summary

eNear passes all ERC20 and MintingHub collateral checks, but three things weigh against it as collateral:

1. The bridge is paused in both directions, so there is currently no redemption path to native NEAR.
2. On-chain exit liquidity is thin (~$300k absorbable across two Uniswap V3 pools).
3. A single admin address can write any storage slot and delegatecall, i.e. mint or rewrite balances.

Its value therefore depends on Ethereum DEX depth, not on the CEX liquidity of native NEAR, and on the trustworthiness of the admin key.

## Token

- Rainbow Bridge `eNear`: OpenZeppelin 3.x ERC20 (solc 0.6.12), 24 decimals, supply ~4.36M, ~16.5k holders.
- No proxy (EIP-1967 implementation slot is empty), but the admin can still change state arbitrarily, see Risks.
- No transfer fee, blacklist or freeze function; transfers return `true`. Funding in the tests impersonates the Uniswap NEAR/USDC pool. All shared collateral checks pass (hub, position, challenge, bid, forced sale).

## Bridge status

- `paused()` = `3`: bit 0 (mint from NEAR) and bit 1 (burn to NEAR, `transferToNear`) are both set.
- `transferToNear` reverts on mainnet while paused (eth_call, ~26k gas, no reason string).
- Fork test: after the admin calls `adminPause(0)` the same call succeeds, emits `TransferToNearInitiated` and burns the tokens, so the bridge's exit side works once unlocked. Only the burn on Ethereum is tested; the NEAR-side release is not verifiable here.
- Plain ERC20 transfers and DEX trading are unaffected.
- Admin `0x150c79c8a70B1D528e95e200C6cA5Ed0421C44f7` can reopen with `adminPause(0)` (works in the fork). It is a ~170 byte contract, possibly a Safe proxy; owners and threshold not checked.
- Not determined: when it was paused, whether it is a deliberate wind-down or temporary, whether a successor bridge exists.

## Holders (Etherscan, 2026-11-09)

| Holder                                    | NEAR    | Share |
| ----------------------------------------- | ------- | ----- |
| Railgun relay (shielded pool, many users) | 832,878 | 19.1% |
| `0xeE334C43…e5a1E7bfB` (unlabeled)        | 165,745 | 3.8%  |
| Uniswap V3 NEAR/USDC                      | 141,744 | 3.3%  |
| `0x033E6932…BAa34aE12` (unlabeled)        | 81,842  | 1.9%  |
| Uniswap V3 NEAR/WETH                      | 76,087  | 1.7%  |

Implied price ~$3.49 per NEAR.

## Exit liquidity (Uniswap V3, sell NEAR, average price vs a 100 NEAR trade)

Live pools: NEAR/USDC 0.3% (`0xee8AAa36…16eA`, 140,461 NEAR) and NEAR/WETH 1% (`0x9Ba3F47F…1Dd8e`, 76,087 NEAR). Other fee tiers and USDT/DAI/WBTC pairs are empty.

| Sell (NEAR) | USDC pool | WETH pool |
| ----------- | --------- | --------- |
| 1,000       | −0.4%     | −0.3%     |
| 5,000       | −2.2%     | −1.5%     |
| 10,000      | −4.6%     | −3.0%     |
| 25,000      | −12.7%    | −8.0%     |
| 50,000      | −27.9%    | −27.8%    |
| 100,000     | −49.6%    | −63%      |

The pools can absorb roughly $300k of NEAR in total (~$177k USDC plus ~60 ETH), not the ~216k NEAR they hold.
Single-pool figures; splitting a sale across both would be somewhat cheaper.

## Risks

1. No redemption: while the bridge is paused, price is set by Ethereum liquidity only and can depeg from native NEAR.
2. Liquidations: a position backed by more than ~$50-100k of NEAR would take a large loss selling on-chain.
3. Admin power (highest severity): besides pausing, the admin can call `adminSstore` and `adminDelegatecall`. A fork test sets an arbitrary balance, so one key can mint unbacked eNear, which would then be sold into the same thin pools or posted as collateral. No proxy is involved, but this is equivalent to an upgrade key. Only the admin can reopen the bridge. Severity depends on who controls the admin contract (unchecked).
4. Concentration: Railgun holds 19% and its users can exit at any time.
