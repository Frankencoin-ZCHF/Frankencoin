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
import {IFluidDexT1} from "./interfaces/IFluidDexT1.sol";
import {IDexCallback} from "./interfaces/IDexCallback.sol";
import {IFluidDexReservesResolver} from "./interfaces/IFluidDexReservesResolver.sol";
import {IFluidDexResolver} from "./interfaces/IFluidDexResolver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title FluidDexT1Aggregator
/// @notice Uniswap V4 hook that aggregates liquidity from Fluid DEX T1 pools
/// @dev Implements Fluid's IDexCallback interface for swap callbacks
contract FluidDexT1Aggregator is BaseAggregatorHook, IDexCallback {
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    /// @notice The Fluid DEX T1 pool
    IFluidDexT1 public immutable fluidPool;
    /// @notice Liquidity Layer contract (tokens are transferred here in the callback)
    address public immutable fluidLiquidity;
    /// @notice The Fluid DEX reserves resolver for pool state queries
    IFluidDexReservesResolver public immutable fluidDexReservesResolver;
    /// @notice The Fluid DEX resolver for swap queries
    IFluidDexResolver public immutable fluidDexResolver;
    /// @notice The Uniswap V4 pool ID associated with this aggregator
    PoolId public localPoolId;

    bool private _isReversed;
    bool private _currency0IsNative;
    bool private _currency1IsNative;
    address private constant FLUID_NATIVE_CURRENCY = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    // The slot holding the inflight state, transiently. bytes32(uint256(keccak256("InFlight")) - 1)
    bytes32 private constant INFLIGHT_SLOT = 0x60d3e47259b598a408c0f35a2690d6e03fbf8cbc79ab359d5d81f5f451a5750e;
    // Fluid's exactOut can sometimes be off so we add a buffer to the amountOut
    // Buffer scales with amount: max(INACCURACY_BUFFER, amount / INACCURACY_SCALE)
    uint256 private constant INACCURACY_BUFFER = 20;
    uint256 private constant INACCURACY_SCALE = 1_000_000; // 1 part per million

    error UnauthorizedCaller();
    error Reentrancy();
    error ProhibitedEntry();
    error NativeCurrencyExactOut();
    error HookAlreadyInitialized(PoolId poolId);
    error TokenNotInPool(address token);
    error TokensNotInPool(address token0, address token1);

    constructor(
        IPoolManager _manager,
        IFluidDexT1 _fluidDex,
        IFluidDexReservesResolver _fluidDexReservesResolver,
        IFluidDexResolver _fluidDexResolver,
        address _fluidLiquidity
    ) BaseAggregatorHook(_manager, "FluidDexT1Aggregator v1.0") {
        fluidPool = _fluidDex;
        fluidLiquidity = _fluidLiquidity;
        fluidDexReservesResolver = _fluidDexReservesResolver;
        fluidDexResolver = _fluidDexResolver;
    }

    /// @inheritdoc IDexCallback
    /// @dev Per Fluid docs, tokens should be transferred to the Liquidity Layer.
    function dexCallback(address token, uint256 amount) external override {
        if (!_getTransientInflight()) revert ProhibitedEntry();
        if (msg.sender != address(fluidPool)) revert UnauthorizedCaller();
        if (token == FLUID_NATIVE_CURRENCY) {
            token = address(0);
        }
        poolManager.take(Currency.wrap(token), fluidLiquidity, amount);
    }

    /// @inheritdoc BaseAggregatorHook
    function _rawQuote(bool zeroToOne, int256 amountSpecified, PoolId poolId)
        internal
        override
        returns (uint256 amountUnspecified)
    {
        if (PoolId.unwrap(poolId) != PoolId.unwrap(localPoolId)) revert PoolDoesNotExist();
        bool fluidSwap0to1 = _isReversed ? !zeroToOne : zeroToOne;
        if (amountSpecified < 0) {
            amountUnspecified =
                fluidDexResolver.estimateSwapIn(address(fluidPool), fluidSwap0to1, uint256(-amountSpecified), 0);
        } else {
            // Native-input exact-output is unsupported in execution; gate the quote so it
            // stays consistent with _swapExactOut rather than returning a misleading amount.
            if (zeroToOne ? _currency0IsNative : _currency1IsNative) revert NativeCurrencyExactOut();
            uint256 amount = uint256(amountSpecified);
            amountUnspecified = fluidDexResolver.estimateSwapOut(
                // Fluid's exactOut can be off so we add a scaled buffer to the amountOut
                address(fluidPool),
                fluidSwap0to1,
                amount + _getBuffer(amount),
                type(uint256).max
            );
        }
    }

    /// @inheritdoc BaseAggregatorHook
    /// @dev Uses call (not staticcall) because Fluid's getPoolReserves internally calls getDexPricesAndExchangePrices
    ///      which performs state changes; staticcall would cause StateChangeDuringStaticCall and return zeros.
    function pseudoTotalValueLocked(PoolId poolId) external override returns (uint256 amount0, uint256 amount1) {
        if (PoolId.unwrap(poolId) != PoolId.unwrap(localPoolId)) revert PoolDoesNotExist();
        (bool success, bytes memory data) = address(fluidDexReservesResolver)
            .call(abi.encodeWithSelector(IFluidDexReservesResolver.getPoolReserves.selector, address(fluidPool)));
        if (success && data.length > 0) {
            IFluidDexReservesResolver.PoolWithReserves memory poolData =
                abi.decode(data, (IFluidDexReservesResolver.PoolWithReserves));
            uint256 token0Reserves =
                poolData.collateralReserves.token0RealReserves + poolData.debtReserves.token0RealReserves;
            uint256 token1Reserves =
                poolData.collateralReserves.token1RealReserves + poolData.debtReserves.token1RealReserves;
            return _isReversed ? (token1Reserves, token0Reserves) : (token0Reserves, token1Reserves);
        }
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (PoolId.unwrap(localPoolId) != bytes32(0)) revert HookAlreadyInitialized(localPoolId);
        (address token0, address token1) = fluidDexResolver.getDexTokens(address(fluidPool));
        if (token0 == FLUID_NATIVE_CURRENCY) {
            token0 = address(0);
        }
        if (token1 == FLUID_NATIVE_CURRENCY) {
            token1 = address(0);
        }
        if (token1 < token0) {
            if (token0 != Currency.unwrap(key.currency1) && token1 != Currency.unwrap(key.currency0)) {
                revert TokensNotInPool(token0, token1);
            } else if (token0 != Currency.unwrap(key.currency1)) {
                revert TokenNotInPool(token0);
            } else if (token1 != Currency.unwrap(key.currency0)) {
                revert TokenNotInPool(token1);
            }
            _isReversed = true;
        } else {
            if (token0 != Currency.unwrap(key.currency0) && token1 != Currency.unwrap(key.currency1)) {
                revert TokensNotInPool(token0, token1);
            } else if (token0 != Currency.unwrap(key.currency0)) {
                revert TokenNotInPool(token0);
            } else if (token1 != Currency.unwrap(key.currency1)) {
                revert TokenNotInPool(token1);
            }
        }

        localPoolId = key.toId();

        _currency0IsNative = Currency.unwrap(key.currency0) == address(0);
        _currency1IsNative = Currency.unwrap(key.currency1) == address(0);
        emit AggregatorPoolRegistered(key.toId());
        pollTokenJar();
        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc BaseAggregatorHook
    function _conductSwap(Currency settleCurrency, Currency takeCurrency, SwapParams calldata params, PoolId)
        internal
        override
        returns (uint256 amountSettle, uint256 amountTake, bool hasSettled)
    {
        if (_getTransientInflight()) revert Reentrancy();

        // Pre-compute values to avoid stack depth issues
        bool inputIsNative = takeCurrency.isAddressZero();
        bool outputIsNative = settleCurrency.isAddressZero();
        bool fluidSwap0to1 = _isReversed ? !params.zeroForOne : params.zeroForOne;

        if (!outputIsNative) {
            poolManager.sync(settleCurrency);
        }

        _setTransientInflight(true);

        if (params.amountSpecified < 0) {
            amountTake = uint256(-params.amountSpecified);
            amountSettle = _swapExactIn(
                inputIsNative,
                fluidSwap0to1,
                amountTake,
                outputIsNative ? address(this) : address(poolManager),
                takeCurrency
            );
        } else {
            amountSettle = uint256(params.amountSpecified);
            amountTake = _swapExactOut(
                inputIsNative, outputIsNative, fluidSwap0to1, amountSettle, address(this), settleCurrency
            );
        }

        _setTransientInflight(false);

        if (!outputIsNative) {
            hasSettled = true;
            poolManager.settle();
        }

        return (amountSettle, amountTake, hasSettled);
    }

    function _swapExactIn(
        bool inputIsNative,
        bool fluidSwap0to1,
        uint256 amountIn,
        address recipient,
        Currency takeCurrency
    ) internal returns (uint256 amountOut) {
        if (inputIsNative) {
            poolManager.take(takeCurrency, address(this), amountIn);
            // MinAmountOut is 0 to avoid slippage check because it is checked in the router
            amountOut = fluidPool.swapIn{value: amountIn}(fluidSwap0to1, amountIn, 0, recipient);
        } else {
            // MinAmoountOut is 0 to avoid slippage check because it is checked in the router
            amountOut = fluidPool.swapInWithCallback(fluidSwap0to1, amountIn, 0, recipient);
        }
    }

    function _swapExactOut(
        bool inputIsNative,
        bool outputIsNative,
        bool fluidSwap0to1,
        uint256 amountOut,
        address recipient,
        Currency settleCurrency
    ) internal returns (uint256 amountIn) {
        if (inputIsNative) {
            revert NativeCurrencyExactOut();
        } else {
            // Fluid's exactOut can be off so we add a scaled buffer to the amountOut
            amountIn = fluidPool.swapOutWithCallback(
                fluidSwap0to1, amountOut + _getBuffer(amountOut), type(uint256).max, recipient
            );
            if (!outputIsNative) {
                settleCurrency.transfer(address(poolManager), amountOut);
            }
        }
    }

    function _getBuffer(uint256 amount) internal pure returns (uint256) {
        uint256 scaled = amount / INACCURACY_SCALE;
        return scaled > INACCURACY_BUFFER ? scaled : INACCURACY_BUFFER;
    }

    function _setTransientInflight(bool value) private {
        uint256 _value = value ? 1 : 0;
        assembly {
            tstore(INFLIGHT_SLOT, _value)
        }
    }

    function _getTransientInflight() private view returns (bool value) {
        uint256 _value;
        assembly {
            _value := tload(INFLIGHT_SLOT)
        }
        // Results to true if the slot is not empty
        value = _value > 0;
    }
}
