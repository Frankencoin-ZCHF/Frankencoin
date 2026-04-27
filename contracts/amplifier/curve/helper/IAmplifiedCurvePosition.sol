// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IAmplifierCurve} from "./IAmplifierCurve.sol";

interface IAmplifiedCurvePosition {
    // --- Errors ---
    error AlreadyInitialized();

    // --- Events ---
    event Mint(uint256 zchfAmount, uint256 collateralAmount, uint256 lpReceived);
    event Burn(uint256 lpBurned, uint256 zchfRepaid);

    // --- State ---
    function AMP() external view returns (IAmplifierCurve);
    function borrowed() external view returns (uint256);
    function lpBalance() external view returns (uint256);

    // --- Mutating ---
    function initialize(IAmplifierCurve amp, address positionOwner) external;
    function mint(uint256 zchfAmount, uint256 collateralAmount, uint256 minLp) external;
    function burn(uint256 lpAmount, uint256[2] calldata minAmounts) external returns (uint256[2] memory received);
}
