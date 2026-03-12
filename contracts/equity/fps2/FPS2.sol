// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./AccumulatingVotesToken.sol";
import "./FPS2MintRedeem.sol";

/**
 * @title FPS2
 * @notice A wrapper token around the Frankencoin Pool Share (FPS) that removes the 90-day
 * redemption lock in favor of a spread-based pricing mechanism. It comes with its own
 * governance system and a minter pre-announcement system that
 * effectively extends the veto period for new minting modules to 3 months.
 *
 * Investment price is unaltered (same as investing directly in FPS). Selling incurs a discount
 * based on an 8th-power curve that increases with recently redeemed FPS volume.
 * Investing reduces the redemption counter (net redemptions). The counter linearly
 * recovers over 30 days.
 */
contract FPS2 is AccumulatingVotesToken, FPS2MintRedeem {

    constructor(IFrankencoin zchf_, ICCIPAdmin ccipAdmin_)
        AccumulatingVotesToken()
        FPS2Governance(zchf_, ccipAdmin_)
        FPS2MintRedeem(Equity(address(zchf_.reserve())))
    {}

    function name() external pure override returns (string memory) {
        return "Frankencoin Pool Share 2";
    }

    function symbol() external pure override returns (string memory) {
        return "FPS2";
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override(AccumulatingVotesToken, ERC20) {
        super._beforeTokenTransfer(from, to, amount);
    }

}
