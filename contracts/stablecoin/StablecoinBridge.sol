// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../erc20/IERC20.sol";
import "../erc20/IERC677Receiver.sol";
import "./IFrankencoin.sol";

/**
 * @title Stable Coin Bridge
 * @notice A minting contract for another Swiss franc stablecoin ('source stablecoin') that we trust.
 * @author Frankencoin
 */
contract StablecoinBridge {
    
    IERC20 public immutable chf; // the source stablecoin
    IFrankencoin public immutable zchf; // the Frankencoin

    /**
     * @notice The time horizon after which this bridge expires and needs to be replaced by a new contract.
     */
    uint256 public immutable horizon;

    /**
     * The maximum amount of outstanding converted source stablecoins.
     */
    uint256 public immutable limit;
    uint256 public minted;

    error Limit(uint256 amount, uint256 limit);
    error Expired(uint256 time, uint256 expiration);
    error UnsupportedToken(address token);

    constructor(address other, address zchfAddress, uint256 limit_) {
        chf = IERC20(other);
        zchf = IFrankencoin(zchfAddress);
        horizon = block.timestamp + 52 weeks;
        limit = limit_;
        minted = 0;
    }

    /**
     * @notice Convenience method for mint(msg.sender, amount)
     */
    function mint(uint256 amount) external {
        mintTo(msg.sender, amount);
    }

    /**
     * @notice Mint the target amount of Frankencoins, taking the equal amount of source coins from the sender.
     * @dev This only works if an allowance for the source coins has been set and the caller has enough of them.
     */
    function mintTo(address target, uint256 amount) public {
        chf.transferFrom(msg.sender, address(this), amount);
        _mint(target, amount);
    }

    function _mint(address target, uint256 amount) internal {
        if (block.timestamp > horizon) revert Expired(block.timestamp, horizon);
        zchf.mint(target, amount);
        minted += amount;
        if (minted > limit) revert Limit(amount, limit);
    }

    /**
     * @notice Convenience method for burnAndSend(msg.sender, amount)
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, msg.sender, amount);
    }

    /**
     * @notice Burn the indicated amount of Frankencoin and send the same number of source coin to the caller.
     */
    function burnAndSend(address target, uint256 amount) external {
        _burn(msg.sender, target, amount);
    }

    function _burn(address zchfHolder, address target, uint256 amount) internal {
        zchf.burnFrom(zchfHolder, amount);
        chf.transfer(target, amount);
        minted -= amount;
    }
}
