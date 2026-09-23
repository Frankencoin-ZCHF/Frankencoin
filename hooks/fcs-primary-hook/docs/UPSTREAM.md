# Upstream provenance and narrow adaptation

Base architecture: `Uniswap/v4-hooks-public` commit `e4eabe526f9b516fff78d98ba781251747f0fd6e`.
`src/base/BaseTokenWrapperHook.sol` is a local MIT-licensed copy of the upstream file.
The exact delta is preserved in `base-wrapper.patch`:

1. Import `BaseHook` from the pinned upstream dependency instead of a sibling file.
2. Add `virtual` to `_beforeInitialize` so the derived hook can enforce canonical tick spacing.
3. Add `virtual` to `_beforeSwap` so the derived hook can enforce mandatory minOut/deadline and input-credit checks for **all** callers.
4. Add a provenance comment. No base accounting, permission or conversion logic was changed.

The upstream `_beforeSwap` is nonvirtual and does not forward sender/hookData into `_deposit`/`_withdraw`. An initial exclusively authorized convenience-router design prevented aggregator integration. The minimal adaptation allows a permissionless hook without an unguarded user path. Both exact-output branches remain explicitly disabled by the derived hook; no incomplete inverse preview implementation is enabled.

The existing deployed FCS contract and its vendored source are **unmodified**. FCS primary deposit/redeem semantics, votes, age rules, binding conditions and discounts are preserved. Test fixtures compile source at the same commit independently; the fork tests use actual deployed bytecode, not a local recompile substituted into the fork.

All exact dependency revisions and installation paths are in `dependencies.lock.json`. `scripts/bootstrap_dependencies.py` fetches those exact GitHub commit snapshots, verifies any existing file is identical rather than overwriting it, and records archive SHA-256 hashes in `evidence/dependency-downloads.json`. It extracts regular source/license files only. Release bundles may include those files directly; no `.git` directory is required to build/test.

First-party files use MIT. Each vendored component retains its SPDX identifier and upstream license files, including the Uniswap core license terms. Do not infer a blanket first-party MIT relicensing of all dependencies.
