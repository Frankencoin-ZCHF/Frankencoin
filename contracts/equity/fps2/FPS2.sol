// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./AccumulatingVotesToken.sol";
import "./FPS2MintRedeem.sol";
import "../IGovernance.sol";
import "../IEquity.sol";

/**
 * @title FPS2
 *
 * Wraps the Frankencoin Pool Share to alter the governance dynamics of the Frankencoin system. Think of this
 * contract as a "shareholder agreement" for FPS token holders.
 *
 * The most important features are:
 * - Reduce the veto power threshold from 2% in FPS1 to 1% in FPS2
 * - Increase minter application period of 60 days
 * - Minting and redemption following the ERC 4626 standard
 * - No more waiting period for redemption, but potentially very low redemption prices when too many FPS2 are redeemed within a short time
 * - Ability to prevent FPS1 holders from participating in governance or redeeming their FPS by "shooting" them
 *
 * The FPS2 contract is "binding" as long as more than 50% of all votes are controlled by this contract.
 */
contract FPS2 is AccumulatingVotesToken, FPS2MintRedeem {

    event Wrapped(address who, uint amount);
    event Unwrapped(address who, uint amount);
    event Shot(address target, uint256 votesDestroyed);

    error Binding();
    error NotBinding();
    error SelfShooting();
    error NotFIFO();

    constructor(IGovernanceFactory factory, IGovernance fps1Gov, IFrankencoin zchf_) AccumulatingVotesToken() FPS2MintRedeem(zchf_) {
        (address votes, address helper) = factory.deploy(address(this));
        fps1Gov.delegateVoteTo(helper);
    }

    function name() external pure override returns (string memory) {
        return "Frankencoin Pool Shares 2";
    }

    function symbol() external pure override returns (string memory) {
        return "FPS2";
    }

    /**
     * @notice Wrap FPS tokens into FPS2 tokens 1:1.
     * The caller must have approved this contract to spend their FPS.
     * @param amount  Number of FPS to wrap
     */
    function wrap(uint256 amount) external {
        uint256 votesBefore = FPS1.votes(msg.sender);
        IERC20(address(FPS1)).transferFrom(msg.sender, address(this), amount);
        uint256 votesAfter = FPS1.votes(msg.sender);
        _mint(msg.sender, amount);
        // credit after minting, otherwise it won't work when starting with a 0 balance
        creditVotes(msg.sender, votesBefore - votesAfter);
        emit Wrapped(msg.sender, amount);
    }

    function _redeem(address from, address to, uint256 shares) internal override returns (uint256)  {
        // Only allow redemptions as long as the contract is binding
        if (!isBinding()) revert NotBinding();
        super._redeem(from, to, shares);
    }

    /**
     * This contract is binding and there is no escape any more once more than 2/3 of all votes are controlled by this contract.
     *
     * Note that FPS2 could become "unbinding" again in case a lot of FPS2 are redeemed or FPS1 minted.
     */
    function isBinding() public view returns (bool) {
        return FPS1.relativeVotes(address(this)) * 3 > 2e18;
    }

    /**
     * @notice destroy the votes of an FPS1 holder to prevent them from participating in governance or
     * redeeming their FPS. Can only be called when the contract is binding.
     * 
     * This can be used to effectively force FPS1 holders into FPS2.
     *
     * @param target           the FPS1 holder whose votes to destroy
     */
    function shoot(address target) external {
        if (!isBinding()) revert NotBinding();
        if (target == address(this)) revert SelfShooting();
        address[] memory targets = new address[](1);
        targets[0] = target;
        uint256 votesToDestroy = FPS1.votes(target);
        FPS1.kamikaze(targets, votesToDestroy);
        emit Shot(target, votesToDestroy);
    }

    /**
     * Unwrap FPS2 into FPS1.
     * 
     * This can only be done while not binding and even when FPS is not binding, the
     * later joiners must wait for the earlier joiners to unwrap first.
     */
    function unwrap(uint256 amount) external {
        if (isBinding()) revert Binding();
        if (holdingDuration(msg.sender) >= averageHoldingDuration()) revert NotFIFO();
        _burn(msg.sender, amount);
        FPS1.transfer(msg.sender, amount);
        emit Unwrapped(msg.sender, amount);
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override(AccumulatingVotesToken, ERC20) {
        super._beforeTokenTransfer(from, to, amount);
    }

    // Note
    // Earlier versions had a "restructureCaptable" function here like the one in FPS1.
    // However, in such a catastrophic scenario, it is unclear whether we would still want to have FPS2 and
    // not better restart with FPS1 and a completely new setup.

}

interface IGovernanceFactory {
    function deploy(address fps2mainnet) external returns (address votes, address helper);
}
