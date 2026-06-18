# Response to Preliminary Report

We hope that the preliminary report provided understandable and helpful feedback. During the upcoming engagement phase we will review your resulting modifications. To make this process as efficient as possible and to avoid potential miscommunication, we have prepared the following response document.

Using this document you can:

- Provide feedback if you feel that any of our findings were (partially) unjustified.
- Document the modifications you are making along with corresponding commits.
- Highlight findings that you plan not to address.
- Respond to open questions that were mentioned in the report.

In case any parts of the report, this form or the overall process are unclear, please reach out at any time to schedule a call. This document is for internal use only.

Please note that your descriptions may be included verbatim in the final report.

## Assessment overview review

Please carefully review the Assessment Overview section of the report. This section is the summary of our understanding of the system and scope of the audit. We described the components, functions, and capabilities of the system to the best of our knowledge. In case there are differences of our understanding and your own understanding, please describe them here:

- [Add the differences here]

Without any requests for changes, we assume the assessment overview to be accepted from your end as accurate.

## System Considerations review

Please carefully review the System Considerations section of the report. This section highlights observations for the system that are not necessarily issues. The topics included are intended to clarify or support the report and do not require modifications to the project. Instead, they aim to raise awareness and improve overall understanding for both users and developers.

If there are any discrepancies between our understanding and your own, please outline them below:

- [Add any differences here]

If everything is correct please mark this section with ACCEPTED.

## Possible status messages

For each finding below, mark the applicable status by placing an `x` in the corresponding checkbox, e.g. `[x]`. The available statuses are:

- **Code Change** – The issue was resolved through a code change. Please provide a brief description of the approach and the commit hash.
- **Specification Change** – The issue was resolved through a specification change. Please reference the change.
- **Process Change** – The issue was addressed using a modified business process. Please explain the modification.
- **Risk Accepted** – The associated risk was deemed small enough that no modification is necessary. No change will be made.
- **No Issue** – The reported issue was incorrect. No change will be made.
- **Other** – None of the above apply. Please provide a description.

## New system state

Please provide **the final commit hash** that includes all modifications made and should be considered as new version:

- [Add the final commit here]

## Findings

### \#001 Shoot Enables Governance Takeover and Unlimited Minting

- **Status**:
  - [X] Code Change
  - [X] Specification Change
  - [ ] Process Change
  - [ ] Risk Accepted
  - [ ] No Issue
  - [ ] Other:
- **Description of changes**: Moved 'binding' level to 66% (two thirds). Prevents this type of attack in combination with #004.

- **Commit hash (if applicable)**: 3818cb8c60ef1e7856fdaa0f4ca3ef720384f9ec, db291347951e340d541d8b24db4bd6f39d1d5812

---

### \#002 Discount Computation Uses Incorrect totalSupply

- **Status**:
  - [X] Code Change
  - [ ] Specification Change
  - [ ] Process Change
  - [ ] Risk Accepted
  - [ ] No Issue
  - [ ] Other:
- **Description of changes**: Measure total supply before computing discount.
- **Commit hash (if applicable)**: 66d5b88c3687569f70b3a3f706dcc51bdd8beb04

---

### \#003 FPS2 Governance Address DoS

- **Status**:
  - [ ] Code Change
  - [ ] Specification Change
  - [ ] Process Change
  - [X] Risk Accepted
  - [ ] No Issue
  - [ ] Other:
- **Description of changes**: If someone frontruns the FPS2 deployment, we will simply repeat it and treat the first successful deployment as the one we move into. And when deploying Frankencoin to new L2 chains in the future, it should be done in an adjusted version without the baggage of the old versions. And that adjusted version can look at FPS2 votes explicitely without having to rely on any delegations.
- **Commit hash (if applicable)**:

---

### \#004 Free Wrap/unwrap Round-Trips Can Delay FPS2 Binding Forever

- **Status**:
  - [x] Code Change
  - [x] Specification Change
  - [ ] Process Change
  - [ ] Risk Accepted
  - [ ] No Issue
  - [ ] Other:
- **Description of changes**: Prevent arbitrary reduction of the holding duration of FPS tokens held by the FPS2 contract. Redemption is restricted to be done while FPS2 is binding and unwrapping is only allowed for those that held their FPS2 for an above average duration. This ensures that FPS2 voting power in the FPS layer cannot be pushed below 66% by a malicious actor.

- **Commit hash (if applicable)**: db291347951e340d541d8b24db4bd6f39d1d5812

---

### \#005 ERC-4626 Spec Violations in FPS2MintRedeem

- **Status**:
  - [ ] Code Change
  - [ ] Specification Change
  - [ ] Process Change
  - [ ] Risk Accepted
  - [ ] No Issue
  - [ ] Other:
