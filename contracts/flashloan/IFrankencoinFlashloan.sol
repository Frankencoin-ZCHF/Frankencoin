// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IBasicFrankencoin} from "../stablecoin/IBasicFrankencoin.sol";
import {IModuleRegistry} from "../registry/IModuleRegistry.sol";

/// @title IFrankencoinFlashloan
/// @notice Interface for initiating a Frankencoin ZCHF flash loan.
///
/// The contract must be registered as an active module in the ModuleRegistry.
/// It does not need direct ZCHF minter status; mint and burn are proxied through
/// the registry via moduleMint / moduleBurn.
interface IFrankencoinFlashloan {
    /// @notice Flash-loan `amount` ZCHF to `msg.sender`.
    ///
    ///         `msg.sender` must implement `IFrankencoinFlashloanCallback`. ZCHF is
    ///         minted before the callback and burned from `msg.sender` after it returns.
    ///         No token approval is required — the registry burns as a privileged minter.
    ///
    /// @param amount ZCHF to mint and deliver to msg.sender (also the exact burn amount).
    /// @param data   Arbitrary bytes forwarded verbatim to onFrankencoinFlashloan.
    function flashloan(uint256 amount, bytes calldata data) external;

    /// @notice Returns the ModuleRegistry this contract routes minter-privilege calls through.
    function registry() external view returns (IModuleRegistry);

    /// @notice Returns the Frankencoin contract, derived from the registry.
    function zchf() external view returns (IBasicFrankencoin);
}
