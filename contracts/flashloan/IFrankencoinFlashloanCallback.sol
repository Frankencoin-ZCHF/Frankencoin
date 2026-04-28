// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IFrankencoinFlashloanCallback
/// @notice Interface that recipients of a Frankencoin ZCHF flash loan must implement.
///
/// The implementor receives ZCHF, performs its logic, then returns. The flash-loan
/// contract burns the loaned amount from the recipient via minter privilege — no token
/// approval is required from the recipient.
interface IFrankencoinFlashloanCallback {
    /// @notice Invoked after `amount` ZCHF has been minted to `msg.sender`.
    ///
    ///         The recipient must still hold at least `amount` ZCHF when this function
    ///         returns, as the flash-loan contract will burn exactly that amount afterwards.
    ///
    /// @param amount ZCHF minted to this contract (equals the burn amount after return).
    /// @param data   Arbitrary bytes forwarded from the original `flashloan()` call.
    function onFrankencoinFlashloan(uint256 amount, bytes calldata data) external;
}
