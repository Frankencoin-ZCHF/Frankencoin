// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./MintingHubV2.sol";
import "./IPositionV2.sol";
import "../../erc20/IERC20.sol";
import "../../utils/Ownable.sol";

/**
 * @title CloneHelper
 * @notice Helper contract that allows cloning a position and immediately setting a different liquidation price.
 *
 * The clone always mints at the parent's price first, then adjusts if needed:
 * - Same price as parent: no adjustment, no cooldown.
 * - Lower price: adjusted downward immediately (no cooldown).
 * - Higher price: adjusted upward (3-day cooldown triggered, but the initial mint already happened).
 */
contract CloneHelper {

    MintingHubV2 public immutable HUB;

    constructor(address hub_) {
        HUB = MintingHubV2(hub_);
    }

    /**
     * @notice Clone a position, mint, and optionally set a new liquidation price in one transaction.
     * @dev The caller must have approved this contract for the collateral token.
     *      Minting always happens at the parent's price. The price is only adjusted afterwards
     *      if newPrice differs from the parent's price.
     * @param parent             address of the position to clone
     * @param initialCollateral  amount of collateral to deposit
     * @param initialMint        amount of ZCHF to mint
     * @param expiration         expiration timestamp for the clone
     * @param newPrice           the desired liquidation price for the clone
     * @return pos               address of the newly created position
     */
    function cloneWithPrice(address parent, uint256 initialCollateral, uint256 initialMint, uint40 expiration, uint256 newPrice) external returns (address) {
        IERC20 collateral = IPositionV2(parent).collateral();
        collateral.transferFrom(msg.sender, address(this), initialCollateral);
        collateral.approve(address(HUB), initialCollateral);

        // Clone and mint at the parent's price
        address pos = HUB.clone(address(this), parent, initialCollateral, initialMint, expiration);

        // Only adjust if the desired price differs from what was inherited
        if (newPrice != IPositionV2(parent).price()) {
            IPositionV2(pos).adjustPrice(newPrice);
        }

        // Forward any minted ZCHF to the caller
        IERC20 zchf = IERC20(address(HUB.zchf()));
        zchf.transfer(msg.sender, zchf.balanceOf(address(this)));

        // Transfer ownership to the caller
        Ownable(pos).transferOwnership(msg.sender);

        return pos;
    }
}
