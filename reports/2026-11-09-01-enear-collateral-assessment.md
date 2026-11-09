# eNear (NEAR on Ethereum) as Frankencoin collateral

Token `0x85F17Cf997934a597031b2E18a9aB6ebD4B9f6a4` · Ethereum mainnet · measured 2026-11-09 (block ~26.377M)
Tests: `test/collaterals/NearCollateralTests.ts` (69 passing, fork block 26,376,900).

## Summary

eNear passes all ERC20 and MintingHub collateral checks (no fee, no blacklist, 24 decimals, returns `true`).
The risks are the exit routes, on-chain liquidity and admin power, not the token mechanics.

## Redemption to native NEAR

- The old Rainbow exit is closed to the public: `paused() = 3` (mint and `transferToNear` both off). A direct `transferToNear` reverts.
- Omni Bridge is the live exit. `rainbowbridge.app` sends from Ethereum through Omni (`0xe00c629aFaCCb0510995A2B95560E446A24c85B9`, not paused), which maps `wrap.near` to this token.
- Fork simulation: `initTransfer(eNEAR, 1 NEAR, "alice.near")` succeeds (~90k gas). The token is pulled into `0x150c79c8…`, which burns it via `transferToNear` (allowed despite the pause because it is the token's admin) and Omni emits `InitTransfer`.
- Not verified: the NEAR-side release (relayer/MPC), exit time, and whether NEAR backing is complete.
- Not determined: when Rainbow was paused, and any deadline for the legacy path.

## Exit liquidity (Uniswap V3, selling NEAR, ~$3.5)

Live pools: NEAR/USDC 0.3% (140k NEAR) and NEAR/WETH 1% (76k NEAR). Both together absorb roughly $300k.

| Sell (NEAR) | 1k ($3.5k) | 5k ($17.5k) | 10k ($35k) | 25k ($88k) | 50k ($175k) | 100k ($350k) |
|---|---|---|---|---|---|---|
| USDC pool slippage | −0.4% | −2.2% | −4.6% | −12.7% | −27.9% | −49.6% |
| WETH pool slippage | −0.3% | −1.5% | −3.0% | −8.0% | −27.8% | −63% |

Top holders: Railgun relay 19.1% (shielded, many users), two Uniswap pools 5%, two unlabeled wallets 5.7%.

## Risks

1. Admin power (highest): the token admin `0x150c79c8…` can call `adminSstore` and `adminDelegatecall` (fork test sets any balance), i.e. mint unbacked eNear. It is an upgradeable ERC1967 proxy (implementation `0x801f5ff0…`), used by Omni as the burn/mint hook. Who can upgrade it is unchecked.
2. Liquidations: a position backed by more than ~$50-100k of NEAR would take a large loss selling on-chain. Omni is cross-chain and not atomic (the NEAR-side release comes later, timing unmeasured), so it cannot settle a liquidation in one transaction. It only helps bidders who can wait and accept bridge risk.
3. Trust model: the exit now depends on Omni's relayer and MPC signers, not Rainbow's light client.
4. Concentration: Railgun's pool can exit at any time.

## Open items

- Owners and upgrade rights of the `0x150c79c8…` proxy and of Omni.
- NEAR-side backing versus the ~4.36M supply, and Omni exit time.
- Curve/Balancer liquidity, split-sale slippage.
- The test position assumes 2 ZCHF per NEAR (placeholder); 3,000 NEAR comes from the hub's 5000 ZCHF minimum.
