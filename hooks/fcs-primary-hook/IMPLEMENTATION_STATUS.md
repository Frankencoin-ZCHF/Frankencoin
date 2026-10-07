REVISED FOR UNIVERSAL ROUTER COMPATIBILITY — source, tests, evidence and docs regenerated together.

Final CI run: 127 test executions passed, zero failures/skips; 107 distinct names; 14,336 fuzz trials;
4 stateful invariants over 1,920 handler calls; 11 pinned mainnet fork tests including the deployed
Universal Router, Permit2 and V4 Quoter. See docs/TESTING.md and evidence/final-test-summary.json.

Hook follows the standard swap-then-settle ordering (input borrowed from PoolManager float, repaid in the
same transaction, `InsufficientInventory` otherwise) and accepts empty or 64-byte hookData. Exact-input
only; immutable protocol redemption gates remain authoritative; router/base/interface unchanged.

No changes to deployed FCS, no broadcasts or external deployments. Uniswap app routing additionally
requires Uniswap Labs allowlisting of the hook address and ZCHF/FCS float in the PoolManager.
External audit remains the funded-deployment gate; the revision has not been independently re-reviewed.