- **Description of changes**: I agree that "convertToAssets" should probably be based on the raw underlying price. However, "totalAssets" should probably not overstate the amount of Frankencoins that are in the equity pool. Replaced binary search for mint operation with explicit calculation that slightly overshoots to guarantee the desired amount.
- **Commit hash (if applicable)**: 6b84ed425e0634c7d23d55faca6ab966d8c70655

---

### \#006 Arbitrarily Old Vote Snapshots Can Be Applied

- **Status**:
  - [ ] Code Change
  - [ ] Specification Change
  - [ ] Process Change
  - [X] Risk Accepted
  - [ ] No Issue
  - [ ] Other:
- **Description of changes**: The risk is accepted under the assumption that it is more expensive for an attacker to initiate a stuck sync on mainnet than it is to manually executed the sync on the L2 chain in order to flush out the intentionally stuck messages. The defense against such an attack would therefore be to watch the blockchain for stuck sync messages and flush them once detected.
- **Commit hash (if applicable)**:

---

### \#007 Binary Search Assumes Monotonicity of Effective Proceeds

- **Status**:
  - [X] Code Change
  - [X] Specification Change
  - [ ] Process Change
  - [ ] Risk Accepted
  - [ ] No Issue
  - [ ] Other:
- **Description of changes**: Limit the amount of shares that can be redeemed at once to 10% and revert if amounts above that are requested. Note that binary search always finds a result on a continuous curve as long as the low point starts below and the high point starts above the target. It does not need to be monotone. There is just no guarantee that it finds the first solution of there are multiple valid values.
- **Commit hash (if applicable)**: 2f1bb1e1fd5f3beed3a8d9f887c6308d4a8bbe89

---

### \#008 GovernanceFactory Does Not Implement Correct Interface, Blocking FPS2 Deployment

- **Status**:
  - [X] Code Change
  - [ ] Specification Change
  - [ ] Process Change
  - [ ] Risk Accepted
  - [ ] No Issue
  - [ ] Other:
- **Description of changes**: Fixed IGovernanceFactory and reference in FPS2 to match implementation.
- **Commit hash (if applicable)**: e57d91ec5b49894c33585ce9a01363f6bd9d4f62

---

### \#009 MutualDestruction Event Reports Cumulative Votes Instead of the per-Target Amount

- **Status**:
  - [X] Code Change
  - [ ] Specification Change
  - [ ] Process Change
  - [ ] Risk Accepted
  - [ ] No Issue
  - [ ] Other:
- **Description of changes**: Emitting correct variable.
- **Commit hash (if applicable)**: 731391e6ed8d35fc89546159ae6b2aceb00b4985

---

### \#010 Redemption Discount Recovers Slower than Intended

- **Status**:
  - [ ] Code Change
  - [X] Specification Change
  - [ ] Process Change
  - [ ] Risk Accepted
  - [ ] No Issue
  - [ ] Other:
- **Description of changes**: This indeed wasn't intended, but accepting this behavior is simpler than devising a new calculation method. In an extreme scenario, under which there are continuous redemptions, the linear decay becomes de facto exponential and the "recentlyRedeemed" variable is twice as high in the steady state. For example, if there is 1 FPS2 redeemed per 10 minutes and a week is assumed to have 10'000 minutes, the steady state of "recentlyRedeemed" lands at 1000 (exponential decay) instead of 500 (linear decay). This is ok and means that in times of frequent redemptins, a full recovery will take longer. However, in the short run, the difference is relatively small, so the initial recovery after a large event looks similar as before, even if it is followed by a stream of smaller redemptions.
- **Commit hash (if applicable)**:

---

### \#011 totalAssets Counts Unredeemable FPS1

- **Status**:
  - [ ] Code Change
  - [ ] Specification Change
  - [ ] Process Change
  - [X] Risk Accepted
  - [ ] No Issue
  - [ ] Other:
- **Description of changes**: I think one could argue either way. If the FPS2 contract has excess FPS1, these could still be counted as "managed" as they are under the control of the FPS2 contract. Similarly, when an FPS2 holder accidentally sends them to an invalid address, they also become "unredeemable", but are still counted. I tend not to change unless there is clear wording in the ERC-4626 specification to cover this case.
- **Commit hash (if applicable)**:

---

### \#012 Very Large Redemptions Can Reach Negative Marginal Price

- **Status**:
  - [ ] Code Change
  - [ ] Specification Change
  - [ ] Process Change
  - [X] Risk Accepted
  - [ ] No Issue
  - [ ] Other:
- **Description of changes**: A warning should be shown in the frontend, telling the users that multiple small redemptions can yield a better outcome than one giant redemption. Afterwards, it is in the responsibility of the user to decide on how much to redeem at once.
- **Commit hash (if applicable)**:

