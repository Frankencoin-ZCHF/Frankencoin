// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFCS} from "./interfaces/IFCS.sol";

/// @notice Single-pool, exact-input router. Pays the manager BEFORE the primary transformation.
/// @dev No arbitrary payer, pool, hookData, approval, sweep or admin execution entry point.
contract FCSPrimaryRouter is IUnlockCallback {
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    IFCS public immutable FCS;
    address public immutable ZCHF;
    address public immutable hook;
    bytes32 private activeRequest;

    error Unauthorized();
    error InvalidConfiguration();
    error Reentrancy();
    error Expired();
    error InvalidAmount();
    error InvalidRecipient();
    error InvalidMinimum();
    error UnexpectedDelta();
    error InsufficientOutput(uint256 actual, uint256 minimum);

    event PrimarySwap(
        address indexed payer, address indexed recipient, bool buyFCS, uint256 amountIn, uint256 amountOut
    );

    struct Request {
        address payer;
        address recipient;
        bool buyFCS;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint256 deadline;
    }

    constructor(IPoolManager manager_, IFCS fcs_, address hook_) {
        if (hook_ == address(0) || address(manager_).code.length == 0 || address(fcs_).code.length == 0) {
            revert InvalidConfiguration();
        }
        manager = manager_;
        FCS = fcs_;
        ZCHF = fcs_.asset();
        hook = hook_;
    }

    function poolKey() public view returns (PoolKey memory) {
        Currency a = Currency.wrap(ZCHF);
        Currency b = Currency.wrap(address(FCS));
        return PoolKey(a < b ? a : b, a < b ? b : a, 0, 1, IHooks(hook));
    }

    /// @param buyFCS True: ZCHF deposit. False: FCS primary redemption (subject to protocol gates).
    /// @dev The caller supplies an explicit, nonzero minimum. Quotes are not execution guarantees.
    function swapExactInput(
        bool buyFCS,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amountOut) {
        if (activeRequest != bytes32(0)) revert Reentrancy();
        if (block.timestamp > deadline) revert Expired();
        if (amountIn == 0 || amountIn > uint256(uint128(type(int128).max))) revert InvalidAmount();
        if (amountOutMinimum == 0) revert InvalidMinimum();
        if (recipient == address(0) || recipient == address(this) || recipient == hook || recipient == address(manager))
        {
            revert InvalidRecipient();
        }
        bytes memory data = abi.encode(Request(msg.sender, recipient, buyFCS, amountIn, amountOutMinimum, deadline));
        activeRequest = keccak256(data);
        amountOut = abi.decode(manager.unlock(data), (uint256));
        delete activeRequest;
        emit PrimarySwap(msg.sender, recipient, buyFCS, amountIn, amountOut);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager) || activeRequest == bytes32(0) || keccak256(data) != activeRequest) {
            revert Unauthorized();
        }
        Request memory r = abi.decode(data, (Request));
        if (block.timestamp > r.deadline) revert Expired();
        Currency input = Currency.wrap(r.buyFCS ? ZCHF : address(FCS));
        Currency output = Currency.wrap(r.buyFCS ? address(FCS) : ZCHF);
        // An exact clean credit belongs to this operation, never to ambient manager balances.
        if (manager.currencyDelta(address(this), input) != 0 || manager.currencyDelta(address(this), output) != 0) {
            revert UnexpectedDelta();
        }
        manager.sync(input);
        IERC20(Currency.unwrap(input)).safeTransferFrom(r.payer, address(manager), r.amountIn);
        if (manager.settle() != r.amountIn) revert UnexpectedDelta();
        bool zeroForOne = Currency.unwrap(input) < Currency.unwrap(output);
        BalanceDelta delta = manager.swap(
            poolKey(),
            SwapParams(
                zeroForOne, -int256(r.amountIn), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            abi.encode(r.amountOutMinimum, r.deadline)
        );
        int128 inputDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = zeroForOne ? delta.amount1() : delta.amount0();
        if (inputDelta != -int256(r.amountIn) || outputDelta <= 0) revert UnexpectedDelta();
        uint256 amountOut = uint256(uint128(outputDelta));
        if (amountOut < r.amountOutMinimum) revert InsufficientOutput(amountOut, r.amountOutMinimum);
        if (
            manager.currencyDelta(address(this), input) != 0
                || manager.currencyDelta(address(this), output) != int256(amountOut)
        ) {
            revert UnexpectedDelta();
        }
        manager.take(output, r.recipient, amountOut);
        if (manager.currencyDelta(address(this), output) != 0) revert UnexpectedDelta();
        return abi.encode(amountOut);
    }
}
