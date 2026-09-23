// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IReactor} from "@uniswapx/interfaces/IReactor.sol";
import {IReactorCallback} from "@uniswapx/interfaces/IReactorCallback.sol";
import {IValidationCallback} from "@uniswapx/interfaces/IValidationCallback.sol";
import {OrderInfo, InputToken, OutputToken, ResolvedOrder, SignedOrder} from "@uniswapx/base/ReactorStructs.sol";
import {ERC20} from "@uniswapx/base/ReactorStructs.sol";

/// @notice Minimal UniswapX-style reactor for unit tests.
/// @dev Mirrors the canonical BaseReactor flow: pull the swapper's input to the filler (msg.sender), call
///      reactorCallback on the filler, then deliver the order's output from the filler to the recipient.
///      The order is a plain ABI-encoded `MockOrder` carried in `SignedOrder.order` (signatures are ignored).
contract MockUniswapXReactor is IReactor {
    /// @notice Native-ETH sentinel used by UniswapX outputs
    address public constant NATIVE = address(0);

    struct MockOrder {
        address swapper;
        address inputToken; // always an ERC20 (Permit2 cannot move native ETH)
        uint256 inputAmount;
        address outputToken; // ERC20, WETH, or address(0) for native ETH
        uint256 outputAmount;
        address outputRecipient;
    }

    error OutputTransferFailed();

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
        MockOrder memory o = abi.decode(order.order, (MockOrder));

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

        // The filler sources/converts the output during this callback.
        IReactorCallback(msg.sender).reactorCallback(resolved, callbackData);

        // Deliver the output to the recipient.
        if (o.outputToken == NATIVE) {
            // Filler forwarded native ETH to this reactor during the callback; pay the recipient from balance.
            (bool ok,) = o.outputRecipient.call{value: o.outputAmount}("");
            if (!ok) revert OutputTransferFailed();
        } else {
            // Pull the ERC20 output from the filler (it approved this reactor).
            ERC20(o.outputToken).transferFrom(msg.sender, o.outputRecipient, o.outputAmount);
        }
    }

    /// @notice Helper for tests to encode a SignedOrder from a MockOrder
    function encode(MockOrder memory o) external pure returns (SignedOrder memory) {
        return SignedOrder({order: abi.encode(o), sig: ""});
    }

    receive() external payable {}
}
