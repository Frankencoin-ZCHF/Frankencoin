// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./AccumulatingVotesToken.sol";
import "./FCSMintRedeem.sol";
import "../IGovernance.sol";

/**
 * @title FCS
 *
 * Wraps the Frankencoin Pool Share to alter the governance dynamics of the Frankencoin system. Think of this
 * contract as a "shareholder agreement" for FPS token holders.
 *
 * The most important features are:
 * - Reduce the veto power threshold from 2% in FPS1 to 1% in FCS
 * - Increase minter application period of 60 days
 * - Minting and redemption following the ERC 4626 standard
 * - No more waiting period for redemption, but potentially very low redemption prices when too many FCS are redeemed within a short time
 * - Ability to prevent FPS1 holders from participating in governance or redeeming their FPS by "shooting" them
 *
 * The FCS contract is "binding" as long as more than 2/3 of all votes are controlled by this contract.
 */
contract FCS is AccumulatingVotesToken, FCSMintRedeem {
    event Wrapped(address indexed who, uint amount);
    event Unwrapped(address indexed who, uint amount);
    event Shot(address indexed target, uint256 votesDestroyed);

    error Binding();
    error NotBinding();
    error SelfShooting();
    error NotFIFO();

    constructor(IGovernanceFactory factory, IGovernance fps1Gov, IFrankencoin zchf_) AccumulatingVotesToken() FCSMintRedeem(zchf_) {
        address helper = factory.deploy(address(this));
        fps1Gov.delegateVoteTo(helper);
    }

    function name() external pure override returns (string memory) {
        return "Frankencoin Shares";
    }

    function symbol() external pure override returns (string memory) {
        return "FCS";
    }

    /**
     * @notice Wrap FPS tokens into FCS tokens 1:1.
     * The caller must have approved this contract to spend their FPS.
     * @param amount  Number of FPS to wrap
     */
    function wrap(uint256 amount) external {
        if (amount == 0) return; // nothing to do
        uint256 votesBefore = FPS1.votes(msg.sender);
        IERC20(address(FPS1)).transferFrom(msg.sender, address(this), amount);
        uint256 votesAfter = FPS1.votes(msg.sender);
        _mint(msg.sender, amount);
        // credit after minting, otherwise it won't work when starting with a 0 balance
        creditVotes(msg.sender, votesBefore - votesAfter);
        emit Wrapped(msg.sender, amount);
    }

    /**
     * Only allow redemptions when the contract is binding, i.e. when more than 2/3 of all votes are controlled by this contract.
     * 
     * This ensures that an attacked cannot reduce the voting power of this contract below 2/3 of all votes by redeeming and investing in a loop.
     */
    function redemptionsEnabled() internal view override returns (bool) {
        return isBinding() && FPS1.canRedeem(address(this));
    }

    /**
     * This contract is binding and there is no escape any more once more than 2/3 of all votes are controlled by this contract.
     *
     * Note that FCS could become "unbinding" again in case a lot of FCS are redeemed or FPS1 minted.
     */
    function isBinding() public view returns (bool) {
        return FPS1.relativeVotes(address(this)) * 3 > 2e18;
    }

    /**
     * @notice destroy the votes of an FPS1 holder to prevent them from participating in governance or
     * redeeming their FPS. Can only be called when the contract is binding.
     *
     * This can be used to effectively force FPS1 holders into FCS.
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
     * Unwrap FCS into FPS1.
     *
     * Unwrapping is only allowed for those with an above-average holding duration in order to prevent vote destruction attacks
     * where an attacker wraps and unwraps FCS in a loop to destroy the votes of this contract in the FPS1 contract.
     * 
     * In the initial design, unwrapping was only allowed while the contract was not binding. However, we decided to relax this restricution
     * in order to allow for a smoother transition from FCS to a future replacement contract (in case that is ever needed). Generally, unwrapping
     * your FCS puts you in a strictly worse position as you cannot redeem any more fore 90 days, you temporarily lose all voting power, and
     * you are at risk of getting shot by FCS holders such that you will never regain any voting power unless you join FCS agin.
     */
    function unwrap(uint256 amount) external {
        if (holdingDuration(msg.sender) < averageHoldingDuration()) revert NotFIFO();
        _burn(msg.sender, amount);
        FPS1.transfer(msg.sender, amount);
        emit Unwrapped(msg.sender, amount);
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override(AccumulatingVotesToken, ERC20) {
        super._beforeTokenTransfer(from, to, amount);
    }

    // Note
    // Earlier versions had a "restructureCaptable" function here like the one in FPS1.
    // However, in such a catastrophic scenario, it is unclear whether we would still want to have FCS and
    // not better restart with FPS1 and a completely new setup.
}

interface IGovernanceFactory {
    function deploy(address fcsmainnet) external returns (address helper);
}
