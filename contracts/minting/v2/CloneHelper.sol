// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./MintingHubV2.sol";
import "./IPositionV2.sol";
import "../../erc20/IERC20.sol";
import "../../utils/Ownable.sol";

/**
 * @title CloneHelper
 * @notice Helper contract that allows cloning a position and immediately adjusting its liquidation price.
 * Without this helper, cloning always inherits the parent's price and adjusting it requires a separate
 * transaction by the owner.
 */
contract CloneHelper {

    MintingHubV2 public immutable HUB;

    constructor(address hub_) {
        HUB = MintingHubV2(hub_);
    }

    /**
     * @notice Clone a position and set a new liquidation price in one transaction.
     * @dev The caller must have approved this contract for the collateral token.
     *      When raising the price, a 3-day cooldown is triggered (no further minting until then).
     *      When lowering the price, the collateral must still cover the minted amount at the new price.
     * @param parent             address of the position to clone
     * @param initialCollateral  amount of collateral to deposit
     * @param initialMint        amount of ZCHF to mint (minted at the parent's price, then price is adjusted)
     * @param expiration         expiration timestamp for the clone
     * @param newPrice           the desired liquidation price for the clone
     * @return pos               address of the newly created position
     */
    function cloneWithPrice(address parent, uint256 initialCollateral, uint256 initialMint, uint40 expiration, uint256 newPrice) external returns (address) {
        // Transfer collateral from caller and approve hub
        IERC20 collateral = IPositionV2(parent).collateral();
        collateral.transferFrom(msg.sender, address(this), initialCollateral);
        collateral.approve(address(HUB), initialCollateral);

        // Clone with this contract as temporary owner so we can adjust the price
        address pos = HUB.clone(address(this), parent, initialCollateral, initialMint, expiration);

        // Adjust the liquidation price
        IPositionV2(pos).adjustPrice(newPrice);

        // Forward any minted ZCHF to the caller
        IERC20 zchf = IERC20(address(HUB.zchf()));
        zchf.transfer(msg.sender, zchf.balanceOf(address(this)));

        // Transfer ownership to the caller
        Ownable(pos).transferOwnership(msg.sender);

        return pos;
    }
}
