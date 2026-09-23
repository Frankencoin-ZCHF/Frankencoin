// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFluidLiquidity} from "../../../../lib/fluid-contracts-public/contracts/liquidity/interfaces/iLiquidity.sol";

/// @notice Simple contract to supply tokens to Fluid Liquidity layer
/// @dev Implements the liquidityCallback interface required by the liquidity layer
contract MockLiquiditySupplier {
    using SafeERC20 for IERC20;

    /// @notice Fluid's native currency representation
    address constant FLUID_NATIVE_CURRENCY = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    address public immutable liquidityContract;

    constructor(address liquidityContract_) {
        liquidityContract = liquidityContract_;
    }

    /// @notice Callback called by liquidity layer to transfer tokens
    function liquidityCallback(address token_, uint256 amount_, bytes memory data_) external {
        // Decode the "from" address from callback data (last 20 bytes)
        address from_;
        assembly {
            from_ := mload(add(add(data_, 32), sub(mload(data_), 32)))
        }
        IERC20(token_).safeTransferFrom(from_, liquidityContract, amount_);
    }

    /// @notice Supply tokens to the liquidity layer
    function supply(address token_, uint256 amount_, address from_) external {
        IFluidLiquidity(liquidityContract)
            .operate(
                token_,
                int256(amount_),
                0, // no borrow
                address(0),
                address(0),
                abi.encode(from_)
            );
    }

    /// @notice Supply native ETH to the liquidity layer
    function supplyNative(address from_) external payable {
        IFluidLiquidity(liquidityContract).operate{value: msg.value}(
            FLUID_NATIVE_CURRENCY,
            int256(msg.value),
            0, // no borrow
            address(0),
            address(0),
            abi.encode(from_)
        );
    }

    receive() external payable {}
}
