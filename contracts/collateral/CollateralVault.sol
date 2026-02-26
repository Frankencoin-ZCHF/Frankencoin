// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626, ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title CollateralVault
 * @notice ERC4626-compliant 1:1 wrapper for collateral tokens.
 *
 *         Some stock tokens (e.g. AAPLx) leave 1 wei of dust on every transfer due to internal
 *         rounding in their own contract. Using such tokens directly as Frankencoin collateral
 *         breaks the challenge system: MintingHub receives amount-1 but records amount, so the
 *         challenge size can never reach zero and the challenge is permanently stuck.
 *
 *         This vault wraps the asset so the Frankencoin system only ever handles cvToken shares,
 *         which are plain OZ ERC20 with no rounding issues. The dust is absorbed at deposit time
 *         by measuring the actual balance change and minting shares 1:1 against what was received.
 *
 *         Name and symbol are derived automatically from the underlying asset.
 *         No fees, no yield, no admin keys.
 */
contract CollateralVault is ERC4626 {
    constructor(
        IERC20 _asset
    )
        ERC4626(_asset)
        ERC20(
            string.concat("Collateral Vault ", IERC20Metadata(address(_asset)).name()),
            string.concat("cv", IERC20Metadata(address(_asset)).symbol())
        )
    {}

    /**
     * @dev Override to handle fee-on-transfer / dust-producing tokens.
     *      Mints shares equal to what the vault actually received, not the requested amount.
     *      This ensures the vault is never undercollateralized by even 1 wei.
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 /*shares*/) internal override {
        IERC20 _asset = IERC20(asset());
        uint256 balanceBefore = _asset.balanceOf(address(this));
        SafeERC20.safeTransferFrom(_asset, caller, address(this), assets);
        uint256 received = _asset.balanceOf(address(this)) - balanceBefore;
        _mint(receiver, received);
        emit Deposit(caller, receiver, received, received);
    }
}
