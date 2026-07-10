// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../../stablecoin/IFrankencoin.sol";
import "../IGovernance.sol";
import "../../minting/IPosition.sol";
import "./GovernanceModule.sol";

/**
 * @title MinterGovernance
 * @dev Module to govern adding new minting modules to Frankencoin
 */
contract MinterGovernance is GovernanceModule {
    
    // --- Constants ---
    uint256 public constant MIN_APPLICATION_FEE = 1200 ether;

    // --- Constants ---
    uint256 public constant MIN_APPLICATION_PERIOD = 60 days;
    
    // --- Announcement tracking for minters ---
    mapping(address minter => uint256 timestamp) public announcements;

    // --- References to other contracts ---
    IFrankencoin public immutable ZCHF;
    
    event MinterAnnounced(address indexed who, address indexed minter, uint256 timestamp);
    event Rewarded(address indexed caller, uint256 amount, address token);

    error FeeTooLow();
    error MinterCorrectlyAnnounced();
    error PeriodTooShort();

    /**
     * Instantiate this contract with references to the Frankencoin and FPS2 governance contracts.
     * Caller must make sure that fps2 delegates to this contract, so that qualified FPS2 holders can use the denyMinter function.
     */
    constructor(IFrankencoin zchf_, IGovernance fps1Gov, IGovernance fps2Gov, address delegate, address helper) GovernanceModule(fps2Gov, helper) {
        ZCHF = zchf_;
        fps1Gov.delegateVoteTo(delegate);
    }

    // ==================== Minter Suggestion & Veto ====================

    /**
     * @notice Publicly accessible method to suggest a new way of minting Frankencoin.
     *
     * Wraps the existing functionality in Frankencoin to enforce a 60 days application period.
     * The fee is forwarded to Frankencoin. Minters suggested through this contract are recorded
     * and protected from being vetoed through denyMinter.
     */
    function suggestMinter(address _minter, uint256 _applicationPeriod, uint256 _applicationFee, string calldata _message) external {
        if (_applicationPeriod < MIN_APPLICATION_PERIOD) revert PeriodTooShort();
        if (_applicationFee < MIN_APPLICATION_FEE) revert FeeTooLow();

        // refill the reward pool to contain at least 1000 ZCHF for the MEV bots that will help enforce the application period
        uint256 rewardPoolSize = rewardPool();
        uint256 rewardPoolRefill = rewardPoolSize < 1000 ether ? 200 ether : 0; 
        ZCHF.transferFrom(msg.sender, address(this), _applicationFee);
        ZCHF.suggestMinter(_minter, _applicationPeriod, _applicationFee - rewardPoolRefill, _message);
        announcements[_minter] = block.timestamp;
        emit MinterAnnounced(msg.sender, _minter, block.timestamp);
    }

    /**
     * The funds available for MEV bot rewards. Denying an unannounced minter will reward the caller with 10% of these funds.
     */
    function rewardPool() public view returns (uint256) {
        return ZCHF.balanceOf(address(this));
    }

    /**
     * Check the reward that the caller would receive for denying an unannounced minter.
     * 
     * @dev To find the candidates for the 'minter' parameter, look for MinterApplied events emitted by the Frankencoin contract
     * after this contract was deployed and that is not accompanied by a MinterAnnounced event emited from this contract.
     */
    function checkReward(address minter) public view returns (uint256) {
        if (announcements[minter] != 0) return 0;
        uint256 validityStart = ZCHF.minters(minter);
        if (validityStart == 0) return 0; // minter does not exist
        if (validityStart <= block.timestamp) return 0; // minter is already approved
        return rewardPool() / 10; // reward the caller with 10% of the reward pool for helping to enforce the application period
    }

    /**
     * @notice Veto a minter that was not announced through the MinterGovernance
     * @param minter The minter to veto
     * 
          * @dev To find the candidates for the 'minter' parameter, look for MinterApplied events emitted by the Frankencoin contract
     * after this contract was deployed and that is not accompanied by a MinterAnnounced event emited from this contract.
     */
    function denyUnannouncedMinter(address minter) external {
        if (announcements[minter] != 0) revert MinterCorrectlyAnnounced();
        uint256 reward = checkReward(minter);
        ZCHF.denyMinter(minter, defaultHelper(), "FPS2");
        ZCHF.transfer(msg.sender, reward); // reward the caller with 10% of the reward pool for helping to enforce the announcement requirement
        emit Rewarded(msg.sender, reward, address(ZCHF));
    }

    /**
     * Allows qualified FPS2 holders to deny a minter, regardless of whether it was announced or not.
     * No reward is paid out in this case. If you want a reward, call denyUnannouncedMinter instead.
     */
    function denyMinter(address minter, address[] calldata helpers, string calldata message) external onlyQualified(helpers) {
        ZCHF.denyMinter(minter, defaultHelper(), message);
        delete announcements[minter]; // clear the announcement if it exists, so that the minter can be announced and denied again in the future
    }

    // ==================== Position governance ====================

    /**
     * @notice Deny a v1 or v2 minting position on behalf of qualified FPS2 holders. In practice only relevant on mainnet.
     * @param position  The position contract to deny
     * @param helpers   FPS2 holders who delegate their votes to the caller
     * @param message   Reason for the denial
     */
    function denyPosition(address position, address[] calldata helpers, string calldata message) external onlyQualified(helpers) {
        IPosition(position).deny(defaultHelper(), message);
    }

    // TODO: enforce longer position approval process for new collateral when introducing MintingHub3.

}