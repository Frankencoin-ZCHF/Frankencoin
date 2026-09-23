# FCS primary Uniswap v4 hook

A **local, tested, unaudited** exact-input primary-market adapter for the immutable Ethereum FCS at
`0xdb861830d9ae2d1fcf99fa0cfd3973de382b0b5b`. Nothing was deployed externally, no transactions were broadcast, and no FCS source or governance rules were changed.

**At pinned Ethereum block 26038677 the sell side is closed:** `FCS.isBinding() == false` and
`FPS1.canRedeem(FCS) == false`. A positive `previewRedeem` is not permission to redeem. The mainnet fork tests buy through the actual deployed PoolManager/FCS and verify the current sell rejection. Successful sell tests use a clearly simulated, matured/binding local instance of the genuine FCS and Equity source.

## Contents

- `src/FCSPrimaryHook.sol`: exact-input ZCHF deposit / FCS redeem; immutable FCS, ZCHF, manager; per-operation balance accounting; Universal Router compatible swap-then-settle ordering with optional hook-level slippage/deadline protection via 64-byte `hookData`.
- `src/FCSPrimaryRouter.sol`: guarded single-pool convenience router, authenticated unlock callback, input prefunding, recipient/input bounds, deadline and minimum-output checks. No arbitrary payer or sweep route.
- `src/base/BaseTokenWrapperHook.sol`: narrowly adapted upstream base (two added `virtual` modifiers); [exact patch and rationale](docs/UPSTREAM.md).
- `script/PrepareMainnet.s.sol`: **read-only** chain/code-hash checks, CREATE2 salt/address mining and deployment calldata preparation. It contains no broadcast or deployment call.
- `test/`: real PoolManager integration, genuine FCS/Equity fixture, adversarial callback transports, stateful invariants, and pinned mainnet fork tests against the deployed FCS, PoolManager, Universal Router, Permit2 and V4 Quoter. See [test matrix](docs/TESTING.md).
- `evidence/`, `logs/`: source/runtime verification and actual execution output. `final-*` files are the current revision; numbered logs record the earlier prefund-only design and its TDD RED runs.
- `dependencies.lock.json`: exact dependency and toolchain revisions; dependencies can be bundled under `lib/` without Git metadata.

## Build and test

Requirements: Foundry **v1.8.3**, Solidity **0.8.26**, Cancun-capable EVM. The compiler version, optimizer settings and portable artifact paths are pinned in `foundry.toml`. Source release bundles include vendored dependencies; no bootstrap is needed when `lib/` is present. Foundry may download the pinned compiler on first use.

```sh
# Only needed in a checkout without vendored dependencies (Python standard library):
python3 scripts/bootstrap_dependencies.py

forge build --sizes
forge test -vv                              # includes pinned mainnet forks (FCS, PoolManager, Universal Router, V4 Quoter)
forge test --no-match-contract Fork -vv     # offline after compiler installation
FOUNDRY_PROFILE=ci forge test -vv            # 2048 runs per fuzz test
forge fmt --check src/FCSPrimaryHook.sol src/FCSPrimaryRouter.sol src/interfaces/IFCS.sol test script
```

`MAINNET_RPC_URL` optionally overrides the default `https://eth-mainnet.public.blastapi.io`; the pinned block is historical, so the endpoint must serve archive state (plain full nodes such as `ethereum-rpc.publicnode.com` no longer do). Fork tests pin **26038677**, chain ID 1 and the verified FCS/PoolManager runtime hashes. They do not silently skip on RPC failure. The fork-only payer balance is funded with Foundry `deal`; FCS code, gates and timestamp are not patched.

The local fixture deploys the real Frankencoin, Equity and FCS contracts, seeds primary capital, and advances time to create a binding/mature state. Only the governance-helper factory is inert; no pricing, settlement, voting-age or redemption logic is mocked. A separate hostile-manager fixture tests callback authorization only, not swap correctness.

## Integration

