// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ILitePSM} from "../../../../src/aggregator-hooks/implementations/LitePSM/interfaces/ILitePSM.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockLitePSM
/// @notice Mock LitePSM for unit testing — simulates sellGem/buyGem with configurable tin/tout fees.
/// @dev Uses floor division for usdsAmt (matching the real PSM's internal math).
///      The mock acts as its own pocket so USDC balance queries go to address(this).
contract MockLitePSM is ILitePSM {
    using SafeERC20 for IERC20;

    uint256 private constant WAD = 1e18;

    address private immutable _gem;
    address private immutable _usds;

    uint256 public tin; // fee on sellGem (USDC → USDS)
    uint256 public tout; // fee on buyGem (USDS → USDC)
    /// @dev buf mirrors the real PSM's pre-minted stablecoin buffer (WAD units).
    ///      Defaults to type(uint256).max (effectively uncapped) so existing tests are unaffected.
    ///      Set via setBuf() to simulate a constrained debt ceiling / buffer in capacity tests.
    uint256 public buf = type(uint256).max;

    constructor(address gem_, address usds_) {
        _gem = gem_;
        _usds = usds_;
    }

    function gem() external view override returns (address) {
        return _gem;
    }

    function pocket() external view override returns (address) {
        return address(this);
    }

    function to18ConversionFactor() external pure override returns (uint256) {
        return 1e12;
    }

    /// @notice Sell gemAmt USDC, receive USDS at (WAD - tin) rate
    function sellGem(address usr, uint256 gemAmt) external override returns (uint256 usdsAmt) {
        // Compute fee with floor division then subtract, matching the real PSM.
        // gemAmt * 1e12 * (WAD - tin) / WAD would instead ceil the fee because
        // floor((A*WAD - B) / WAD) = A - ceil(B/WAD).
        uint256 fee = gemAmt * 1e12 * tin / WAD;
        usdsAmt = gemAmt * 1e12 - fee;
        IERC20(_gem).safeTransferFrom(msg.sender, address(this), gemAmt);
        IERC20(_usds).safeTransfer(usr, usdsAmt);
    }

    /// @notice Buy gemAmt USDC, pay USDS at (WAD + tout) rate
    function buyGem(address usr, uint256 gemAmt) external override returns (uint256 usdsAmt) {
        // fee uses floor division; adding to a WAD-aligned base keeps the whole expression floor.
        uint256 fee = gemAmt * 1e12 * tout / WAD;
        usdsAmt = gemAmt * 1e12 + fee;
        IERC20(_usds).safeTransferFrom(msg.sender, address(this), usdsAmt);
        IERC20(_gem).safeTransfer(usr, gemAmt);
    }

    function setTin(uint256 tin_) external {
        tin = tin_;
    }

    function setTout(uint256 tout_) external {
        tout = tout_;
    }

    /// @notice Set the buf (pre-minted buffer) in WAD units to simulate sellGem capacity limits.
    ///         e.g. setBuf(500_000 * 1e18) caps sellGem at 500k USDC (500k * 1e18 / 1e12 = 500k USDC).
    function setBuf(uint256 buf_) external {
        buf = buf_;
    }
}
