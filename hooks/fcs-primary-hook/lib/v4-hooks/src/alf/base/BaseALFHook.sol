// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BaseHook} from "../../base/BaseHook.sol";
import {DeltaResolver} from "@uniswap/v4-periphery/src/base/DeltaResolver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IALFHook, ALFHookData} from "../interfaces/IALFHook.sol";
import {IHookStats} from "../interfaces/IHookStats.sol";

/// @title BaseALFHook
/// @author Uniswap Labs
/// @notice Abstract base contract for ALF hooks. Provides hookData resolution, settlement
///         helpers, and the IALFHook interface. Quoters extend this and implement _price()
///         with their pricing logic.
/// @dev Follows the same BaseHook + DeltaResolver dual-inheritance pattern as BaseTokenWrapperHook.
/// @custom:security-contact security@uniswap.org
abstract contract BaseALFHook is BaseHook, DeltaResolver, IALFHook {
    /// @dev Gas budget declared for `getIndicativeQuote` staticcalls. Returned by `maxGas()`.
    uint32 private immutable _maxGas;

    /// @param _poolManager The Uniswap v4 PoolManager.
    /// @param maxGas_      Gas budget declared for `getIndicativeQuote` staticcalls.
    constructor(IPoolManager _poolManager, uint32 maxGas_) BaseHook(_poolManager) {
        _maxGas = maxGas_;
    }

    // ──── IALFHook ────

    /// @inheritdoc IALFHook
    function maxGas() external view override returns (uint32) {
        return _maxGas;
    }

    /// @notice ERC-165 advertisement for the interfaces this contract implements.
    /// @dev Stateless implementation (no inherited `ERC165` storage). Advertises `IALFHook`,
    ///      `IHooks` (implemented via `BaseHook`), and `IERC165`. Subclasses that implement
    ///      additional interfaces should override this and OR-in their own selectors.
    function supportsInterface(bytes4 interfaceId) public pure virtual returns (bool) {
        return interfaceId == type(IALFHook).interfaceId || interfaceId == type(IHooks).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    /// @inheritdoc IALFHook
    function getIndicativeQuote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bytes calldata hookData)
        external
        view
        virtual
        override
        returns (uint256 outputAmount)
    {
        (bool isAttested, address attester) = _resolveHookData(hookData);
        return _price(key, zeroForOne, amountSpecified, isAttested, attester);
    }

    /// @inheritdoc IALFHook
    function isLive() external view virtual override returns (bool);

    // ──── Reserves (default: no off-pool reserves) ────

    /// @inheritdoc IHookStats
    function getReserves(PoolKey calldata) external view virtual override returns (uint256, uint256) {
        return (0, 0);
    }

    /// @inheritdoc IHookStats
    function getEffectiveLiquidity(PoolKey calldata) external view virtual override returns (uint256, uint256) {
        return (0, 0);
    }

    // ──── Price-bounded simulation (default: unsupported) ────

    /// @inheritdoc IALFHook
    function swapToPrice(PoolKey calldata, bool, int256, uint160, bytes calldata)
        external
        view
        virtual
        override
        returns (uint256, uint256)
    {
        return (0, 0);
    }

    // ──── Internal: HookData Resolution ────

    /// @dev Decode ALFHookData and resolve attestation. The base implementation does not
    ///      verify attestations; subclasses that want attestation support override
    ///      `_resolveAttestation` with their own verification logic.
    function _resolveHookData(bytes calldata hookData) internal view returns (bool isAttested, address attester) {
        if (hookData.length == 0) return (false, address(0));
        ALFHookData memory hd = abi.decode(hookData, (ALFHookData));
        (isAttested, attester) = _resolveAttestation(hd.attestationData);
    }

    /// @dev Resolve attestation from raw bytes. Default returns (false, address(0)).
    ///      Subclasses can override to verify attestationData against their own signer.
    function _resolveAttestation(bytes memory) internal view virtual returns (bool isAttested, address attester) {
        return (false, address(0));
    }

    // ──── Pricing extension point (default: no indicative quote) ────

    /// @dev Indicative pricing backing the default {getIndicativeQuote}. Defaults to 0: the
    ///      IALFHook "cannot price this swap" path. Quoter subclasses override with their curve
    ///      (e.g. `SpreadQuoterBase` simulates against the pool's static fee). Hooks that price
    ///      against bespoke liquidity (e.g. `DualPoolHook`) override `getIndicativeQuote`
    ///      directly instead, leaving this dormant.
    function _price(PoolKey calldata, bool, int256, bool, address) internal view virtual returns (uint256) {
        return 0;
    }

    // ──── DeltaResolver: _pay ────

    /// @inheritdoc DeltaResolver
    /// @dev Pays the PoolManager using v4's `Currency.transfer` rather than OZ `SafeERC20`, by
    ///      design: this matches v4 periphery's `DeltaResolver` convention (the destination is the
    ///      trusted PoolManager during an unlock, and `Currency.transfer` handles native ETH and
    ///      the no-return-value ERC-20 quirk in the same path).
    function _pay(Currency token, address, uint256 amount) internal virtual override {
        token.transfer(address(poolManager), amount);
    }
}
