# Test matrix and final verification (revision: swap-then-settle compatible hook)

Authoritative results for the current sources: `evidence/final-ci-tests.json` (`forge test --json`,
CI profile, includes the pinned mainnet fork suites; the invariant campaign's multi-megabyte call traces
were removed from the file, every other field is verbatim) and `evidence/final-test-summary.json`
(derived counts and the SHA-256 of every production source file). Human-readable output is in
`logs/final-tests.log` (default profile, `-vv`) and `logs/final-ci-tests.log` (CI profile).

Final CI run: **127 test executions passed, zero failed, zero skipped** across 7 suites; **107 distinct
test names** (inherited base tests execute in several suites). 7 fuzz properties completed **14,336 trials**
(2048 runs each). One stateful invariant campaign (4 invariants) ran 48 sequences of depth 40
(1,920 handler calls, zero reverts). 11 tests run against a pinned mainnet fork.

| Suite | Tests | What it proves |
|---|---|---|
| `PrimaryHookTest` | 5 | Genuine local FCS/Equity fixture: buy and sell through the bundled router from an empty PoolManager, quotes equal amount-specific previews. |
| `SecurityTest` | 56 | Callback/payer attacks, malformed hookData, integer bounds, exact-output and LP rejection, donations, stale quotes, gate changes, swap-then-settle float borrowing and repayment, clear `InsufficientInventory` failures, fuzzed round trips. |
| `ReviewGapsTest` | 28 | Hook-level `PrimaryExecution` event accuracy, contract-wallet payer, direct-vs-adapter execution from identical snapshots, seven-day discount recovery boundaries. |
| `DeepTestingTest` | 21 | Hostile pool initialization prices, both token orderings, ERC-6909-claim-funded routes, LP-pool to primary multi-hop in one unlock, protocol fee inertness, nested-unlock rejection, bootstrap quote gap, dust sells. |
| `PrimaryHookInvariants` | 6 (4 invariants) | Random users trade through the router while competing investors deposit, redeem, buy FPS and time advances: adapter/singleton hold nothing, FCS supply equals wrapped FPS, supply conservation, execution always equals the immediate quote. |
| `MainnetForkTest` | 5 | Real deployed FCS and PoolManager at block 26038677: live buy, atomic sell rejection by the live gates, quotes, CREATE2 preparation executed in a disposable fork. |
| `UniversalRouterForkTest` | 6 | Real deployed Universal Router, Permit2 and V4 Quoter: the Uniswap app's default `SWAP -> SETTLE_ALL -> TAKE_ALL` encoding with empty hookData buys FCS and repays the borrowed float; settle-first and OPEN_DELTA encodings; buy beyond singleton float fails with `InsufficientInventory`; live sell gates propagate; the quoter returns the primary preview. |

## Design revision covered by this run

Earlier evidence (numbered logs `01`-`17`, `review-event-*.log`, `evidence/baseline-review-manifest.json`)
documents the previous design, which required callers to settle input credit **before** the swap and to
supply 64-byte hookData. Those rules made the pool unusable by the Universal Router and unquotable by the
V4 Quoter. The revised hook follows the standard swap-then-settle ordering, borrowing the input from the
PoolManager's physical balance for the duration of the transaction (repayment is enforced by the manager),
and accepts empty hookData. The tests that asserted the old rules were rewritten to assert the new ones:

- `test_unfundedRouterCannotRelyOnSingletonInventory` -> `test_swapThenSettleRouterBorrowsSingletonInventoryAndRepaysIt`
- `test_unfundedRouterRejectedWithEmptyManager` -> `test_swapThenSettleRevertsWithEmptyManager` (+ one-wei-short variant)
- `test_hookRejectsEmptyHookData` -> `test_hookAcceptsEmptyHookDataAndDefersSlippageToRouter`
- `testFuzz_hookRejectsMalformedHookData` now excludes length 0 as well as 64

## Fixtures

The local fixture deploys the real Frankencoin, Equity and FCS contracts (pinned commit), seeds primary
capital and advances time to a binding/mature state. Only the governance-helper factory is inert. The
`DeepTestingTest` stack builder can place the genuine FCS bytecode at a chosen address to force either
token ordering and can leave the system un-bootstrapped. `ActionRouter` (test only) composes arbitrary
PoolManager action sequences; `ExternalRouter` (test only) supports both prefund and swap-then-settle.

Fork suites pin block **26038677**, chain ID 1 and the FCS/PoolManager runtime hashes, and do not skip
on RPC failure. The pinned block requires an archive-capable RPC; the default is
`https://eth-mainnet.public.blastapi.io` (override with `MAINNET_RPC_URL`). Only the test payer's ZCHF
balance is dealt; FCS code, gates, timestamps and Uniswap contracts are live.

## Reproduce

```sh
forge build --sizes
forge test -vv                                       # default profile, includes forks
forge test --no-match-contract Fork -vv              # offline
FOUNDRY_PROFILE=ci forge test --json > evidence/final-ci-tests.json
forge fmt --check src/FCSPrimaryHook.sol src/FCSPrimaryRouter.sol src/interfaces/IFCS.sol test script
```

`MANIFEST.sha256` lists the SHA-256 of every file in this directory (LF-normalized, as stored in git);
`.gitattributes` pins LF so the manifest and `forge fmt --check` reproduce on Windows checkouts.

## Deployment preparation

`logs/final-deployment-preparation.log` holds the current-source read-only CREATE2 plan (hook
`0x747a076611A138ae063179800D43d8aE33b7E888`, router `0xc056Bb03EB2eF7F86f570AAB52C8Fba13B3E8566`).
Predictions are **not deployed addresses**; any source, compiler or constructor change invalidates them.
`logs/final-build-sizes.log` records compiled sizes. No keys, broadcasts or mainnet writes were used.

Build/test success and static analysis are not an independent security audit. The revised hook has not
been independently re-reviewed; see `docs/REVIEW_CLOSURE.md` and `docs/STATIC_ANALYSIS.md`.
