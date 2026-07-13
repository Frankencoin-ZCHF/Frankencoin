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

### \#005 ERC-4626 Spec Violations in FPS2MintRedeem

- **Status**:
  - [X] Code Change
  - [X] Specification Change
  - [ ] Process Change
  - [ ] Risk Accepted
  - [ ] No Issue
  - [ ] Other:
- **Description of changes**:
5. Check FPS1.canRedeem(..) in FPS2.redemptionsEnabled().
6. Regarding convertToShares(), we argue that FPS1.price() *IS* the current price of FPS1, and not an approximation.
It is true that the price calculation involves flooring the last significant digit. But that does not mean that the returned price is
not the true price, it just means that the definition of the current price includes the price being rounded down after 18 digits.
The comment on Equity.price() was adjusted accordingly.
- **Commit hash (if applicable)**: 2a3807dec7b01d78d3b869085c4989ad2d0397e4, 8c8d1b59408f8575223fb04d8f5e478026aad5fb

---

### \#018 Outdated and Incorrect Documentation Comments

- **Status**:
  - [X] Code Change
  - [ ] Specification Change
  - [ ] Process Change
  - [ ] Risk Accepted
  - [ ] No Issue
  - [ ] Other:
- **Description of changes**: Fixed the comment.
- **Commit hash (if applicable)**: 8c8d1b59408f8575223fb04d8f5e478026aad5fb

---

### \#021 FPS2MintRedeem Mishandles Vault-Specific Limits, Violating ERC-4626

- **Status**:
  - [X] Code Change
  - [X] Specification Change
  - [ ] Process Change
  - [ ] Risk Accepted
  - [ ] No Issue
  - [ ] Other:
- **Description of changes**:
1. Fixed previewRedeem: now ignoring whether redemptions are actually enabled.
2. Aligned maxWithdraw to new specs: maximum that can be withdrawn through a single withdraw call is 10% of the total supply. Also considers redemptionsEnabled().
3. Conscious "soft" spec violation with previewWithdraw. Claude tells me: "Pragmatic status quo, documented. Keep previewWithdraw reverting at the same hi = totalSupply/10 bound as withdraw, and rely on the now-correct maxWithdraw as the authoritative ceiling. Many capped 4626 vaults do this and it's widely tolerated; it's a soft deviation, not a correctness bug, as long as maxWithdraw is accurate."
- **Commit hash (if applicable)**: 6a49754bccd89f1eb31051753dde92aeb5199d0e

---

### \#022 Inverted Holding-Duration Check in Unwrap

- **Status**:
  - [X] Code Change
  - [ ] Specification Change
  - [ ] Process Change
  - [ ] Risk Accepted
  - [ ] No Issue
  - [ ] Other:
- **Description of changes**: Fixed
- **Commit hash (if applicable)**: 513547a337ed53ff18098ee2804dd478c19e3b79

---

### \#023 maxRedeem Returns an Amount Instead of a Share Count

- **Status**:
  - [X] Code Change
  - [ ] Specification Change
  - [ ] Process Change
  - [ ] Risk Accepted
  - [ ] No Issue
  - [ ] Other:
- **Description of changes**: Now returning the number of shares the user can redeem, and not the ZCHF proceeds from the redemption. This is either the user's balance or 0.
- **Commit hash (if applicable)**: 6a49754bccd89f1eb31051753dde92aeb5199d0e

---

### \#024 `totalAssets()` Reverts Once FPS2 Owns Nearly the Entire FPS1 Supply

- **Status**:
  - [X] Code Change
  - [X] Specification Change
  - [ ] Process Change
  - [ ] Risk Accepted
  - [ ] No Issue
  - [ ] Other:
- **Description of changes**: Good catch! I've moved to a new definition of totalSupply that is equally defensible as the previous one and not subject to the 0.3% fee.
- **Commit hash (if applicable)**: 4465483913c6b43580cc222290056b3d2e45da3e

---

### \#026 previewMint of Zero Shares Returns a Positive ZCHF Amount

- **Status**:
  - [ ] Code Change
  - [ ] Specification Change
  - [ ] Process Change
  - [X] Risk Accepted
  - [ ] No Issue
  - [ ] Other:
- **Description of changes**: No change needed. This function always returns a marginal amount more than actually needed in order to always conform to the 4626 standard. Returning 0.0001 when the optimial result is 0.0000 is equally wrong as returning 7.0001 when the optimal result is 7.0000.
- **Commit hash (if applicable)**:

---

### \#027 Unused Variable in MainnetVotes

- **Status**:
  - [ ] Code Change
  - [ ] Specification Change
  - [ ] Process Change
  - [ ] Risk Accepted
  - [ ] No Issue
  - [ ] Other:
- **Description of changes**: Fixed
- **Commit hash (if applicable)**: e6ae81f3af9591bdb6803d9b1eb72bb6387616aa

---

### \#028 `denyUnannouncedMinter` Can Be Disabled

- **Status**:
  - [X] Code Change
  - [ ] Specification Change
  - [ ] Process Change
  - [ ] Risk Accepted
  - [ ] No Issue
  - [ ] Other:
- **Description of changes**: Fixed by clearing on veto.
- **Commit hash (if applicable)**: 8b18c1349ab26f194e01de58c64045931c6bda44

---

### Further changes

In order to allow for a smoother transition from FPS2 to a potentially future FPS3, we relaxed the 'binding' restriction on 
the unwrap function. Now, unwrapping is still possible after the contract became binding for those that have an above average
holding duration.

### Notes

You write in Trust Model: "We assume FPS2 holders that own 51% of the total voting power in the FPS2 contract always behave in the
best interests of the system." Can we refine that to "We assume that there is no malicious FPS2 holder or malicious group of FPS2
holders that collectively have more than 50% of the voting power after FPS2 became binding."