Canonical pool: sorted **ZCHF/FCS**, fee **0**, tick spacing **1**, this hook, initialized with a valid dummy `sqrtPriceX96` (tests use `1 << 96`). No AMM positions or LP capital are required. Hook flags must be **0x2888** (before initialize, before add liquidity, before swap, before-swap-return-delta).

Approve the input token to the convenience router, then call:

```solidity
uint256 actualOut = router.swapExactInput(
    true,       // true: ZCHF -> FCS; false: FCS -> ZCHF
    amountIn,
    minOut,     // must be nonzero; choose from a fresh amount-specific quote
    recipient,
    deadline    // block.timestamp <= deadline
);
```

For external aggregators/unlock callers, the hook is **permissionless**, not restricted to the convenience router, and follows the standard Uniswap v4 **swap-then-settle** ordering used by the Universal Router and the V4 Quoter. Each hop MUST:

1. Use a negative `amountSpecified` (exact input), within `1..int128.max`.
2. Either pass **empty** `hookData` (slippage and deadline are then the caller's router's responsibility, e.g. Universal Router `amountOutMinimum`/`deadline`), or exactly `abi.encode(uint256 minOut, uint256 deadline)` as 64 bytes for an additional hook-level check; any other length, a zero minimum or an expired deadline reverts **in the hook**.
3. Settle the input debt and take the output before returning from unlock. Prefunding (settle before swap) is also accepted; a subsequent hop may be funded by backed output credit from a previous swap.

**Inventory float.** During `swap` the hook borrows the input token from the PoolManager's physical balance (other pools' reserves or ERC-6909 claim deposits) to execute `FCS.deposit`/`FCS.redeem`, and the caller's later settlement repays it within the same transaction; the PoolManager refuses to end the unlock otherwise. A swap larger than the singleton's balance of the input token reverts with `InsufficientInventory(required, available)`. Callers that prefund never depend on float. To guarantee capacity for swap-then-settle routers, park ZCHF (and, once the sell side is open, FCS) in the PoolManager as ERC-6909 claims; the depositor keeps full ownership and can burn the claims at any time.

Uniswap UI routing additionally requires Uniswap Labs to allowlist the hook address (it uses the `beforeSwapReturnDelta` flag). Fork tests drive the deployed mainnet Universal Router with its default encoding and the deployed V4 Quoter through the hook. Aggregator discovery/inclusion is not supplied or implied by deployment. The integration tests also prove an independent router can perform two primary hops within one unlock using intermediate credit, and can fund input with burned ERC-6909 claims.

Primary pricing comes from `FCS.deposit` / `FCS.redeem`, not FCS `wrap` / `unwrap`, `convertToShares`, `convertToAssets`, `ask`, `bid`, pool `slot0` or `sqrtPriceLimitX96`. A zero native AMM fee does not remove FCS/FPS curve fees or redemption discounts. **Exact output is deliberately rejected in both directions.** The ERC4626 `withdraw` inversion cap is not applied to `redeem`; a regression test redeems more than 10% of FCS supply.

## Trade indexing

Use the hook's `PrimaryExecution(bytes32 indexed poolId, address indexed router, bool buyFCS, uint256 amountIn, uint256 amountOut)` event for primary execution volume (`PoolId` is encoded as `bytes32`). It records actual trade amounts for every successful route, including external routers. The event's `router` field is the PoolManager-authenticated caller (normally a router), **not necessarily the economic payer or recipient**. The bundled router additionally emits `PrimarySwap` with payer and recipient.

Native PoolManager `Swap` logs contain zero native-curve amounts for these fully hook-executed swaps. Do not derive primary volume, execution prices or TWAPs from those native amounts or `slot0`, and do not double-count hook and router events. Amounts are raw token units; both target tokens have 18 decimals. Reverted transactions do not produce committed execution logs.

## Quotes and sell availability

```solidity
(uint256 amountOut, bool available, FCSPrimaryHook.QuoteStatus status) =
    hook.quoteExactInput(buyFCS, amountIn);
```

