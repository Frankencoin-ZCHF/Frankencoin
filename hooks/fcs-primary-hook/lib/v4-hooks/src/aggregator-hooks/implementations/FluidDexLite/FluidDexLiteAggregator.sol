// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {BaseAggregatorHook} from "../../BaseAggregatorHook.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IFluidDexLite} from "./interfaces/IFluidDexLite.sol";
import {IFluidDexLiteCallback} from "./interfaces/IFluidDexLiteCallback.sol";
import {IFluidDexLiteResolver} from "./interfaces/IFluidDexLiteResolver.sol";

/// @title FluidDexLiteAggregator
/// @notice Uniswap V4 hook that aggregates liquidity from Fluid DEX Lite pools
/// @dev Implements the IFluidDexLiteCallback interface for swap callbacks
contract FluidDexLiteAggregator is BaseAggregatorHook, IFluidDexLiteCallback {
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    /// @notice The Fluid DEX Lite contract
    IFluidDexLite public immutable fluidDexLite;
    /// @notice The Fluid DEX Lite resolver for pool state queries
    IFluidDexLiteResolver public immutable fluidDexLiteResolver;
    /// @notice The key identifying the Fluid DEX Lite pool
    IFluidDexLite.DexKey public dexKey;
    /// @notice The Uniswap V4 pool ID associated with this aggregator
    PoolId public localPoolId;

    bool private _isReversed;
    bytes32 private immutable salt;
    address private constant FLUID_NATIVE_CURRENCY = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    // The slot holding the inflight state, transiently. bytes32(uint256(keccak256("InFlight")) - 1)
    bytes32 private constant INFLIGHT_SLOT = 0x60d3e47259b598a408c0f35a2690d6e03fbf8cbc79ab359d5d81f5f451a5750e;

    error UnauthorizedCaller();
    error Reentrancy();
    error ProhibitedEntry();
    error NativeCurrencyExactOut();
    error IncorrectNativeCurrency();
    error HookAlreadyInitialized(PoolId poolId);

    struct FluidDexLiteSwapParams {
        IFluidDexLite.DexKey dexKey;
        bool swap0To1;
        int256 amountSpecified;
        uint256 amountLimit;
        address payer;
        address recipient;
        bytes extraData;
    }

    constructor(IPoolManager _manager, IFluidDexLite _dexLite, IFluidDexLiteResolver _dexLiteResolver, bytes32 _salt)
        BaseAggregatorHook(_manager, "FluidDexLiteAggregator v1.0")
    {
        fluidDexLite = _dexLite;
        fluidDexLiteResolver = _dexLiteResolver;
        salt = _salt;
    }

    /// @inheritdoc IFluidDexLiteCallback
    function dexCallback(address token, uint256 amount, bytes calldata) external override {
        if (!_getTransientInflight()) revert ProhibitedEntry();
        if (msg.sender != address(fluidDexLite)) revert UnauthorizedCaller();
        if (token == FLUID_NATIVE_CURRENCY) {
            token = address(0);
        }
        poolManager.take(Currency.wrap(token), address(fluidDexLite), amount);
    }

    /// @inheritdoc BaseAggregatorHook
    function _rawQuote(bool zeroToOne, int256 amountSpecified, PoolId poolId)
        internal
        override
        returns (uint256 amountUnspecified)
    {
        if (PoolId.unwrap(poolId) != PoolId.unwrap(localPoolId)) revert PoolDoesNotExist();
        bool fluidSwap0to1 = _isReversed ? !zeroToOne : zeroToOne;
        // For Fluid, amountSpecified is positive for exactInput, and negative for exactOutput
        amountUnspecified = fluidDexLiteResolver.estimateSwapSingle(dexKey, fluidSwap0to1, -amountSpecified);
    }

    /// @inheritdoc BaseAggregatorHook
    function pseudoTotalValueLocked(PoolId poolId) external override returns (uint256 amount0, uint256 amount1) {
        if (PoolId.unwrap(poolId) != PoolId.unwrap(localPoolId)) revert PoolDoesNotExist();
        (, IFluidDexLite.Reserves memory reserves) = fluidDexLiteResolver.getPricesAndReserves(dexKey);
        if (_isReversed) {
            return (reserves.token1RealReserves, reserves.token0RealReserves);
        }
        return (reserves.token0RealReserves, reserves.token1RealReserves);
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (PoolId.unwrap(localPoolId) != bytes32(0)) revert HookAlreadyInitialized(localPoolId);
        // Convert address(0) (Uniswap v4 native currency) to Fluid's native currency representation
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        if (token0 == FLUID_NATIVE_CURRENCY || token1 == FLUID_NATIVE_CURRENCY) {
            revert IncorrectNativeCurrency();
        }

        if (token0 == address(0)) {
            token0 = FLUID_NATIVE_CURRENCY;
        }

        // Fluid requires sorted tokens in dexKey (token0 < token1)
        if (token0 > token1) {
            (token0, token1) = (token1, token0);
            _isReversed = true;
        }

        dexKey = IFluidDexLite.DexKey({token0: token0, token1: token1, salt: salt});

        IFluidDexLite.DexState memory dexState = fluidDexLiteResolver.getDexState(dexKey);

        if (isEmpty(dexState)) revert PoolDoesNotExist();

        localPoolId = key.toId();

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

        bool isExactIn = params.amountSpecified < 0;

        if (!settleCurrency.isAddressZero()) {
            poolManager.sync(settleCurrency);
        }

        _setTransientInflight(true);

        uint256 value;
        if (takeCurrency.isAddressZero()) {
            if (isExactIn) {
                value = uint256(-params.amountSpecified);
                // Take native from PoolManager so we can send it to Fluid
                poolManager.take(takeCurrency, address(this), value);
            } else {
                revert NativeCurrencyExactOut();
            }
        }

        bool fluidSwap0to1 = _isReversed ? !params.zeroForOne : params.zeroForOne;
        uint256 amountUnspecified = _swap(
            FluidDexLiteSwapParams({
                dexKey: dexKey,
                swap0To1: fluidSwap0to1,
                amountSpecified: -params.amountSpecified,
                // Safe to disable slippage check since these are checked in the router
                amountLimit: isExactIn ? 0 : type(uint256).max,
                payer: address(this),
                recipient: settleCurrency.isAddressZero() ? address(this) : address(poolManager),
                extraData: bytes("")
            }),
            value
        );

        _setTransientInflight(false);

        if (!settleCurrency.isAddressZero()) {
            hasSettled = true;
            poolManager.settle();
        }

        if (isExactIn) {
            amountTake = uint256(-params.amountSpecified);
            amountSettle = amountUnspecified;
        } else {
            amountSettle = uint256(params.amountSpecified);
            amountTake = amountUnspecified;
        }

        return (amountSettle, amountTake, hasSettled);
    }

    function _swap(FluidDexLiteSwapParams memory p, uint256 value) internal returns (uint256 amountUnspecified) {
        amountUnspecified = fluidDexLite.swapSingle{value: value}(
            p.dexKey,
            p.swap0To1,
            p.amountSpecified,
            p.amountLimit,
            p.recipient,
            true, // callback enabled
            bytes(""),
            p.extraData
        );
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

    function isEmpty(IFluidDexLite.DexState memory dexState) private pure returns (bool) {
        return dexState.dexVariables.token0Decimals == 0 && dexState.dexVariables.token1Decimals == 0
            && dexState.dexVariables.fee == 0;
    }
}
