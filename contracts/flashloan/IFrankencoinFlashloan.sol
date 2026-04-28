// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IFrankencoinFlashloan
/// @notice Interface for initiating a Frankencoin ZCHF flash loan.
interface IFrankencoinFlashloan {
    /// @notice Flash-loan `amount` ZCHF to `msg.sender`.
    ///
    ///         `msg.sender` must implement `IFrankencoinFlashloanCallback`. ZCHF is
    ///         minted before the callback and burned from `msg.sender` after it returns.
    ///         No token approval is required — the contract burns as a privileged minter.
    ///
    /// @param amount ZCHF to mint and deliver to msg.sender (also the exact burn amount).
    /// @param data   Arbitrary bytes forwarded verbatim to onFrankencoinFlashloan.
    function flashloan(uint256 amount, bytes calldata data) external;
}
