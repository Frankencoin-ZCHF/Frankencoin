// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "../base/BaseHook.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {DeltaResolver} from "@uniswap/v4-periphery/src/base/DeltaResolver.sol";
import {IAggregatorHook} from "./interfaces/IAggregatorHook.sol";
import {ProtocolFees} from "./ProtocolFees.sol";
import {IFeeClassifiedHook} from "@protocol-fees/interfaces/IFeeClassifiedHook.sol";

/// @title BaseAggregatorHook
/// @notice Abstract contract for implementing aggregator hooks in Uniswap V4
/// @dev Implements the IAggregatorHook interface, leverages the ProtocolFees contract, and extends the BaseHook contract
abstract contract BaseAggregatorHook is IAggregatorHook, IFeeClassifiedHook, ProtocolFees, BaseHook, DeltaResolver {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    /// @notice The publicly displayed version of the aggregator hook.
    /// @dev Although this should never change after construction, strings cannot be labelled immutable.
    string public aggregatorHookVersion;

    /// @notice Initializes the hook with required dependencies
    /// @param _manager The Uniswap V4 PoolManager contract
    constructor(IPoolManager _manager, string memory _aggregatorHookVersion) BaseHook(_manager) ProtocolFees(25) {
        aggregatorHookVersion = _aggregatorHookVersion;
    }

    /// @inheritdoc ProtocolFees
    function pollTokenJar() public virtual override returns (address) {
        address newTokenJar = _getTokenJar(poolManager);
        if (tokenJar != newTokenJar) {
            tokenJar = newTokenJar;
            emit TokenJarUpdated(tokenJar);
        }
        return tokenJar;
    }

    /// @inheritdoc IAggregatorHook
    function pseudoTotalValueLocked(PoolId poolId) external virtual returns (uint256 amount0, uint256 amount1);

    /// @inheritdoc IAggregatorHook
    function quote(bool zeroToOne, int256 amountSpecified, PoolId poolId) external returns (uint256 amountUnspecified) {
        return _innerQuote(zeroToOne, amountSpecified, poolId, _rawQuote(zeroToOne, amountSpecified, poolId));
    }

    /// @notice Shared quote tail: applies the protocol fee to a raw quote. Called by every quote variant so
    ///         this fee adjustment lives in exactly one place.
    /// @param zeroToOne Whether the swap is from token0 to token1
    /// @param amountSpecified The amount specified (negative for exact-in, positive for exact-out)
    /// @param poolId The pool ID
    /// @param amountUnspecified The raw unspecified amount before protocol fee adjustment
    /// @return The unspecified amount after protocol fee adjustment
    function _innerQuote(bool zeroToOne, int256 amountSpecified, PoolId poolId, uint256 amountUnspecified)
        internal
        returns (uint256)
    {
        uint24 protocolFee = _getProtocolFee(poolManager, zeroToOne, poolId);

        if (protocolFee == 0) return amountUnspecified;

        if (tokenJar == address(0)) pollTokenJar();
        if (tokenJar == address(0)) return amountUnspecified;

        bool isExactInput = amountSpecified < 0;
        uint256 feeAmount = _calculateProtocolFeeAmount(protocolFee, isExactInput, amountUnspecified);

        return isExactInput ? amountUnspecified - feeAmount : amountUnspecified + feeAmount;
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.beforeSwap = true;
        permissions.beforeSwapReturnDelta = true;
        permissions.beforeInitialize = true;
        permissions.beforeAddLiquidity = true;
    }

    /// @inheritdoc IFeeClassifiedHook
    function protocolFeeFlags() external view virtual override returns (uint256) {
        return 1 << 11;
    }

    /// @notice Abstract function for contracts to implement conducting the swap on the aggregated liquidity source
    /// @param settleCurrency The currency to be settled on the V4 PoolManager (swapper's output currency)
    /// @param takeCurrency The currency to be taken from the V4 PoolManager (swapper's input currency)
    /// @param params The swap parameters
    /// @param poolId The V4 Pool ID
    /// @return amountSettle The amount of the currency being settled (swapper's output amount)
    /// @return amountTake The amount of the currency being taken (swapper's input amount)
    /// @return hasSettled Whether the swap has been settled inside of the _conductSwap function
    /// @dev To settle the swap inside of the _conductSwap function, you must follow the 'sync, send,
    ///      settle' pattern and set hasSettled to true
    function _conductSwap(Currency settleCurrency, Currency takeCurrency, SwapParams calldata params, PoolId poolId)
        internal
        virtual
        returns (uint256 amountSettle, uint256 amountTake, bool hasSettled);

    /// @notice Returns the raw quote from the underlying liquidity source without protocol fees
    /// @param zeroToOne Whether the swap is from token0 to token1
    /// @param amountSpecified The amount specified (negative for exact-in, positive for exact-out)
    /// @param poolId The pool ID
    /// @return amountUnspecified The raw unspecified amount before protocol fee adjustment
    function _rawQuote(bool zeroToOne, int256 amountSpecified, PoolId poolId)
        internal
        virtual
        returns (uint256 amountUnspecified);

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal virtual override returns (bytes4) {
        emit AggregatorPoolRegistered(key.toId());
        // NOTE: Token jar will be grabbed in first protocol fee payment if not done here.
        pollTokenJar();
        return IHooks.beforeInitialize.selector;
    }

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert LiquidityNotAllowed();
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (uint256 amountIn, uint256 amountOut) = _internalSettle(key, params);
        return _innerBeforeSwap(sender, key, params, amountIn, amountOut);
    }

    /// @notice Shared `beforeSwap` tail: turns the settled amounts into the BeforeSwapDelta and applies the
    ///         protocol fee. Called by every `_beforeSwap` variant so this accounting lives in exactly one place.
    /// @param sender The address that initiated the swap
    /// @param key The pool key
    /// @param params The swap parameters
    /// @param amountIn The swapper's input amount resolved by settlement (the `takeCurrency` amount)
    /// @param amountOut The swapper's output amount resolved by settlement (the `settleCurrency` amount)
    function _innerBeforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        uint256 amountIn,
        uint256 amountOut
    ) internal returns (bytes4, BeforeSwapDelta, uint24) {
        int128 unspecifiedDelta = _processAmounts(amountIn, amountOut, params.amountSpecified < 0);
        int128 specified = int128(-params.amountSpecified); // cancel core

        uint24 protocolFee = _getProtocolFee(poolManager, params.zeroForOne, key.toId());
        unspecifiedDelta += _applyWithProtocolFee(poolManager, key, params, unspecifiedDelta, protocolFee);

        if (params.amountSpecified >= 0) {
            // For exactOut, in cases where the implementation's amountOut may be off.
            // NOTE: it would be up to the router to handle this
            specified = -int128(uint128(amountOut));
        }

        int256 amount0;
        int256 amount1;
        if (params.zeroForOne == params.amountSpecified < 0) {
            amount0 = specified;
            amount1 = unspecifiedDelta;
        } else {
            amount0 = unspecifiedDelta;
            amount1 = specified;
        }

        emit HookSwap(key.toId(), sender, amount0, amount1, protocolFee);

        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(specified, unspecifiedDelta), 0);
    }

    function _processAmounts(uint256 amountIn, uint256 amountOut, bool exactInput)
        internal
        pure
        returns (int128 unspecifiedDelta)
    {
        uint256 unspecified;
        if (exactInput) {
            // Exact-In
            unspecified = amountOut;
            unspecifiedDelta = -int128(uint128(unspecified));
        } else {
            // Exact-Out
            unspecified = amountIn;
            unspecifiedDelta = int128(uint128(unspecified));
        }
    }

    function _internalSettle(PoolKey calldata key, SwapParams calldata params)
        internal
        returns (uint256 amountIn, uint256 amountOut)
    {
        Currency settleCurrency = params.zeroForOne ? key.currency1 : key.currency0;
        Currency takeCurrency = params.zeroForOne ? key.currency0 : key.currency1;

        (uint256 amountSettle, uint256 amountTake, bool hasSettled) =
            _conductSwap(settleCurrency, takeCurrency, params, key.toId());

        if (!hasSettled) {
            _settle(settleCurrency, address(this), amountSettle);
        }

        return (amountTake, amountSettle);
    }

    function _pay(Currency token, address payer, uint256 amount) internal override {
        if (payer == address(this)) {
            token.transfer(address(poolManager), amount);
        } else {
            IERC20(Currency.unwrap(token)).safeTransferFrom(payer, address(poolManager), amount);
        }
    }

    /// @notice Allows the contract to receive ETH for native currency swaps
    /// @dev Required for handling native ETH transfers during swap operations
    receive() external payable virtual {}
}
