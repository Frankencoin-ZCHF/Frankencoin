// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IALFHook} from "../../../src/alf/interfaces/IALFHook.sol";

/// @title MockAdversarialALFHook
/// @notice Bare IALFHook implementation with a revert knob on every metadata surface the
///         multiplexer's tier-1 query path touches (`isLive`, `maxGas`, `getIndicativeQuote`,
///         `getEffectiveLiquidity`). The multiplexer must soft-skip a candidate whose hook
///         misbehaves on any of these calls instead of aborting the whole quote/swap.
///
///         Not a real v4 hook: it is only ever used as a quote-path target (never swapped
///         against), so it carries no hook flags and skips BaseHook address validation.
contract MockAdversarialALFHook is IALFHook {
    bool public revertOnIsLive;
    bool public liveValue = true;
    bool public revertOnMaxGas;
    bool public revertOnQuote;
    uint256 public quoteValue = 1e18;

    error Adversarial();

    function setRevertOnIsLive(bool v) external {
        revertOnIsLive = v;
    }

    function setLiveValue(bool v) external {
        liveValue = v;
    }

    function setRevertOnMaxGas(bool v) external {
        revertOnMaxGas = v;
    }

    function setRevertOnQuote(bool v) external {
        revertOnQuote = v;
    }

    function setQuoteValue(uint256 v) external {
        quoteValue = v;
    }

    // ──── IERC165 ────

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IALFHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    // ──── IALFHook ────

    function isLive() external view override returns (bool) {
        if (revertOnIsLive) revert Adversarial();
        return liveValue;
    }

    function maxGas() external view override returns (uint32) {
        if (revertOnMaxGas) revert Adversarial();
        return 100_000;
    }

    function getIndicativeQuote(PoolKey calldata, bool, int256, bytes calldata)
        external
        view
        override
        returns (uint256)
    {
        if (revertOnQuote) revert Adversarial();
        return quoteValue;
    }

    function swapToPrice(PoolKey calldata, bool, int256, uint160, bytes calldata)
        external
        pure
        override
        returns (uint256, uint256)
    {
        return (0, 0);
    }

    // ──── IHookStats ────

    function getReserves(PoolKey calldata) external pure override returns (uint256, uint256) {
        return (0, 0);
    }

    function getEffectiveLiquidity(PoolKey calldata) external pure override returns (uint256, uint256) {
        return (0, 0);
    }
}
