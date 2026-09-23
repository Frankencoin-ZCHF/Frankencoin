// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {BaseAggregatorHook} from "../../BaseAggregatorHook.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Factory} from "./interfaces/IUniswapV2Factory.sol";

/// @title UniswapV2Aggregator
/// @notice Hook that aggregates liquidity from a canonical Uniswap V2 compatible pair resolved via factory.getPair
/// @dev Fee and tickSpacing on PoolKey do not participate in routing; routing is keyed by currency pair only.
contract UniswapV2Aggregator is BaseAggregatorHook {
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    address public immutable factory;

    uint256 public immutable fee;
    uint256 internal constant FEE_DENOMINATOR = 1_000_000;

    mapping(PoolId => address) public poolIdToExternalPair;
    mapping(address => PoolKey) private _canonicalPoolKeyByAddress;

    /// @notice PoolKeys of all pools initialized with this hook, in initialization order
    PoolKey[] internal _initializedPools;

    error NativeCurrencyNotSupported();
    error ExternalPoolNotFound();
    error ExternalPoolMismatch();
    error Reentrancy();
    error UnexpectedSwapOutputDelta();
    error AmountInZero();
    error AmountOutZero();
    error InsufficientLiquidity();
    error PairAlreadyHasCanonicalPool(PoolId existingPoolId);

    constructor(IPoolManager manager, address factory_, uint256 fee_, string memory hookVersion)
        BaseAggregatorHook(manager, hookVersion)
    {
        factory = factory_;
        fee = fee_;
    }

    /// @inheritdoc BaseAggregatorHook
    function pseudoTotalValueLocked(PoolId poolId) external view override returns (uint256 amount0, uint256 amount1) {
        address pairAddr = poolIdToExternalPair[poolId];
        if (pairAddr == address(0)) revert PoolDoesNotExist();
        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pairAddr).getReserves();
        amount0 = uint256(reserve0);
        amount1 = uint256(reserve1);
    }

    function _resolveExternalPool(address token0, address token1) internal view returns (address pool) {
        pool = IUniswapV2Factory(factory).getPair(token0, token1);
        if (pool == address(0)) revert ExternalPoolNotFound();
    }

    /// @notice Returns the raw quote from the underlying liquidity source without protocol fees
    /// @param zeroToOne Whether the swap is from token0 to token1
    /// @param amountSpecified The amount specified (negative for exact-in, positive for exact-out)
    /// @param poolId The pool ID
    /// @return amountUnspecified The raw unspecified amount before protocol fee adjustment
    /// @dev Prices the swap using reserve math (matching canonical V2 getAmountsOut) and does not account for
    ///      fee-on-transfer input tokens. For such tokens the actual output is lower than quoted because the pair
    ///      receives less than the nominal input amount. Integrators that pass the quoted value as a router
    ///      minimum-output check will see the swap revert on shortfall; no funds are lost.
    function _rawQuote(bool zeroToOne, int256 amountSpecified, PoolId poolId)
        internal
        view
        override
        returns (uint256 amountUnspecified)
    {
        address pairAddr = poolIdToExternalPair[poolId];
        if (pairAddr == address(0)) revert PoolDoesNotExist();

        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pairAddr).getReserves();
        (uint256 reserveIn, uint256 reserveOut) =
            zeroToOne ? (uint256(reserve0), uint256(reserve1)) : (uint256(reserve1), uint256(reserve0));

        if (amountSpecified < 0) {
            uint256 amtIn = uint256(-amountSpecified);
            amountUnspecified = getAmountOut(amtIn, reserveIn, reserveOut);
        } else {
            uint256 amtOut = uint256(amountSpecified);
            amountUnspecified = getAmountIn(amtOut, reserveIn, reserveOut);
        }
    }

    /// @notice Number of pools initialized with this hook
    function initializedLength() external view returns (uint256) {
        return _initializedPools.length;
    }

    /// @notice Returns the PoolKey of an initialized pool
    /// @param index The pool index (in initialization order)
    function initialized(uint256 index) external view returns (PoolKey memory) {
        return _initializedPools[index];
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal virtual override returns (bytes4) {
        if (key.currency0.isAddressZero() || key.currency1.isAddressZero()) revert NativeCurrencyNotSupported();
        if (key.fee != fee) revert ExternalPoolMismatch();
        if (key.tickSpacing != 1) revert ExternalPoolMismatch();

        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        address pairAddr = _resolveExternalPool(token0, token1);

        if (IUniswapV2Pair(pairAddr).token0() != token0 || IUniswapV2Pair(pairAddr).token1() != token1) {
            revert ExternalPoolMismatch();
        }

        PoolKey storage existing = _canonicalPoolKeyByAddress[pairAddr];
        if (address(existing.hooks) != address(0)) {
            revert PairAlreadyHasCanonicalPool(existing.toId());
        }
        _canonicalPoolKeyByAddress[pairAddr] = key;

        poolIdToExternalPair[key.toId()] = pairAddr;
        _initializedPools.push(key);

        emit AggregatorPoolRegistered(key.toId());
        pollTokenJar();
        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc BaseAggregatorHook
    function _conductSwap(Currency settleCurrency, Currency takeCurrency, SwapParams calldata params, PoolId poolId)
        internal
        virtual
        override
        returns (uint256 amountSettle, uint256 amountTake, bool hasSettled)
    {
        if (settleCurrency.isAddressZero() || takeCurrency.isAddressZero()) revert NativeCurrencyNotSupported();

        address pairAddr = poolIdToExternalPair[poolId];
        if (pairAddr == address(0)) revert PoolDoesNotExist();

        poolManager.sync(settleCurrency);
        (amountTake, amountSettle) = _swapOnPair(pairAddr, takeCurrency, settleCurrency, params);
        poolManager.settle();
        hasSettled = true;

        if (params.amountSpecified > 0 && uint256(params.amountSpecified) != amountSettle) {
            revert UnexpectedSwapOutputDelta();
        }
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        view
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert AmountInZero();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        uint256 amountInWithFee = amountIn * (FEE_DENOMINATOR - fee);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * FEE_DENOMINATOR + amountInWithFee;
        amountOut = numerator / denominator;
    }

    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        internal
        view
        returns (uint256 amountIn)
    {
        if (amountOut == 0) revert AmountOutZero();
        if (reserveIn == 0 || reserveOut == 0 || amountOut > reserveOut) revert InsufficientLiquidity();
        uint256 numerator = reserveIn * amountOut * FEE_DENOMINATOR;
        uint256 denominator = (reserveOut - amountOut) * (FEE_DENOMINATOR - fee);
        amountIn = numerator / denominator + 1;
    }

    /// @dev Executes Constant-Product swap on `pair`. Pulls input from PoolManager to `pair` via `take`; pair sends output to PoolManager.
    /// @return amountTakeUsed Input amount taken from PoolManager for the pair.
    /// @return amountSettle Output amount sent by the pair to PoolManager (must match `settle` after `sync`).
    function _swapOnPair(address pairAddr, Currency takeCurrency, Currency settleCurrency, SwapParams calldata params)
        private
        returns (uint256 amountTakeUsed, uint256 amountSettle)
    {
        bool zeroForOne = params.zeroForOne;

        (uint112 r0Before, uint112 r1Before,) = IUniswapV2Pair(pairAddr).getReserves();
        (uint256 reserveIn, uint256 reserveOut) =
            zeroForOne ? (uint256(r0Before), uint256(r1Before)) : (uint256(r1Before), uint256(r0Before));
        if (reserveIn == 0 || reserveOut == 0) revert ExternalPoolMismatch();

        uint256 amountOut;
        if (params.amountSpecified < 0) {
            amountTakeUsed = uint256(-params.amountSpecified);
            // FoT: use amount that actually lands on the pair for the quote.
            uint256 balanceTakeBefore = takeCurrency.balanceOf(pairAddr);
            poolManager.take(takeCurrency, pairAddr, amountTakeUsed);
            uint256 balanceTakeAfter = takeCurrency.balanceOf(pairAddr);
            uint256 amountArrived = balanceTakeAfter - balanceTakeBefore;
            amountOut = getAmountOut(amountArrived, reserveIn, reserveOut);
        } else {
            amountOut = uint256(params.amountSpecified);
            amountTakeUsed = getAmountIn(amountOut, reserveIn, reserveOut);
            poolManager.take(takeCurrency, pairAddr, amountTakeUsed);
            // Fee-on-transfer input is unsupported for exact-out (pair needs full getAmountIn on balance).
        }

        uint256 amount0Out;
        uint256 amount1Out;
        if (zeroForOne) {
            amount1Out = amountOut;
        } else {
            amount0Out = amountOut;
        }
        uint256 balanceSettleBefore = settleCurrency.balanceOf(address(poolManager));
        IUniswapV2Pair(pairAddr).swap(amount0Out, amount1Out, address(poolManager), "");
        uint256 balanceSettleAfter = settleCurrency.balanceOf(address(poolManager));

        amountSettle = balanceSettleAfter - balanceSettleBefore;
    }

    receive() external payable override {
        revert NativeCurrencyNotSupported();
    }
}
