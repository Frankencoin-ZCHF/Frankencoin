// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";

/// @title FeeLib
/// @author Uniswap Labs
/// @notice Shared fee helpers for ALF quote and simulation paths, so a quote charges the same total
///         fee the v4 swap will. Previously duplicated in `SwapSimulator` and `DualPoolHook`.
/// @custom:security-contact security@uniswap.org
library FeeLib {
    using ProtocolFeeLibrary for uint24;
    using ProtocolFeeLibrary for uint16;

    /// @notice Compose the directional protocol fee with an LP fee, mirroring `Pool.swap`'s fee
    ///         calculation.
    /// @dev Returns `lpFee` unchanged when the directional protocol fee is zero; otherwise blends
    ///      them via `ProtocolFeeLibrary.calculateSwapFee` (protocol fee on the gross, LP fee on the
    ///      remainder). Selecting the directional half matches how v4 charges the fee per direction.
    /// @param lpFee       The LP fee in pips (1e-6).
    /// @param protocolFee The packed bidirectional protocol fee read from `slot0`.
    /// @param zeroForOne  The swap direction (selects the directional protocol-fee half).
    /// @return The combined swap fee in pips.
    function effectiveSwapFee(uint24 lpFee, uint24 protocolFee, bool zeroForOne) internal pure returns (uint24) {
        uint16 directional = zeroForOne ? protocolFee.getZeroForOneFee() : protocolFee.getOneForZeroFee();
        return directional == 0 ? lpFee : directional.calculateSwapFee(lpFee);
    }
}