---

### \#013 `shoot()` Does Not Explicitly Reject FPS2 as Target

- **Status**:
  - [x] Code Change
  - [ ] Specification Change
  - [ ] Process Change
  - [ ] Risk Accepted
  - [ ] No Issue
  - [ ] Other:
- **Description of changes**: Explicit check added.

- **Commit hash (if applicable)**: b3f7ded3aab77e745e19b6be58257d54ac776218

---

### \#014 Abstract Leadrate Does Not Inherit ILeadrate

- **Status**:
  - [X] Code Change
  - [ ] Specification Change
  - [ ] Process Change
  - [ ] Risk Accepted
  - [ ] No Issue
  - [ ] Other:
- **Description of changes**: Let AbstractLeadrate implement ILeadrate
- **Commit hash (if applicable)**: 2c19df3796cd792070f18dd2a7980596f08d05a8

---

### \#015 Application Fee Check Is Misleading

- **Status**:
  - [X] Code Change
  - [ ] Specification Change
  - [ ] Process Change
  - [ ] Risk Accepted
  - [ ] No Issue
  - [ ] Other:
- **Description of changes**: Adjusted reward pool logic and increased application fee to 1200 ZCHF
- **Commit hash (if applicable)**: 96b7344383c4efb0f912f0b07564a0bd95840656

---

### \#016 Inconsistent Function Naming

- **Status**:
  - [X] Code Change
  - [ ] Specification Change
  - [ ] Process Change
  - [ ] Risk Accepted
  - [ ] No Issue
  - [ ] Other:
- **Description of changes**: Renamed deposit(uint256 amount, uint256 expectedShares) to depositExpected.
- **Commit hash (if applicable)**: bf8fa337ae415a73ea7eac806a9a67ce21a47d2f

---

### \#017 Non-Indexed Event Parameters

- **Status**:
  - [X] Code Change
  - [ ] Specification Change
  - [ ] Process Change
  - [ ] Risk Accepted
  - [ ] No Issue
  - [ ] Other:
- **Description of changes**: Added 'indexed' to addresses in events.
- **Commit hash (if applicable)**: 92cce60ea6a155e859edd09f3f41ee06be04dd0a

---

### \#018 Outdated and Incorrect Documentation Comments

- **Status**:
  - [X] Code Change
  - [ ] Specification Change
  - [ ] Process Change
  - [ ] Risk Accepted
  - [ ] No Issue
  - [ ] Other:
- **Description of changes**: Updated.
- **Commit hash (if applicable)**: 92cce60ea6a155e859edd09f3f41ee06be04dd0a

---

### \#019 Unused Error

- **Status**:
  - [X] Code Change
  - [ ] Specification Change
  - [ ] Process Change
  - [ ] Risk Accepted
  - [ ] No Issue
  - [ ] Other:
- **Description of changes**: Removed unused error.
- **Commit hash (if applicable)**: 92cce60ea6a155e859edd09f3f41ee06be04dd0a

---

### \#020 Unused Imports

- **Status**:
  - [X] Code Change
  - [ ] Specification Change
  - [ ] Process Change
  - [ ] Risk Accepted
  - [ ] No Issue
  - [ ] Other:
- **Description of changes**: Removed unused imports.
- **Commit hash (if applicable)**: 92cce60ea6a155e859edd09f3f41ee06be04dd0a

---

## Open Questions

### OQ1 Cross-Chain Transfer Reference String Not Included in CCIP Message

- **Response to open question**: This is intended. The purpose of the reference is to be able to allow accountants to attribe a transfer to an invoice. It is not necessary to have it emitted on both ends in case of a cross-chain transaction.
- **Description, in case of resulting changes**:
- **Commit hash (if applicable)**:

---

### OQ2 Disallow Local Delegation in BridgedVotes?

- **Response to open question**: Can be useful for administrative work, let's keep it. Also, when in doubt, we keep prefer to not change anything.
- **Description, in case of resulting changes**:
- **Commit hash (if applicable)**:

---

### OQ3 Should Rate Limit Increases via FPS2 Governance Be Delayed?

- **Response to open question**: Yes, this absolutely makes sense. However, since we have already reached the byte size limit for the GovernanceFactory, we decided to implement that change independently through a general update of the CCIPAdmin module. This update would make both the old deployed CCIPAdmin modules obsolete as well as the new CCIPGovernance.
- **Description, in case of resulting changes**:
- **Commit hash (if applicable)**:

---

### OQ4 Should Slippage-Protected Overloads Support All Original Parameters?

- **Response to open question**: Yes. Added 'receipient' to depositExpected. However, did not add 'owner' for simplicity.
- **Description, in case of resulting changes**:
- **Commit hash (if applicable)**:

---
