# Final-source static-analysis triage

Slither was run against production sources compiled with Solidity 0.8.26, excluding test/script/vendor findings. Static analysis is not a security audit. Do not interpret a finding count as a count of exploitable vulnerabilities, or a reviewed warning as proof of safety.

## Arbitrary ERC20 transferFrom

The router callback contains a decoded payer, which triggers arbitrary-send-erc20. The entry point sets payer to msg.sender, commits the entire request hash before unlock, and the callback requires both the immutable PoolManager as caller and an exact matching active request. No public caller-selected payer API exists. Review the victim-allowance and unauthorized-callback regression tests before accepting this as a contextual false positive.

## Balance/reentrancy findings

The hook deliberately measures balances around FCS deposit/redeem and settlement, preserving any pre-existing gifts and checking actual output against the reported amount. The intended deployment uses the verified immutable FCS and its actual ZCHF/FPS dependencies, whose relevant token transfers and primary calls have no arbitrary user callback. This trust assumption is essential: the constructor interface is not a certification of arbitrary ERC4626-like contracts. The bundled router also rejects a second swap while its request hash is active. Re-audit if any dependency or routing design changes.

The router's request hash is cleared only after the synchronous manager unlock callback finishes. Slither does not model this intentional authenticated callback lifecycle; inspect the guard and tests rather than moving the reset before the callback and breaking authorization.

## Other detections

- Strict equality to zero output is an intentional dust-rejection condition, not a dependence on an attacker-controlled exact account balance.
- Timestamp checks implement user deadlines; block timestamps are not used for randomness. The underlying FCS has its own time-dependent protocol mechanics.
- Uppercase getters preserve the upstream FCS ABI and immutable-asset naming.
- Inherited virtual conversion methods are reachable through BaseTokenWrapperHook; detector dead-code reports must not cause removal of live conversion paths.
- Callback complexity reflects explicit settlement, authorization and delta checks; simplify only while preserving those checks.
- The previously reported missing router-constructor zero check is fixed; it is absent from the final scan.

The final scan completed successfully with 25 findings: 7 High, 2 Medium, 4 Low and 12 Informational detector labels. Those are analyzer classifications, not confirmed exploitable defect counts. The 7 High labels comprise one arbitrary-payer warning and six balance/reentrancy warnings discussed above. Raw results and source fingerprints are in evidence/slither-final.json and evidence/slither-source-manifest.json. Do not label this project Slither-clean. Independent security review remains required before funded deployment.
