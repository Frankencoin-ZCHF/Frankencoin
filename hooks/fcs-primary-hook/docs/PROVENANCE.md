# Deployed FCS verification

Target supplied by the user, preserved exactly: `0xdb861830d9ae2d1fcf99fa0cfd3973de382b0b5b`, Ethereum chain 1. This is not assumed from a repository branch.

- Sourcify API: `https://sourcify.dev/server/v2/contract/1/0xdb861830d9ae2d1fcf99fa0cfd3973de382b0b5b?fields=all`.
- Exact **creation** and **runtime** match, nonproxy, Solidity `0.8.24+commit.e11b9ed9`, optimizer 200, Paris target.
- Deployment block **25852506**, transaction `0x5b7df19db201535b1a10f3e30a9d343cf2f78fcc645d059b6f5f3b84aeee70ec`.
- The 11 verified FCS source files match the pinned Frankencoin commit `8b4c4ab67bb361b91d58c474b87f4608fc4c0566` byte-for-byte. Their hashes and equality results are in `evidence/evidence-summary.json`; the files are under `evidence/deployed-contracts/`.
- Independent `eth_getCode` at block **26038677** matches the Sourcify onchain runtime exactly. FCS runtime Keccak-256: `0x9dacc056e5f2d59b75a9c9ae8a3cd5134abf7bfb675462f50c12ab777603cc62`.
- Underlying `asset()` / `ZCHF()`: `0xB58E61C3098d85632Df34EecfB899A1Ed80921cB`.
- `FPS1()`: `0x1bA26788dfDe592fec8bcB0Eaff472a42BE341B2`.
- At that block both `isBinding()` and `FPS1.canRedeem(FCS)` are false. The positive one-share preview is **not executable availability**. Golden preview vectors are in `evidence/quote-vectors.json`.

The exact block hash is `0x2a3b91922e5d86cc8b1b4496422e8b211dadf0fecf54f2c78ef2b9d3c2421863`.
The actual deployed v4 PoolManager comes from the official deployment list:
`https://docs.uniswap.org/contracts/v4/deployments`.
Its address is `0x000000000004444c5dc75cB358380D2e3dE08A90`; runtime hash at the pinned block:
`0x785f1014552b7ce7d5fb7d0c970ca60edee94fd00425d7ca21609acac7ce1293`.
The fork tests assert both runtime hashes and the underlying/reserve identities.

A read-only standard-library reproducer is included:

```sh
python3 scripts/verify_fcs_deployment.py --rpc https://eth-mainnet.public.blastapi.io --block 26038677
```

It queries Sourcify, Ethereum chain ID, the exact block, code, asset, reserve and gates; it has no wallet or signing/submission capability. The pinned block is historical, so the RPC must serve archive state; `ethereum-rpc.publicnode.com` (the original default) stopped doing so and the defaults were switched to `eth-mainnet.public.blastapi.io`, which served the block on 2026-09-23. Original verification was independently supplied by the parent review, with fresh mainnet fork assertions executed in this project. Etherscan returned HTTP 403; Sourcify exact matching plus direct RPC verified the deployment without it. The verified FCS's compiler target differs intentionally from this v4 hook project's Cancun compiler configuration.
