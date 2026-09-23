# Independent read-only FCS primary-hook review

## Verdict

No confirmed exploitable high/medium-severity defect was identified in the reviewed exact-input hook/router against the intended immutable FCS/ZCHF and canonical PoolManager. This is a bounded independent code review, not an audit or production-safety certification. The working tree is uncommitted and was being edited concurrently; this verdict attaches to the source hashes in `review-manifest.json`, not to later changes.

Repository: `/home/ec2-user/clawd/projects/fcs-primary-hook`.

## Non-blocking findings and remaining assurance

### I-01 — Native v4 Swap events report zero amounts; external routes lack a hook-level execution event

References: `src/FCSPrimaryHook.sol:63-79`; `src/base/BaseTokenWrapperHook.sol:133-157`; `src/FCSPrimaryRouter.sol:40-42,90`; dependency `PoolManager.sol:202-226,240-250`.

A full primary transformation offsets the complete specified amount before native pool execution. Independently executed traces show the manager emits `Swap(amount0=0, amount1=0, liquidity=0)` on successful buys and sells. The bundled router subsequently emits the accurate `PrimarySwap`, but permissionless external routers need not do so, and the hook itself emits no trade event. Indexers consuming only native Swap logs will omit primary volume and must not infer prices from slot0.

Recommendation: explicitly document this indexing limitation and use token/FCS events plus transaction traces, or add a hook-level event carrying authenticated caller, direction, exact input and actual output. This is an observability/integration limitation, not a demonstrated asset-loss exploit.

### I-02 — Additional adversarial acceptance coverage remains desirable

References: `test/PrimaryHook.t.sol` (`setUp`); `test/Security.t.sol` (`test_forgedVictimDuringActiveRequestCannotDrainApproval`, `test_activeRequestRejectsReentrantUserEntry`, `test_replayedValidLookingRequestCannotDrainApproval`, fuzz tests); `test/MainnetFork.t.sol` (`setUp`). Test files were being formatted during review, so function names are the stable test citations.

The supplied suite provides extensive real-manager execution, donation isolation, minOut rollback, integer bounds, malformed hookData, gate combinations, exact-output rejection and active-request negative tests. It does not yet demonstrate direct-FCS-versus-adapter execution from identical snapshots, a real smart-contract-wallet payer, stale sell quotes after an intervening redemption, or before/at/after seven-day discount recovery boundaries. The callback-tampering/reentrancy tests use a deliberately fake manager; they are valid boundary tests, not proof of attacker reachability through the canonical manager. Fixed production-token call paths inspected here do not invoke arbitrary recipient callbacks.

Recommendation: add these targeted regressions before production sign-off. Do not describe every row of the larger adversarial checklist as executed merely because current tests pass.

## Security reasoning checked

- Hook entry points inherit `onlyPoolManager`. Initialization enforces the exact sorted pair, zero fee and tickSpacing 1; the real manager requires pool initialization before swapping. No arbitrary PoolKey route is accepted by the bundled router.
- Exact output is explicitly rejected. Negative input is bounded before negation/casts; output is nonzero and bounded to signed int128.
- Hook requires exactly 64-byte `(minimumOutput, deadline)`, nonzero minimum and inclusive deadline. These checks apply to external routers as well as the bundled one.
- Router payer is captured from `msg.sender`, then bound to callback bytes via `activeRequest`; caller must be the immutable manager. The manager's actual unlock implementation calls its initiating caller, once, and rejects nested unlocks.
- Actual trace order is `sync -> payer transferFrom -> settle -> swap -> hook take` in both directions with initially empty manager inventory. Hook requires caller-owned positive input credit before the transformation. End-of-unlock nonzero deltas revert.
- Buy uses exact `FCS.deposit(amount, hook)`; sell uses exact `FCS.redeem(amount, hook, hook)`. No migration wrap/unwrap or inverse exact-output approximation is used.
- Before/after balance checks isolate gifts and cross-check protocol-reported output. Settlement return values and router deltas are checked exactly. Fixed references, no admin arbitrary execution, no sweep and no mutable approval target were found.
- Sell quote checks binding and `FPS1.canRedeem(FCS)`, not seller age or the empty hook's maxRedeem. Quote documentation correctly makes availability advisory and excludes recapitalization/supply-cap modeling.
- No protocol gate bypass was found. The fork demonstrates a successful buy and an atomic `RedemptionsDisabled()` failure on the purchased shares; enabled sells use real locally deployed FCS/Equity logic after synthetic maturation, not live mainnet eligibility.
- Local BaseTokenWrapperHook matches pinned upstream except provenance/import and the two documented virtual keywords. Eleven fixture FCS source files match the supplied verified-source SHA-256 evidence.
- Read-only PrepareMainnet pins chain 1, FCS and manager runtime hashes, asset/FPS addresses, and derives the first-CREATE router address; its mined deployment plan executes successfully inside the fork test. No broadcast was performed.

