## CCIP Admin

This document summarizes the governance-facing functions of the `CCIPAdmin` contract, which performs CCIP bridge administration through the Frankencoin governance process. Rather than a single centralized operator, configuration changes are proposed by qualified voters and—unless denied—can be executed after a configured delay. Time-critical actions (rate limits) can be applied immediately by qualified voters.

**Key concepts**

- **Qualified voters:** Functions that create or deny proposals require the caller to be a qualified voter (the contract checks a set of helpers via governance).
- **Proposals:** Proposal data is stored as a hash together with a deadline. Proposals are created with a delay (in days). They can be denied by qualified voters or enacted after the delay expires.
- **Immediate actions:** Limited-impact operations (for example, setting rate limits) can be applied immediately by qualified voters.
- **Proposals:** The contract stores proposals by hash (keccak256 of a typed string plus the calldata). The `propose` helper sets a deadline (current time + delay days). `enact` verifies the proposal exists and that its deadline has passed, then deletes it and emits `ProposalEnacted`.

**Structs & events (summary)**

- `RemotePoolUpdate { bool add; uint64 chain; bytes poolAddress }` — describes adding/removing a remote pool. `chain` is the CCIP ChainID. `poolAddress` has to be the abiEncoded remote pool address.
- `ITokenPool.ChainUpdate` — full chain configuration used when adding a chain (see contract for fields).
- `RateLimiter.Config { bool isEnabled; uint128 capacity; uint128 rate }` — rate limit settings.

---

**proposeRemotePoolUpdate(RemotePoolUpdate update, address[] helpers)**

- Purpose: Propose adding or removing a specific remote pool. The proposal stores a hash of the update and sets a 7-day delay before it can be enacted.
- Who can call: Any qualified voter (checked with `helpers`).
- Outcome: Emits `RemotePoolUpdateProposed(bytes32 hash, address indexed proposer, RemotePoolUpdate update)`.

**applyRemotePoolUpdate(RemotePoolUpdate update)**

- Purpose: Enact a previously proposed remote pool update after the proposal delay has elapsed.
- Behavior: On enactment the token pool will either add or remove the remote pool and the contract emits `RemotePoolAdded` or `RemotePoolRemoved`.

---

**applyRateLimit(uint64 chain, RateLimiter.Config inbound, RateLimiter.Config outbound, address[] helpers)**

- Purpose: Immediately set inbound and outbound rate limits for a remote chain.
- Who can call: Any qualified voter (checked with `helpers`).
- Rationale: Rate limits are low-risk emergency controls and are therefore applied immediately without a proposal delay.
- Outcome: Updates the token pool's rate limiter config and emits `RateLimit(uint64 remoteChain, RateLimiter.Config inboundConfigs, RateLimiter.Config outboundConfig)`.

---

**proposeRemoveChain(uint64 chainId, address[] helpers)**

- Purpose: Propose removing a remote chain from the token pool configuration. Creates a proposal hash and a 7-day delay.
- Who can call: Any qualified voter (checked with `helpers`).
- Outcome: Emits `RemoveChainProposed(bytes32 hash, address indexed proposer, uint64 chain)`.

**applyRemoveChain(uint64 chainId)**

- Purpose: Enact a prior remove-chain proposal after the delay. Removes the chain from the token pool configuration and emits `ChainRemoved`.

---

**proposeAddChain(ITokenPool.ChainUpdate config, address[] helpers)**

- Purpose: Propose adding a new remote chain configuration. Creates a proposal hash and a 7-day delay.
- Who can call: Any qualified voter (checked with `helpers`).
- Outcome: Emits `AddChainProposed(bytes32 hash, address indexed proposer, ITokenPool.ChainUpdate update)`.

**applyAddChain(ITokenPool.ChainUpdate config)**

- Purpose: Enact a prior add-chain proposal after the delay. Applies the chain configuration to the token pool and emits `ChainAdded`.

Notes on `ITokenPool.ChainUpdate` and rate limits:

- `ChainUpdate` includes the remote chain selector, remote pool addresses, remote token address, and separate inbound/outbound `RateLimiter.Config` settings.
- `RateLimiter.Config` controls whether rate limiting is enabled and the numeric capacity and refill rate.

---

**proposeAdminTransfer(address newAdmin, address[] helpers)**

- Purpose: Propose transferring administrative control (both the token registry admin role and token pool ownership) to `newAdmin`.
- Who can call: Any qualified voter (checked with `helpers`).
- Delay: 21 days.
- Outcome: Emits `AdminTransferProposed(bytes32 hash, address indexed proposer, address newAdmin)`.

**applyAdminTransfer(address newAdmin)**

- Purpose: Enact a prior admin-transfer proposal after the delay. Transfers the admin role in the token registry and transfers token pool ownership (if set). Emits `AdminTransferred`.

---

**deny(bytes32 hash, address[] helpers)**

- Who can call: Any qualified voter (checked with `helpers`).
- Purpose: Allows any qualified voter to cancel a pending proposal by its hash. Removes the proposal entry and emits `ProposalDenied(bytes32 hash)`.

## Bridged Governance

Any user willing to pay the gas and ccip fees can send a sync message to any chain.

**BridgedGovernance (receiver)**

- Purpose: Receive governance sync messages from the mainnet governance contract via CCIP and update local voting state.
- Mechanism: Decodes a `SyncMessage` (totalVotes + array of `SyncVote`), updates `_totalVotes`, updates per-address `_votes`, and applies any delegated relationships (`delegate(...)`). Emits `MessageReceived`.
- Role: Local chains use this synchronized state to determine which addresses are "qualified" (veto power) for governance actions. `CCIPAdmin` calls `GOVERNANCE.checkQualified(...)` to gate proposal and deny functions.

**BridgedGovernanceSender (sender / tooling)**

- Purpose: On the mainnet side (or central publisher), batches and sends governance sync payloads to one or more bridged chains.
- Mechanism: Exposes `syncVotes` and variants that allow to push updates in bulk. `getSyncFee(...)` helpers that consult the CCIP router for fees.

## Leadrate (interest rate) propagation

**LeadrateSender (sender)**

- Purpose: Publish the current platform lead rate to bridged chains via CCIP.
- Mechanism: `pushLeadrate` has bulk and single-target variants, ensures local pending rate changes are applied. `getCCIPFee(...)` computes required routing fees.

**BridgedLeadrate (receiver)**

- Purpose: Receive lead rate updates from the canonical mainnet leadrate contract and update local rate state.
- Mechanism: Decodes a `uint24` rate, and calls `updateRate(newRate)`. `AbstractLeadrate` implements rate-change scheduling, `nextChange`, and the tick accounting logic.

**BridgedSavings**

- Purpose: Provide savings functionality on bridged chains using the bridged leadrate.
- Mechanism: `BridgedSavings` composes `AbstractSavings` (savings accounting) with `BridgedLeadrate` (rate updates via CCIP).

---
