// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IHookStats
/// @author Uniswap Labs
/// @notice Reserves-and-liquidity metadata surface for hooks that custody off-pool assets. Lets
///         routers and aggregators (e.g. the ALFMultiplexer) read a hook's total value under
///         management and its immediately-deliverable liquidity to size fills and bound slippage.
/// @dev    Advertised and discovered via ERC-165 (`supportsInterface`); callers query it through
///         `staticcall`. It is a read-only signal, not a binding commitment: the amounts may drift
///         between the query and execution so consumers MUST treat them as non-binding and enforce
///         their own execution-time bounds. Hooks that hold no off-pool reserves (e.g. native LP
///         quoters) return `(0, 0)` from both functions. The pairing carries one invariant:
///         `getEffectiveLiquidity(key) <= getReserves(key)` on each side.
/// @custom:security-contact security@uniswap.org
interface IHookStats is IERC165 {
    /// @notice Total reserves managed by the hook (true TVL).
    /// @dev Should include all assets under management: ERC-20 balances, ERC-6909 claims,
    ///      vault deposits, rehypothecated assets, etc. Returns (0, 0) for hooks that do
    ///      not manage off-pool reserves. This is the gross economic stake and MAY exceed what is
    ///      immediately withdrawable (see {getEffectiveLiquidity}).
    /// @param key The pool key for the specific pool.
    /// @return token0 Total amount of token0 reserves, in token0's native decimals.
    /// @return token1 Total amount of token1 reserves, in token1's native decimals.
    function getReserves(PoolKey calldata key) external view returns (uint256 token0, uint256 token1);

    /// @notice Assets available for immediate swapping.
    /// @dev Returns liquidity that can be accessed right now for trading. Always <= getReserves().
    ///      May differ from getReserves() if some liquidity is not available for deployment (e.g., from a vault with too much utilization).
    ///      Returns (0, 0) for hooks that do not manage off-pool reserves.
    ///      Implementations SHOULD report fee-net, immediately-deliverable reserves: consumers (such as
    ///      the ALFMultiplexer's reserve-bounded strict-tolerance baseline) treat the returned value as
    ///      the deliverable output cap, a bound that is only sound when reserves are net of the fee a swap
    ///      pays. An over-reported (gross) value weakens those consumers' deliverability bounds, which is
    ///      part of the trusted-targets assumption such consumers make.
    /// @param key The pool key for the specific pool.
    /// @return token0 Immediately swappable token0 liquidity, in token0's native decimals.
    /// @return token1 Immediately swappable token1 liquidity, in token1's native decimals.
    function getEffectiveLiquidity(PoolKey calldata key) external view returns (uint256 token0, uint256 token1);
}
