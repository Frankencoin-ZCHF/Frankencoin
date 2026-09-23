// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SpreadQuoterBase} from "./base/SpreadQuoterBase.sol";

/// @title SimpleSpreadQuoterHook
/// @author Uniswap Labs
/// @notice Spread quoter with owner-restricted LP. Only authorized addresses can add or
///         remove liquidity, and all LP must be concentrated in a single tick spacing at
///         the active tick. Owner controls pricing via a single symmetric fee override.
///
///         ## Trust model: `authorizedLPs` is operator-only, not a public LP allowlist
///
///         `authorizedLPs` is designed as an allowlist of addresses controlled by a single
///         trust principal (the operator), not as a registry of independent third-party LPs.
///         Typical configurations: a treasury contract + an algorithmic-execution hot wallet;
///         a multisig + a routine-operations EOA; a primary and a backup. All entries are
///         expected to be in coordination with one another.
///
///         The hook does not track per-LP positions. Two consequences follow:
///
///           1. **Revocation locks the revoked LP's outstanding funds.** If LP A holds a v4
///              position in this pool and the owner calls `setAuthorizedLP(A, false)`, A's
///              subsequent `removeLiquidity` reverts at `_beforeRemoveLiquidity`'s
///              authorization check. A's funds remain locked until re-authorization. Owners
///              MUST sequence "drain then revoke" when retiring an LP address.
///
///           2. **`setActiveTick` enforces drain-before-relocate.** The base now refuses to
///              move `activeLowerTick` while liquidity is still referenced at the prior band
///              (reverts with `ActiveTickBandNonEmpty`). Operators MUST have the authorized
///              LP remove its position at the old tick before calling `setActiveTick` with a
///              different value. Setting the same tick remains an idempotent no-op.
///
///         Use cases that need genuine multi-tenant LP (independent users supplying
///         liquidity, hook manages spread) are out of scope for this contract and would
///         require a separate hook with per-LP position tracking.
/// @dev    This is not intended as a production-ready hook. It is a reference implementation
///         designed to demonstrate the core mechanics of a spread-based quoter where LP is
///         controlled by a single owner. Although it may work for simple use cases, it is not
///         expected to be used in production as-is.
/// @custom:security-contact security@uniswap.org
contract SimpleSpreadQuoterHook is SpreadQuoterBase {
    /// @notice Whether an address is authorized to add or remove pool liquidity.
    mapping(address => bool) public authorizedLPs;

    /// @notice Emitted when an LP's authorization is granted or revoked by the owner.
    /// @param lp         The LP address whose authorization changed.
    /// @param authorized True if the LP can now add/remove liquidity, false if revoked.
    event AuthorizedLPUpdated(address indexed lp, bool authorized);

    /// @dev Caller is not in the `authorizedLPs` allowlist.
    error UnauthorizedLP();

    /// @param _poolManager The Uniswap v4 PoolManager.
    /// @param maxGas_      Gas budget declared for `getIndicativeQuote` staticcalls.
    /// @param owner_       Initial contract owner (Ownable2Step).
    constructor(IPoolManager _poolManager, uint32 maxGas_, address owner_)
        SpreadQuoterBase(_poolManager, maxGas_, owner_)
    {}

    // ──── Hook Permissions ────

    /// @notice The v4 hook permissions for this contract.
    /// @dev    `beforeInitialize` blocks direct PM init (forces operator to use
    ///         `initializePool`); `beforeAddLiquidity` / `beforeRemoveLiquidity` enforce the LP
    ///         allowlist; `beforeSwap` enforces the liveness flag. Pricing is fully static
    ///         (`key.fee`); no LP fee override is returned from `_beforeSwap`.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true, // block direct init (force initializePool)
            afterInitialize: false,
            beforeAddLiquidity: true, // LP authorization + tick enforcement
            beforeRemoveLiquidity: true, // LP authorization
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // liveness check (no fee override; static key.fee)
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ──── LP Gating ────

    /// @dev Reverts {UnauthorizedLP} unless `sender` is an authorized LP. The guard for both LP
    ///      callbacks, so the authorization check stays in one place rather than inlined per site.
    function _requireAuthorizedLP(address sender) private view {
        if (!authorizedLPs[sender]) revert UnauthorizedLP();
    }

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal view override returns (bytes4) {
        _requireAuthorizedLP(sender);
        _enforceActiveTick(key, params);
        return IHooks.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        _requireAuthorizedLP(sender);
        return IHooks.beforeRemoveLiquidity.selector;
    }

    // ──── Owner Functions ────

    /// @notice Authorize or revoke an address for LP operations.
    /// @dev    Only the owner may toggle authorization. Emits {AuthorizedLPUpdated}.
    ///
    ///         **Warning: revocation locks outstanding liquidity.** This contract has no
    ///         per-LP position tracking, so revoking `lp` while `lp` holds a v4 position in
    ///         any pool gated by this hook makes that position un-removable until
    ///         `lp` is re-authorized. Owners MUST sequence revocations as
    ///         "drain (have `lp` remove its positions) then revoke", never the reverse.
    ///         See the contract-level `Trust model` NatSpec for more context on the operator-only
    ///         design intent and the trade-offs involved.
    /// @param lp         The address to authorize or revoke.
    /// @param authorized True to grant LP access, false to revoke.
    function setAuthorizedLP(address lp, bool authorized) external onlyOwner {
        authorizedLPs[lp] = authorized;
        emit AuthorizedLPUpdated(lp, authorized);
    }
}
