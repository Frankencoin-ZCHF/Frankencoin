// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHookStats} from "./IHookStats.sol";

/// @notice Standard hookData encoding for ALF hooks.
/// @dev Callers MUST encode hookData as `abi.encode(ALFHookData(...))`.
///      `attestationData` is optional; pass empty bytes when not applicable.
struct ALFHookData {
    bytes attestationData; // ABI-encoded attestation payload, or empty
}

/// @title IALFHook
/// @author Uniswap Labs
/// @notice Standard interface implemented by ALF hooks on top of the v4 hook interface.
/// @dev Provides a uniform way for the router and multiplexer to query indicative quotes
///      and hook metadata. Hooks expose their own capabilities directly rather than
///      relying on a separate registry contract.
/// @custom:security-contact security@uniswap.org
interface IALFHook is IERC165, IHookStats {
    /// @notice Get an indicative quote for routing purposes.
    /// @dev MUST be a view function. Callers invoke via staticcall.
    /// @dev MUST NOT revert under normal conditions. If the quoter cannot
    ///      price the requested swap, it SHOULD return 0.
    /// @dev The returned value is non-binding. The actual execution price
    ///      is determined by the hook's beforeSwap implementation.
    /// @param key The pool key for this quoter's pool.
    /// @param zeroForOne The swap direction.
    /// @param amountSpecified The swap amount. Negative = exact input.
    /// @param hookData ABI-encoded ALFHookData struct, or empty bytes.
    /// @return outputAmount The indicative number of output tokens.
    ///         For exact input swaps, this is the expected output.
    ///         For exact output swaps, this is the required input.
    function getIndicativeQuote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bytes calldata hookData)
        external
        view
        returns (uint256 outputAmount);

    /// @notice Whether this hook is currently live and accepting swaps.
    /// @dev Hooks SHOULD return true if the current curve is not stale.
    /// @dev Consumers SHOULD validate against observed behavior.
    function isLive() external view returns (bool);

    /// @notice The declared maximum gas for getIndicativeQuote execution.
    /// @dev Callers use this to set gas limits on staticcall invocations.
    /// @dev Hooks that exceed their declared maxGas will have their
    ///      getIndicativeQuote calls fail, resulting in router deprioritization.
    function maxGas() external view returns (uint32);

    /// @notice Simulate a swap up to a target price, returning both input consumed and output received.
    /// @dev Used by the multiplexer and router for split fill planning. The swap terminates
    ///      when the target price is reached or the specified amount is exhausted, whichever
    ///      comes first. Returns (0, 0) for hooks that do not support price-bounded simulation.
    /// @param key The pool key for this quoter's pool.
    /// @param zeroForOne The swap direction.
    /// @param amountSpecified The swap amount. Negative = exact input.
    /// @param sqrtPriceLimitX96 The target price (Q64.96). Swap stops when this price is reached.
    /// @param hookData ABI-encoded ALFHookData struct, or empty bytes.
    /// @return amountIn Total input consumed (including fees).
    /// @return amountOut Total output received.
    function swapToPrice(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata hookData
    ) external view returns (uint256 amountIn, uint256 amountOut);
}
