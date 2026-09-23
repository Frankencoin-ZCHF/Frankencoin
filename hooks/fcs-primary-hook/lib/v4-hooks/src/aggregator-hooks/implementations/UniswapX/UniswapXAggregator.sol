// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {BaseAggregatorHook} from "../../BaseAggregatorHook.sol";
import {BaseHookDataAggregator} from "../../BaseHookDataAggregator.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {IReactor} from "@uniswapx/interfaces/IReactor.sol";
import {IReactorCallback} from "@uniswapx/interfaces/IReactorCallback.sol";
import {ResolvedOrder, SignedOrder} from "@uniswapx/base/ReactorStructs.sol";
import {OrderQuoter} from "@uniswapx/lens/OrderQuoter.sol";

/// @title UniswapXAggregator
/// @notice Uniswap V4 hook whose "liquidity source" is a single UniswapX order (e.g. a Dutch order)
///         supplied as swap `hookData`. The hook acts as the UniswapX filler: it calls the Reactor's
///         `executeWithCallback`, the Reactor pulls the order swapper's input (via Permit2) to this hook
///         and invokes `reactorCallback`, during which the hook sources the order's required output from
///         the V4 PoolManager (i.e. from the V4 swapper). The V4 swapper therefore provides the counter-side
///         liquidity that fills the UniswapX order and, in return, receives the order's input token.
/// @dev    Original Dutch orders are all-or-nothing: the whole order fills or nothing does. The V4 swap amount
///         only needs to cover the order, not match it exactly: an exact-in swap may specify more input than the
///         order's resolved output requires, and an exact-out swap may request less than the order's input
///         supplies — any surplus is forwarded to the protocol's token jar (or left in this hook if no jar is
///         configured). The swap reverts only when the order's required output exceeds the specified input
///         (exact-in) or the order supplies less than the requested output (exact-out). Each swap consumes one
///         order passed fresh via `hookData`, so a
///         single deployed pool is reusable across many orders for the same token pair.
/// @dev    Stateless across pools: this hook holds no per-pool configuration (the order fully determines the
///         token pair and amounts at swap time), so one deployed hook instance can be the `hooks` address for
///         any number of V4 pools — no per-pool factory or deployment is needed. Simply mine one hook address
///         (see `AggregatorHookMiner`/`HookMiner`), deploy it once, then call `PoolManager.initialize` directly
///         for each pool that should use it.
/// @dev    Routing-style quoting (no hookData) is unsupported: `quote`/`_rawQuote`/`pseudoTotalValueLocked` revert
///         because the order is only known at swap time. Use `quoteWithHookData`, which resolves the supplied order
///         via UniswapX's OrderQuoter (note: not a view — see `_rawQuoteWithHookData`).
/// @dev    This hook opts out of protocol-fee classification: `protocolFeeFlags` returns 0, so pools using it
///         are not subject to a protocol fee.
contract UniswapXAggregator is BaseHookDataAggregator, IReactorCallback {
    using SafeERC20 for IERC20;

    /// @notice The UniswapX reactor this hook fills orders against
    IReactor public immutable reactor;
    /// @notice The canonical wrapped-native token, used to bridge V4 native ETH and order WETH
    address public immutable weth;
    /// @notice Lens used to resolve an order (Dutch decay applied) into its current input/output amounts
    OrderQuoter public immutable orderQuoter;

    // Unique, fixed transient-storage slots (EIP-1153), derived from namespaced labels so they are reproducible
    // and collision-resistant (matching the `FluidDexT1`/`UniswapV3` aggregator convention).
    // The inflight (reentrancy / authorized-callback) flag. bytes32(uint256(keccak256("UniswapXAggregator.transient.inflight")) - 1)
    bytes32 private constant INFLIGHT_SLOT = 0x1176e989128e5c0647e83e232d1bddeb5fda2c2633b1403aa0480ddc5744db90;
    // Scratch slots written by `reactorCallback` and read back in `_conductSwap`.
    // bytes32(uint256(keccak256("UniswapXAggregator.transient.resolvedInput")) - 1)
    bytes32 private constant RESOLVED_INPUT_SLOT = 0xb118917dbd5ff3662ea80ab603cec995cb9a6b1dc1ad61eda6f03b34bbbfb660;
    // bytes32(uint256(keccak256("UniswapXAggregator.transient.resolvedOutput")) - 1)
    bytes32 private constant RESOLVED_OUTPUT_SLOT = 0xc5b5e49dc52e02802787e6d9f0f9a1f57867b6b3c54b85bf17b6914c521972d2;

    /// @dev Upper bound for order amounts. The V4 swap delta is formed via `int128(uint128(amount))` in the
    ///      base `_processAmounts`, so any amount above `int128.max` would silently sign-flip/truncate the
    ///      delta. Both the order input and (summed) output are validated against this before being used.
    uint256 private constant MAX_INT128 = uint256(uint128(type(int128).max));

    error Reentrancy();
    error ProhibitedEntry();
    error UnauthorizedCaller();
    error UnexpectedOrderCount();
    error NoOrderData();
    error NoOrderOutputs();
    error InconsistentOrderOutputs();
    error OrderInputMismatch();
    error OrderOutputMismatch();
    error OrderAmountMismatch();
    error OrderInputOverflow();
    error OrderOutputOverflow();
    error NativeTransferFailed();
    error TVLNotSupported();

    /// @notice Emitted when the surplus between the V4 swap amount and the resolved order amount is
    ///         forwarded to the token jar
    event SurplusCollected(address indexed tokenJar, Currency indexed currency, uint256 amount);

    constructor(IPoolManager _manager, IReactor _reactor, address _weth)
        BaseHookDataAggregator(_manager, "UniswapXAggregator v1.0")
    {
        reactor = _reactor;
        weth = _weth;
        orderQuoter = new OrderQuoter();
    }

    function protocolFeeFlags() external pure override returns (uint256) {
        return 0;
    }

    /// @inheritdoc BaseHookDataAggregator
    /// @dev Resolves the order in `hookData` (Dutch decay applied) via the OrderQuoter and returns the amount on
    ///      the side opposite `amountSpecified`. WARNING: the order fully determines both amounts, so `zeroToOne`
    ///      and `poolId` are ignored — quoting the wrong pool or direction still returns an answer; callers must
    ///      pass the pool/direction they intend to swap. NOTE: like UniswapX's OrderQuoter this is NOT a view —
    ///      it calls the reactor (pulling the maker's input via Permit2 before rolling back), so it requires a
    ///      funded, approved, validly-signed order and cannot be `staticcall`-ed.
    function _rawQuoteWithHookData(bool, int256 amountSpecified, PoolId, bytes calldata hookData)
        internal
        override
        returns (uint256 amountUnspecified)
    {
        if (hookData.length == 0) revert NoOrderData();
        SignedOrder memory order = abi.decode(hookData, (SignedOrder));

        ResolvedOrder memory resolved = orderQuoter.quote(order.order, order.sig);

        // Sum the order's outputs. The fill requires all outputs share one token (the V4 swapper's input
        // currency), so enforce that same-token invariant here too — otherwise a quote could return a
        // meaningless sum across differing tokens that `reactorCallback` would later reject at fill time.
        if (resolved.outputs.length == 0) revert NoOrderOutputs();
        address outputToken = resolved.outputs[0].token;
        uint256 orderOutput;
        for (uint256 i = 0; i < resolved.outputs.length; i++) {
            if (resolved.outputs[i].token != outputToken) revert InconsistentOrderOutputs();
            orderOutput += resolved.outputs[i].amount;
        }

        // Mirror the execution-time `int128` narrowing (see MAX_INT128) so a quote never returns an amount
        // that `_conductSwap` would later reject as overflowing. For exact-in the amount actually taken from
        // the PoolManager is the swapper's full specified input, so that is what must fit in an int128.
        if (orderOutput > MAX_INT128) revert OrderOutputOverflow();
        if (resolved.input.amount > MAX_INT128) revert OrderInputOverflow();
        if (amountSpecified < 0 && uint256(-amountSpecified) > MAX_INT128) revert OrderOutputOverflow();

        // The order itself fills all-or-nothing, but the V4 swap amount only needs to cover it (mirroring
        // the execution-time bounds in `reactorCallback`/`_conductSwap`).
        // Exact-in: the V4 swap input is `-amountSpecified` (in the order's output token); it must be at
        // least the order's required output. Any surplus input is forwarded to the token jar at swap time.
        if (amountSpecified < 0 && -amountSpecified < int256(orderOutput)) revert OrderAmountMismatch();
        // Exact-out: the V4 swapper requests `amountSpecified` of the order's input token; the order must
        // supply at least that much. Any surplus order input is forwarded to the token jar at swap time.
        if (amountSpecified > 0 && amountSpecified > int256(resolved.input.amount)) revert OrderAmountMismatch();

        // The hook fills atomically: the V4 swapper provides the order's OUTPUT and receives its INPUT.
        // exact-in  (amountSpecified < 0): swapper specified the input it provides (order output) -> receives order input
        // exact-out (amountSpecified > 0): swapper specified the output it wants (order input)   -> pays order output
        return amountSpecified < 0 ? resolved.input.amount : orderOutput;
    }

    /// @inheritdoc IReactorCallback
    /// @dev Called by the reactor mid-execution. Sources the order's output from the PoolManager (the V4
    ///      swapper's input), converting between native ETH and WETH as needed.
    function reactorCallback(ResolvedOrder[] memory resolvedOrders, bytes memory callbackData) external override {
        if (!_getTransientInflight()) revert ProhibitedEntry();
        if (msg.sender != address(reactor)) revert UnauthorizedCaller();
        // `executeWithCallback` always resolves exactly one order; enforce it so a nonstandard reactor
        // cannot slip extra orders past the single-order accounting below.
        if (resolvedOrders.length != 1) revert UnexpectedOrderCount();

        (Currency settleCurrency, Currency takeCurrency, int256 amountSpecified) =
            abi.decode(callbackData, (Currency, Currency, int256));

        ResolvedOrder memory resolved = resolvedOrders[0];

        // The order's input token (received by this hook) must correspond to the V4 swapper's output currency.
        if (!_matches(settleCurrency, address(resolved.input.token))) revert OrderInputMismatch();

        // Sum the order's outputs; all outputs must share the same token and correspond to the take currency.
        if (resolved.outputs.length == 0) revert NoOrderOutputs();
        address outputToken = resolved.outputs[0].token;
        if (!_matches(takeCurrency, outputToken)) revert OrderOutputMismatch();
        uint256 outputAmount;
        for (uint256 i = 0; i < resolved.outputs.length; i++) {
            if (resolved.outputs[i].token != outputToken) revert InconsistentOrderOutputs();
            outputAmount += resolved.outputs[i].amount;
        }

        // Amount pulled from the PoolManager: for exact-in, the swapper's full specified input (the base hook
        // cancels the full specified amount, so the whole input must be taken to balance the delta) — it must
        // cover the order's required output. For exact-out, exactly the order's required output (the swapper
        // pays it in full on the unspecified side).
        uint256 takeAmount = outputAmount;
        if (amountSpecified < 0) {
            takeAmount = uint256(-amountSpecified);
            if (outputAmount > takeAmount) revert OrderAmountMismatch();
        }

        // Pull the V4 swapper's input from the PoolManager (native ETH or ERC20): the order's required output
        // into this hook, and any exact-in surplus straight to the token jar (or into this hook if no jar is
        // cached, rather than reverting the fill). The jar is cached at pool initialize; call `pollTokenJar`
        // to refresh it if the fee controller's jar changes.
        poolManager.take(takeCurrency, address(this), outputAmount);
        if (takeAmount > outputAmount) {
            uint256 surplus = takeAmount - outputAmount;
            address jar = tokenJar;
            if (jar == address(0)) {
                poolManager.take(takeCurrency, address(this), surplus);
            } else {
                poolManager.take(takeCurrency, jar, surplus);
                emit SurplusCollected(jar, takeCurrency, surplus);
            }
        }

        // Convert what we hold into the order's output token so the reactor can deliver it.
        if (outputToken == address(0)) {
            // Order pays native ETH: ensure we hold ETH, then forward it to the reactor (it pays the
            // recipient from its own balance after this callback returns).
            if (!takeCurrency.isAddressZero()) IWETH9(weth).withdraw(outputAmount);
            (bool ok,) = address(reactor).call{value: outputAmount}("");
            if (!ok) revert NativeTransferFailed();
        } else if (outputToken == weth) {
            // Order pays WETH: ensure we hold WETH (wrap if we took native ETH). The reactor pulls it via approval.
            if (takeCurrency.isAddressZero()) IWETH9(weth).deposit{value: outputAmount}();
        }
        // Otherwise the order's output is an ordinary ERC20 equal to `takeCurrency`; the reactor pulls it via approval.

        _setTransientResolved(RESOLVED_INPUT_SLOT, resolved.input.amount);
        _setTransientResolved(RESOLVED_OUTPUT_SLOT, takeAmount);
    }

    /// @inheritdoc BaseAggregatorHook
    /// @dev No persistent liquidity exists; TVL is undefined for an order-filling hook.
    function pseudoTotalValueLocked(PoolId) external pure override returns (uint256, uint256) {
        revert TVLNotSupported();
    }

    /// @notice Returns true if `token` represents native ETH on the order side, accounting for WETH equivalence
    function _isEthClass(address token) internal view returns (bool) {
        return token == address(0) || token == weth;
    }

    /// @notice Returns true if a V4 currency corresponds to an order-side token, treating ETH and WETH as equivalent
    function _matches(Currency currency, address orderToken) internal view returns (bool) {
        address unwrapped = Currency.unwrap(currency);
        if (unwrapped == orderToken) return true;
        return _isEthClass(unwrapped) && _isEthClass(orderToken);
    }

    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        override
        returns (bytes4)
    {
        // The Reactor pulls the order's output token from this hook via transferFrom, so it must be approved.
        // Approve each non-native currency, plus WETH whenever a side is native (a native V4 currency may map
        // to a WETH order output).
        // Although initialization is permissionless, unlimited approvals are safe: the reactor is immutable
        // and trusted, and the hook holds no resting balances between transactions.
        if (!key.currency0.isAddressZero()) {
            IERC20(Currency.unwrap(key.currency0)).forceApprove(address(reactor), type(uint256).max);
        }
        if (!key.currency1.isAddressZero()) {
            IERC20(Currency.unwrap(key.currency1)).forceApprove(address(reactor), type(uint256).max);
        }
        if (key.currency0.isAddressZero() || key.currency1.isAddressZero()) {
            IERC20(weth).forceApprove(address(reactor), type(uint256).max);
        }

        return super._beforeInitialize(sender, key, sqrtPriceX96);
    }

    /// @inheritdoc BaseHookDataAggregator
    /// @dev The swap's hookData is the ABI-encoded UniswapX SignedOrder to fill.
    function _conductSwap(
        Currency settleCurrency,
        Currency takeCurrency,
        SwapParams calldata params,
        PoolId,
        bytes calldata hookData
    ) internal override returns (uint256 amountSettle, uint256 amountTake, bool hasSettled) {
        if (_getTransientInflight()) revert Reentrancy();
        if (hookData.length == 0) revert NoOrderData();

        SignedOrder memory order = abi.decode(hookData, (SignedOrder));

        _setTransientInflight(true);

        // Execute the order. The reactor pulls the order swapper's input (ERC20) to this hook, calls
        // `reactorCallback` (where we source and convert the order's output from the PoolManager), then
        // transfers the order's output from this hook to the order's recipient.
        reactor.executeWithCallback(order, abi.encode(settleCurrency, takeCurrency, params.amountSpecified));

        // amountSettle = order input amount (now held by this hook, in `settleCurrency` units after any unwrap)
        // amountTake   = amount taken from the PoolManager in the callback (the swapper's full specified input
        //                for exact-in; the order's required output for exact-out)
        amountSettle = _getTransientResolved(RESOLVED_INPUT_SLOT);
        amountTake = _getTransientResolved(RESOLVED_OUTPUT_SLOT);

        // Clear the scratch slots so no stale values survive for later swaps in the same transaction.
        _setTransientResolved(RESOLVED_INPUT_SLOT, 0);
        _setTransientResolved(RESOLVED_OUTPUT_SLOT, 0);

        // Guard the true narrowing site: both amounts are cast to int128 when the base forms the swap delta.
        // Above int128.max the cast silently sign-flips/truncates, so reject here before that happens.
        if (amountTake > MAX_INT128) revert OrderOutputOverflow();
        if (amountSettle > MAX_INT128) revert OrderInputOverflow();

        // If the V4 swapper's output is native ETH but the order paid us WETH, unwrap so the base can settle ETH.
        if (settleCurrency.isAddressZero()) {
            uint256 wethBalance = IWETH9(weth).balanceOf(address(this));
            if (wethBalance != 0) IWETH9(weth).withdraw(wethBalance);
        }

        // The order fills all-or-nothing, but the V4 swap amount only needs to cover it. Exact-in was already
        // enforced in `reactorCallback` (required output <= specified input, with the surplus routed to the
        // token jar there). For exact-out, the order must supply at least the requested amount; settle exactly
        // the request and forward the order's surplus input to the token jar (or leave it in this hook if no
        // jar is cached, rather than reverting the fill).
        if (params.amountSpecified > 0) {
            uint256 requested = uint256(params.amountSpecified);
            if (amountSettle < requested) revert OrderAmountMismatch();
            uint256 surplus = amountSettle - requested;
            if (surplus != 0) {
                address jar = tokenJar;
                if (jar != address(0)) {
                    if (settleCurrency.isAddressZero()) {
                        (bool ok,) = jar.call{value: surplus}("");
                        if (!ok) revert NativeTransferFailed();
                    } else {
                        IERC20(Currency.unwrap(settleCurrency)).safeTransfer(jar, surplus);
                    }
                    emit SurplusCollected(jar, settleCurrency, surplus);
                }
            }
            amountSettle = requested;
        }
        _setTransientInflight(false);

        // Leave the order's input token in this hook so the base `_internalSettle` settles `settleCurrency`.
        return (amountSettle, amountTake, false);
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
        value = _value > 0;
    }

    function _setTransientResolved(bytes32 slot, uint256 value) private {
        assembly {
            tstore(slot, value)
        }
    }

    function _getTransientResolved(bytes32 slot) private view returns (uint256 value) {
        assembly {
            value := tload(slot)
        }
    }
}