## Independently executed verification

Foundry 1.8.3, solc 0.8.26, configured Cancun EVM and optimizer settings.

Final recorded full run: **65 test executions passed, 0 failed, 0 skipped**, consisting of MainnetForkTest 5, PrimaryHookTest 5, SecurityTest 55. There are **60 distinct test function names** because SecurityTest inherits PrimaryHookTest. Five fuzz tests each completed 512 runs.

Mainnet fork block: **26038677**. The real FCS and canonical manager codehash assertions pass. Both redemption predicates remain false at that snapshot. Mainnet buying succeeds; no claim of live enabled selling is supported.

Source files were unchanged during the final recorded test run. The reviewed router hash includes the later constructor configuration checks. The subsequent formatting-only source edits were reread and the full suite rerun; review-manifest.json contains these final reviewed hashes. Compiler/build and deployed-size checks completed; no repository edits were made by this reviewer.

Commands (run from repository):

```sh
FOUNDRY_OUT=/tmp/fcs-independent-review/out FOUNDRY_CACHE_PATH=/tmp/fcs-independent-review/cache forge test --json
FOUNDRY_OUT=/tmp/fcs-independent-review/out FOUNDRY_CACHE_PATH=/tmp/fcs-independent-review/cache forge test --match-contract PrimaryHookTest --match-test 'test_(buyFromEmptyManager|sellFromEmptyManager_realMatureBindingFCS)' -vvvv
FOUNDRY_OUT=/tmp/fcs-independent-review/out FOUNDRY_CACHE_PATH=/tmp/fcs-independent-review/cache forge build --sizes
```

## Preliminary static-analysis triage

Slither was not available on this reviewer's PATH. The existing `/tmp/fcs-slither-preliminary.json` was inspected, not regenerated. Its source line offsets predate the final router constructor change, so a final pinned scan remains the parent's responsibility.

- `arbitrary-send-erc20`: not confirmed; `r.payer` is bound to the initiating caller via authenticated active-request data.
- Hook `reentrancy-balance`: not confirmed for the immutable intended contracts; inspected token/FCS paths have no arbitrary user callback, and the equality checks enforce conservation rather than grant a withdrawal from ambient balances.
- Router `reentrancy-no-eth/events`: activeRequest is set before unlock, rejects nested user entry, and remains live through its authenticated callback until unlock returns.
- `incorrect-equality` on zero-output rejection and deadline/timestamp findings are intentional guards.
- Claimed dead deposit/redeem methods are demonstrably exercised in the actual traces.
- Earlier router zero-hook warning is addressed in the source version pinned by this report.

Do not equate this manual triage with a zero-warning final Slither run or formal proof.

## Artifacts and operational limitations

Created only reviewer artifacts under `/tmp/fcs-independent-review/`: this report, `review-manifest.json`, `test-results.json`, `test-stderr.txt`, `prefunding-traces.log`, and isolated Foundry output/cache directories. Root disk was almost full, so build output was redirected to tmpfs. No project source/test/config file, dependency, chain state or external service was modified by this reviewer. The uncommitted, concurrently changing working tree means final packaging must re-check hashes and rerun verification after the implementer freezes it.
