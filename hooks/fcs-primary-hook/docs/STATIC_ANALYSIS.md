# Final-source static-analysis triage

Slither 0.11.6 was run against the current production sources (Foundry framework, Solidity 0.8.26,
`--filter-paths "lib/|test/|script/" --exclude-dependencies`). Raw results are in
`evidence/slither-final.json`; the SHA-256 of each scanned source file is in
`evidence/slither-source-manifest.json` and matches `evidence/final-test-summary.json`. Static analysis
is not a security audit. Do not interpret a finding count as a count of exploitable vulnerabilities, or a
reviewed warning as proof of safety.

The scan completed with **26 detector results: 7 High, 2 Medium, 4 Low and 13 Informational** labels.
These are analyzer classifications, not confirmed defects. Compared with the pre-revision scan (25) the
only change is one additional informational dead-code label for the new `_requireInventory` helper; a
Medium `uninitialized-local` label for the optional-hookData minimum was eliminated by initializing it
explicitly, which did not change the compiled bytecode (identical initcode hash).

## High: arbitrary ERC20 transferFrom (1)

The router callback contains a decoded payer, which triggers arbitrary-send-erc20. The entry point sets
payer to msg.sender, commits the entire request hash before unlock, and the callback requires both the
immutable PoolManager as caller and an exact matching active request. No public caller-selected payer API
exists. Review the victim-allowance and unauthorized-callback regression tests before accepting this as a
contextual false positive.

## High: balance/reentrancy findings (6)

The hook deliberately measures balances around FCS deposit/redeem and settlement, preserving any
pre-existing gifts and checking actual output against the reported amount. In the revised design the hook
also reads the PoolManager's token balance before `take` to fail early with `InsufficientInventory`. The
intended deployment uses the verified immutable FCS and its actual ZCHF/FPS dependencies, whose relevant
token transfers and primary calls have no arbitrary user callback. This trust assumption is essential: the
constructor interface is not a certification of arbitrary ERC4626-like contracts. Re-audit if any
dependency or routing design changes.

## Medium (2)

- `incorrect-equality`: the strict `settle() != output` comparison is an intentional exact-settlement check
  on the manager's return value, not a dependence on an attacker-controlled exact account balance.
- `reentrancy-no-eth` in the bundled router: the request hash is cleared only after the synchronous manager
  unlock callback finishes. Slither does not model this intentional authenticated callback lifecycle;
  inspect the guard and tests rather than moving the reset before the callback and breaking authorization.

## Low and Informational (17)

- Timestamp checks implement user deadlines; block timestamps are not used for randomness. The underlying
  FCS has its own time-dependent protocol mechanics.
- Event emitted after external calls (`reentrancy-events`) is the intended post-settlement execution log.
- Uppercase getters preserve the upstream FCS ABI and immutable-asset naming.
- Dead-code labels cover internal overrides reached only through `BaseTokenWrapperHook`/`BaseHook`
  dispatch (`_deposit`, `_withdraw`, `_settleOutput`, `_requireInventory`, `_supportsExactOutput`, `_pay`);
  they are live paths and must not be removed.
- Callback complexity reflects explicit settlement, authorization and delta checks; simplify only while
  preserving those checks.

Do not label this project Slither-clean. The revised hook has not been independently re-reviewed;
independent security review remains required before funded deployment.