The read-only quote uses amount-specific `previewDeposit` / `previewRedeem`, validates signed bounds and zero/oversized outputs, and checks sell gates `isBinding && FPS1.canRedeem(FCS)`. It never uses `maxRedeem(hook)`, which is normally zero because this adapter holds no FCS inventory. When gates are closed, the quote can return a positive **theoretical** amount alongside `available=false`.

`available=true` means **the supported preview/gate checks pass**, not guaranteed execution. It does not check payer balance/allowance, pool initialization, downstream routes, primary recapitalization conditions or the FPS uint96 supply cap. In particular, a depleted reserve may preview a bootstrap mint that `Equity.invest` rejects for insufficient post-deposit capital. Upstream protocol calls remain authoritative. Failed preview/gate reads are reported unavailable for supported calls; immutable contract getters are trusted.

Quotes are advisory snapshots. A large deposit can dilute the **FCS contract's** FPS age and close subsequent redemptions. Competing deposits/redemptions alter nonlinear prices and discounts. Repeated primary hops must be simulated sequentially, not quoted independently against the same initial state. User deadlines and minOut must protect the executed transaction.

## Read-only deployment preparation

```sh
forge script script/PrepareMainnet.s.sol:PrepareMainnet \
  --rpc-url https://eth-mainnet.public.blastapi.io \
  --fork-block-number 26038677 --gas-limit 1000000000 -vv
```

Do **not** add `--broadcast`. The script's `run()` and `prepare()` are view-only: no key, signature, transaction submission, onchain initialization or deployment is performed. `prepare()` returns the predicted hook/router addresses, salt, initcode hash and raw calldata for the existing Arachnid CREATE2 factory. Its read-only address-mining loop can exceed a block's transaction gas; that is not the deployment cost. The fork test separately executes the prepared CREATE2 calldata in a disposable fork and verifies both deployed addresses, flags, immutable bindings and initcode hash.

Factory: `0x4e59b44847b379578588920cA78FbF26c0B4956C`.
Ethereum PoolManager: `0x000000000004444c5dc75cB358380D2e3dE08A90`.
Changing compiler, optimizer settings, source or constructor arguments changes the mined addresses. Re-run preparation against the intended chain state and independently review all calldata before any future approved deployment. Pool initialization would be a separate future action; an arbitrary initial price cannot change primary execution pricing.

## Accounting and trust boundaries

- Every operation snapshots input/output token balances, takes only its exact input, checks exact input consumption, computes the **new output balance delta**, verifies the protocol's returned amount, and settles precisely that output. Pre-existing token gifts at hook/router/manager are never counted as user output or slippage coverage.
- The manager tracks and closes currency deltas; the convenience router additionally verifies the expected input debit/output credit and zero final deltas. The hook borrows the input from the singleton's physical balance during the swap and relies on the PoolManager's end-of-unlock solvency check for repayment, exactly like Uniswap's own token-wrapper hooks; this is a liveness dependency on float, not a custody risk.
- No owner, upgrade path, fee collector, recovery or sweep function. Donations remain stranded by design; never send funds directly to hook/router. The sole hook allowance is ZCHF to immutable FCS; the router grants no token allowances.
- These contracts target the verified non-rebasing, non-fee-on-transfer FCS/ZCHF implementations and the pinned trusted v4 PoolManager. They are **not** a generic hostile-ERC20/upgradeable-vault adapter. Malicious dependency replacement, arbitrary tokens, asynchronous settlement and hostile callback tokens are outside the supported trust model.
- Callback caller plus active-request hash prevent forged payer requests; an active-request guard prevents reentrant user entry. The hook has manager-only callbacks and no unguarded swap branch. Protocol gates cannot be bypassed by an administrator.

## Evidence and release status

See [verification provenance](docs/PROVENANCE.md), [test matrix](docs/TESTING.md), and raw logs. All tests and deployment simulations are local. Build/test success and automated static analysis are **not an independent security audit**. Obtain an independent review/audit, integration testing with the chosen aggregator and explicit operational approval before real funds or deployment.
