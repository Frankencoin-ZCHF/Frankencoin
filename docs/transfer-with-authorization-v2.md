# TransferWithAuthorization V2

`TransferWithAuthorizationV2` is an EIP-3009 sidecar for Frankencoin and CCIP-bridged Frankencoin. It adds ERC-7598 `bytes` signature overloads without changing the meaning of the classic EIP-3009 entrypoints.

## Signature semantics

- Classic EIP-3009 `(v, r, s)` overloads are ECDSA-only, even when the signer has code.
- ERC-7598 `bytes` overloads use ECDSA for codeless EOAs and ERC-1271 for addresses with code. Coded accounts do not receive an ECDSA fallback.
- For an EIP-7702 delegated EOA, the classic path therefore continues to check the root-key ECDSA signature, while the bytes path follows the delegated account's ERC-1271 policy.
- V2 requires `v` to be 27 or 28 and rejects high-`s` signatures. This is intentionally stricter than V1's raw `ecrecover` behavior.
- Failed recovery and recovery to the zero address are always invalid.

These two signature paths are an intentional, spec-compatible boundary. Smart accounts should use the ERC-7598 bytes overloads.

The local regression suite exercises the EIP-7702 boundary with a genuine type-4 authorization-list transaction: it delegates an EOA to a rejecting ERC-1271 implementation, confirms that the bytes overload follows that policy, and confirms that the classic overload still accepts the EOA's root-key ECDSA signature. The Solidity `paris` compilation target does not prevent the newer Hardhat network from executing this transaction type.

The EIP-712 domain is `{ name: "Frankencoin", version: "1", chainId, verifyingContract }`. Unlike V1, the name is a compile-time constant and is not read from the configured asset during initialization.

## Deployment and activation

Run a dry run first:

```shell
PRIVATE_KEY=... npx hardhat run scripts/deployTransferWithAuthorizationV2.ts --network <network>
```

Deploy and initialize only after checking the predicted CREATE2 address and asset:

```shell
PRIVATE_KEY=... EXECUTE=true npx hardhat run scripts/deployTransferWithAuthorizationV2.ts --network <network>
```

The script rejects a `PRIVATE_KEY` that does not resolve to the deployer hardcoded in the contract. It deploys through the Arachnid CREATE2 factory and initializes the sidecar with the chain's configured Frankencoin asset.

Deployment and initialization do not activate transfers. The sidecar relies on the token's implicit allowance for approved minters. Complete the governance procedure on each token/chain:

1. Ensure the account submitting the application holds at least `ZCHF.MIN_FEE()`; the token debits the fee directly.
2. Call `ZCHF.suggestMinter(v2Address, ZCHF.MIN_APPLICATION_PERIOD(), ZCHF.MIN_FEE(), "EIP-3009 sidecar V2")`.
3. Allow the full application period to pass without a qualified governance veto.
4. Confirm `ZCHF.isMinter(v2Address) == true`.
5. Exercise a small authorization on that chain before announcing activation.

Until step 4, authorizations cannot use the implicit allowance and will fail at the token transfer.

After a deployment is confirmed, add its actual V2 address to `exports/address.config.ts` and the corresponding address type. Do not publish a predicted or placeholder V2 address as a deployed address.
