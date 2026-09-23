// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IReactor} from "@uniswapx/interfaces/IReactor.sol";
import {IReactorCallback} from "@uniswapx/interfaces/IReactorCallback.sol";
import {IValidationCallback} from "@uniswapx/interfaces/IValidationCallback.sol";
import {OrderInfo, InputToken, OutputToken, ResolvedOrder, SignedOrder} from "@uniswapx/base/ReactorStructs.sol";
import {ERC20} from "@uniswapx/base/ReactorStructs.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {MockUniswapXReactor} from "./MockUniswapXReactor.sol";

/// @notice Helper that calls `reactorCallback` on the filler from an address that is not the reactor,
///         recording the revert data so tests can assert on the `UnauthorizedCaller` branch.
contract MockForeignCallbackProber {
    bytes public lastRevertData;

    function probe(IReactorCallback filler, ResolvedOrder[] memory resolvedOrders, bytes memory callbackData) external {
        try filler.reactorCallback(resolvedOrders, callbackData) {}
        catch (bytes memory reason) {
            lastRevertData = reason;
        }
    }
}

/// @notice Mock reactor that performs the standard mock fill but, mid-execution (while the filler hook is
///         inflight), first runs a configurable malicious probe: re-entering `PoolManager.swap` (to hit the
///         hook's `Reentrancy` guard) or calling `reactorCallback` from a foreign address (to hit
///         `UnauthorizedCaller`). Probe reverts are caught and recorded so the outer fill still completes.
contract MockMaliciousUniswapXReactor is IReactor {
    enum Probe {
        None,
        ReenterSwap,
        ForeignCallback
    }

    /// @notice Native-ETH sentinel used by UniswapX outputs
    address public constant NATIVE = address(0);

    Probe public probe;
    bytes public lastRevertData;
    MockForeignCallbackProber public prober;

    IPoolManager public poolManager;
    PoolKey internal reenterKey;
    SwapParams internal reenterParams;
    bytes internal reenterHookData;

    error OutputTransferFailed();
    error ReentrantSwapUnexpectedlySucceeded();

    constructor() {
        prober = new MockForeignCallbackProber();
    }

    /// @notice Arm the reactor to re-enter `PoolManager.swap` with the given arguments during the fill.
    function setReenterSwap(
        IPoolManager _poolManager,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external {
        probe = Probe.ReenterSwap;
        poolManager = _poolManager;
        reenterKey = key;
        reenterParams = params;
        reenterHookData = hookData;
    }

    /// @notice Arm the reactor to call `reactorCallback` from a foreign address during the fill.
    function setForeignCallback() external {
        probe = Probe.ForeignCallback;
    }

    function execute(SignedOrder calldata) external payable override {
        revert("not implemented");
    }

    function executeBatch(SignedOrder[] calldata) external payable override {
        revert("not implemented");
    }

    function executeBatchWithCallback(SignedOrder[] calldata, bytes calldata) external payable override {
        revert("not implemented");
    }

    function executeWithCallback(SignedOrder calldata order, bytes calldata callbackData) external payable override {
        MockUniswapXReactor.MockOrder memory o = abi.decode(order.order, (MockUniswapXReactor.MockOrder));

        // Pull the swapper's input to the filler (msg.sender). Swapper must have approved this reactor.
        ERC20(o.inputToken).transferFrom(o.swapper, msg.sender, o.inputAmount);

        // Build the resolved order handed to the filler.
        ResolvedOrder[] memory resolved = new ResolvedOrder[](1);
        OutputToken[] memory outputs = new OutputToken[](1);
        outputs[0] = OutputToken({token: o.outputToken, amount: o.outputAmount, recipient: o.outputRecipient});
        resolved[0] = ResolvedOrder({
            info: OrderInfo({
                reactor: IReactor(address(this)),
                swapper: o.swapper,
                nonce: 0,
                deadline: type(uint256).max,
                additionalValidationContract: IValidationCallback(address(0)),
                additionalValidationData: ""
            }),
            input: InputToken({token: ERC20(o.inputToken), amount: o.inputAmount, maxAmount: o.inputAmount}),
            outputs: outputs,
            sig: order.sig,
            hash: bytes32(0)
        });

        // The filler is inflight here: run the armed malicious probe, catching its revert.
        if (probe == Probe.ReenterSwap) {
            try poolManager.swap(reenterKey, reenterParams, reenterHookData) returns (BalanceDelta) {
                revert ReentrantSwapUnexpectedlySucceeded();
            } catch (bytes memory reason) {
                lastRevertData = reason;
            }
        } else if (probe == Probe.ForeignCallback) {
            prober.probe(IReactorCallback(msg.sender), resolved, callbackData);
        }

        // The filler sources/converts the output during this callback.
        IReactorCallback(msg.sender).reactorCallback(resolved, callbackData);

        // Deliver the output to the recipient.
        if (o.outputToken == NATIVE) {
            (bool ok,) = o.outputRecipient.call{value: o.outputAmount}("");
            if (!ok) revert OutputTransferFailed();
        } else {
            ERC20(o.outputToken).transferFrom(msg.sender, o.outputRecipient, o.outputAmount);
        }
    }

    receive() external payable {}
}
