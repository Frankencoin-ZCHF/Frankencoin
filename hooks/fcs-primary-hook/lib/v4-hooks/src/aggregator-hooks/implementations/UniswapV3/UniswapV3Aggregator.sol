// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {BaseAggregatorHook} from "../../BaseAggregatorHook.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "./interfaces/IUniswapV3SwapCallback.sol";
import {IUniswapV3Factory} from "./interfaces/IUniswapV3Factory.sol";

/// @title UniswapV3Aggregator
/// @notice Singleton hook aggregating concentrated liquidity from Uniswap V3 compatible pools (fee-tier factory lookup)
contract UniswapV3Aggregator is BaseAggregatorHook, IUniswapV3SwapCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    /// @notice Uniswap V3 factory used for default pool resolution (fee tier from PoolKey.fee)
    address public immutable factory;

    /// @notice External CL pool per registered Uniswap V4 pool
    mapping(PoolId => address) public poolIdToExternalPool;

    mapping(address => PoolKey) private _canonicalPoolKeyByAddress;

    /// @notice PoolKeys of all pools initialized with this hook, in initialization order
    PoolKey[] internal _initializedPools;

    uint160 internal constant MIN_SQRT_RATIO_ADJ = TickMath.MIN_SQRT_PRICE + 1;
    uint160 internal constant MAX_SQRT_RATIO_ADJ = TickMath.MAX_SQRT_PRICE - 1;

    // The slot holding the expected pool, transiently. bytes32(uint256(keccak256("UniswapV3Aggregator.transient.expectedPool")) - 1)
    bytes32 private constant TRANSIENT_EXPECTED_POOL =
        0x6eabd122407eeebc08f840712abe83f91a845b97d0fe375ce6644f6d5a2cb3a2;
    // The slot holding the swap input paid, transiently. bytes32(uint256(keccak256("UniswapV3Aggregator.transient.swapInputPaid")) - 1)
    bytes32 private constant TRANSIENT_SWAP_INPUT_PAID =
        0x582465caaa3a5bc4afb238d59b626acb3a16194fc90d0d5ec69b636bbd73057a;

    error NativeCurrencyNotSupported();
    error ExternalPoolNotFound();
    error ExternalPoolMismatch();
    error UnauthorizedCallback();
    error CallbackOutsideActiveSwap();
    error Reentrancy();
    error UnexpectedSwapOutputDelta();
    error PairAlreadyHasCanonicalPool(PoolId existingPoolId);
    error QuoteRevert(int256 amount0Delta, int256 amount1Delta);
    error UnexpectedQuoteBehavior();

    /// @param manager PoolManager
    /// @param factory_ Uniswap V3 factory (fee-tier `getPool`)
    /// @param hookVersion Display version string
    constructor(IPoolManager manager, address factory_, string memory hookVersion)
        BaseAggregatorHook(manager, hookVersion)
    {
        factory = factory_;
    }

    /// @inheritdoc IUniswapV3SwapCallback
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        _processCallback(amount0Delta, amount1Delta, data);
    }

    function _processCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) internal {
        (PoolId poolId, bool isQuote) = abi.decode(data, (PoolId, bool));
        if (isQuote) {
            revert QuoteRevert(amount0Delta, amount1Delta);
        }

        address expectedPool = _transientExpectedPool();
        if (expectedPool == address(0)) revert CallbackOutsideActiveSwap();
        if (msg.sender != expectedPool) revert UnauthorizedCallback();
        if (poolIdToExternalPool[poolId] != msg.sender) revert UnauthorizedCallback();

        address pool = msg.sender;
        PoolKey storage canonical = _canonicalPoolKeyByAddress[pool];
        address tokenOwed;
        uint256 owedAmt;
        if (amount0Delta > 0) {
            tokenOwed = Currency.unwrap(canonical.currency0);
            owedAmt = uint256(amount0Delta);
        } else if (amount1Delta > 0) {
            tokenOwed = Currency.unwrap(canonical.currency1);
            owedAmt = uint256(amount1Delta);
        } else {
            revert UnexpectedSwapOutputDelta();
        }
        _setTransientSwapInputPaid(owedAmt);
        poolManager.take(Currency.wrap(tokenOwed), pool, owedAmt);
    }

    /// @inheritdoc BaseAggregatorHook
    function _rawQuote(bool zeroToOne, int256 amountSpecified, PoolId poolId)
        internal
        virtual
        override
        returns (uint256 amountUnspecified)
    {
        address poolAddr = poolIdToExternalPool[poolId];
        if (poolAddr == address(0)) revert PoolDoesNotExist();

        bool exactInput = amountSpecified < 0;
        int256 v3AmountSpecified = -amountSpecified;

        bytes memory revertData = _quoteViaPoolCallRevertData(poolAddr, zeroToOne, v3AmountSpecified, poolId);
        (int256 amount0Delta, int256 amount1Delta) = _decodeQuoteRevert(revertData);
        return _unspecifiedSideFromQuoteDeltas(zeroToOne, exactInput, amount0Delta, amount1Delta);
    }

    /// @dev Low-level `call`: same-contract callback reverts do not surface through try/catch on a direct `swap` call.
    function _quoteViaPoolCallRevertData(address poolAddr, bool zeroToOne, int256 v3AmountSpecified, PoolId poolId)
        private
        returns (bytes memory revertData)
    {
        bytes memory swapCalldata = abi.encodeCall(
            IUniswapV3Pool.swap,
            (
                address(this),
                zeroToOne,
                v3AmountSpecified,
                zeroToOne ? MIN_SQRT_RATIO_ADJ : MAX_SQRT_RATIO_ADJ,
                abi.encode(poolId, true)
            )
        );
        (bool success, bytes memory ret) = poolAddr.call(swapCalldata);
        if (success || ret.length != 68 || bytes4(ret) != QuoteRevert.selector) {
            revert UnexpectedQuoteBehavior();
        }
        return ret;
    }

    function _unspecifiedSideFromQuoteDeltas(bool zeroToOne, bool exactInput, int256 amount0Delta, int256 amount1Delta)
        private
        pure
        returns (uint256 amt)
    {
        if (exactInput) {
            return zeroToOne ? uint256(-amount1Delta) : uint256(-amount0Delta);
        } else {
            return zeroToOne ? uint256(amount0Delta) : uint256(amount1Delta);
        }
    }

    function _decodeQuoteRevert(bytes memory reason) private pure returns (int256 amount0Delta, int256 amount1Delta) {
        assembly ("memory-safe") {
            amount0Delta := mload(add(reason, 36))
            amount1Delta := mload(add(reason, 68))
        }
    }

    /// @inheritdoc BaseAggregatorHook
    function pseudoTotalValueLocked(PoolId poolId) external view override returns (uint256 amount0, uint256 amount1) {
        address poolAddr = poolIdToExternalPool[poolId];
        if (poolAddr == address(0)) revert PoolDoesNotExist();
        PoolKey storage poolKey = _canonicalPoolKeyByAddress[poolAddr];
        amount0 = poolKey.currency0.balanceOf(poolAddr);
        amount1 = poolKey.currency1.balanceOf(poolAddr);
    }

    /// @notice Resolve external pool from PoolKey (Uni V3 factory + fee tier)
    function _resolveExternalPool(address token0, address token1, PoolKey calldata key)
        internal
        view
        virtual
        returns (address pool)
    {
        pool = IUniswapV3Factory(factory).getPool(token0, token1, key.fee);
        if (pool == address(0)) revert ExternalPoolNotFound();
        if (IUniswapV3Pool(pool).fee() != key.fee) revert ExternalPoolMismatch();
        if (IUniswapV3Pool(pool).tickSpacing() != key.tickSpacing) revert ExternalPoolMismatch();
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

        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        address poolAddr = _resolveExternalPool(token0, token1, key);

        // Defensive programming for untrustable factory.
        if (IUniswapV3Pool(poolAddr).token0() != token0 || IUniswapV3Pool(poolAddr).token1() != token1) {
            revert ExternalPoolMismatch();
        }

        PoolKey storage existing = _canonicalPoolKeyByAddress[poolAddr];
        if (address(existing.hooks) != address(0)) {
            revert PairAlreadyHasCanonicalPool(existing.toId());
        }
        _canonicalPoolKeyByAddress[poolAddr] = key;

        poolIdToExternalPool[key.toId()] = poolAddr;
        _initializedPools.push(key);

        emit AggregatorPoolRegistered(key.toId());
        pollTokenJar();
        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc BaseAggregatorHook
    function _conductSwap(Currency settleCurrency, Currency takeCurrency, SwapParams calldata params, PoolId poolId)
        internal
        override
        returns (uint256 amountSettle, uint256 amountTake, bool hasSettled)
    {
        if (settleCurrency.isAddressZero() || takeCurrency.isAddressZero()) revert NativeCurrencyNotSupported();

        address poolAddr = poolIdToExternalPool[poolId];
        if (poolAddr == address(0)) revert PoolDoesNotExist();

        if (_transientExpectedPool() != address(0)) revert Reentrancy();

        uint160 sqrtPriceLimitX96 = params.zeroForOne ? MIN_SQRT_RATIO_ADJ : MAX_SQRT_RATIO_ADJ;

        _setTransientExpectedPool(poolAddr);
        _setTransientSwapInputPaid(0);

        // Uniswap V4 uses negative amountSpecified for exact-input swaps.
        // Uniswap V3 `swap` expects positive for exact-input (negative for exact-output).
        int256 v3AmountSpecified = -params.amountSpecified;

        poolManager.sync(settleCurrency);
        (int256 amount0Delta, int256 amount1Delta) = IUniswapV3Pool(poolAddr)
            .swap(
                address(poolManager), params.zeroForOne, v3AmountSpecified, sqrtPriceLimitX96, abi.encode(poolId, false)
            );

        // Pool.swap returns balance deltas: positive = pool gained token, negative = pool sent token out to recipient.
        if (params.zeroForOne) {
            // amount1Delta < 0 means token1 left the pool; 0 means zero output (dust rounding), still valid to settle 0.
            if (amount1Delta > 0) revert UnexpectedSwapOutputDelta();
            amountSettle = uint256(-amount1Delta);
        } else {
            if (amount0Delta > 0) revert UnexpectedSwapOutputDelta();
            amountSettle = uint256(-amount0Delta);
        }
        amountTake = _getTransientSwapInputPaid();

        _setTransientExpectedPool(address(0));
        _setTransientSwapInputPaid(0);

        if (params.amountSpecified > 0 && uint256(params.amountSpecified) != amountSettle) {
            revert UnexpectedSwapOutputDelta();
        }

        poolManager.settle();
        hasSettled = true;
    }

    function _setTransientExpectedPool(address pool) private {
        uint256 v = uint256(uint160(pool));
        bytes32 slot = TRANSIENT_EXPECTED_POOL;
        assembly ("memory-safe") {
            tstore(slot, v)
        }
    }

    function _transientExpectedPool() private view returns (address) {
        bytes32 slot = TRANSIENT_EXPECTED_POOL;
        uint256 v;
        assembly ("memory-safe") {
            v := tload(slot)
        }
        return address(uint160(v));
    }

    function _setTransientSwapInputPaid(uint256 amt) private {
        bytes32 slot = TRANSIENT_SWAP_INPUT_PAID;
        assembly ("memory-safe") {
            tstore(slot, amt)
        }
    }

    function _getTransientSwapInputPaid() private view returns (uint256 amt) {
        bytes32 slot = TRANSIENT_SWAP_INPUT_PAID;
        assembly ("memory-safe") {
            amt := tload(slot)
        }
    }

    receive() external payable override {
        revert NativeCurrencyNotSupported();
    }
}
