// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ILitePSM
/// @notice Interface for MakerDAO's LitePSM and LitePSMWrapper contracts
/// @dev Compatible with:
///        - LitePSMWrapper (0xA188EEc8F81263234dA3622A406892F3D630f98c): gem=USDC, stable=USDS
///        - LitePSM-DAI-USDC (0xf6e72Db5454dd049d0788e411b06CfAF16853042): gem=USDC, stable=DAI
///      The "gem" is the collateral token (USDC, 6 decimals); the stable is 18 decimals.
///      to18ConversionFactor = 10^(18 - gem.decimals()) = 10^12 for USDC
interface ILitePSM {
    /// @notice Sell gem to receive stable (e.g. USDC → USDS or USDC → DAI)
    /// @dev Pulls gemAmt of gem from msg.sender; sends stable to usr
    /// @param usr Address to receive stable
    /// @param gemAmt Amount of gem (6 dec) to sell
    /// @return usdsAmt Amount of stable sent to usr
    function sellGem(address usr, uint256 gemAmt) external returns (uint256 usdsAmt);

    /// @notice Buy gem by spending stable (e.g. USDS → USDC or DAI → USDC)
    /// @dev Pulls stable from msg.sender; sends gemAmt of gem to usr
    /// @param usr Address to receive gem
    /// @param gemAmt Amount of gem (6 dec) to receive
    /// @return usdsAmt Amount of stable pulled from msg.sender
    function buyGem(address usr, uint256 gemAmt) external returns (uint256 usdsAmt);

    /// @notice Fee rate for sellGem (gem → stable), in WAD (1e18 = 100%)
    function tin() external view returns (uint256);

    /// @notice Fee rate for buyGem (stable → gem), in WAD (1e18 = 100%)
    function tout() external view returns (uint256);

    /// @notice Conversion factor from gem decimals to 18 decimals (10^(18 - gem.decimals()))
    function to18ConversionFactor() external view returns (uint256);

    /// @notice The gem token address (USDC)
    function gem() external view returns (address);

    /// @notice The pocket contract that holds gem liquidity
    function pocket() external view returns (address);

    /// @notice Pre-minted stable buffer target held in this PSM (WAD, 18 decimals)
    /// @dev Used as a conservative proxy for sellGem capacity.
    ///      The true sellGem cap is `min(buf, line - Art*RAY) / to18ConversionFactor` (gem units),
    ///      but line/Art are only available on the underlying Vat and are not exposed by the wrapper.
    ///      Using buf alone may overestimate capacity when the debt ceiling is simultaneously binding,
    ///      but in normal operation buf is kept well below the ceiling.
    function buf() external view returns (uint256);
}
