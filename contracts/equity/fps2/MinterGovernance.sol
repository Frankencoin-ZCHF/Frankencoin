// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../../stablecoin/IFrankencoin.sol";
import "../Governance.sol";

/**
 * @title MinterGovernance
 * @dev Module to govern adding new minting modules to Frankencoin
 */
abstract contract MinterGovernance is Governance {
    
    // --- Constants ---
    uint256 public constant MIN_APPLICATION_FEE = 5000 ether;

    // --- Constants ---
    uint256 public constant MIN_APPLICATION_PERIOD = 90 days;
    
    // --- Announcement tracking for minters ---
    mapping(address minter => uint256 timestamp) public announcements;

    // --- References to other contracts ---
    IFrankencoin public immutable ZCHF;
    IGovernance public immutable GOV2;
    address private immutable MAINNET_FPS2;
    
    event MinterAnnounced(address indexed who, address indexed minter, uint256 timestamp);
    event Rewarded(address indexed caller, uint256 amount, address token);

    error FeeTooLow();
    error MinterCorrectlyAnnounced();
    error PeriodTooShort();

    /**
     * Instantiate this contract with references to the Frankencoin and FPS2 governance contracts.
     * Caller must make sure that fps2 delegates to this contract, so that qualified FPS2 holders can use the denyMinter function.
     */
    constructor(IFrankencoin zchf_, address mainnetFPS2Address_) {
        ZCHF = zchf_;
        MAINNET_FPS2 = mainnetFPS2Address_;
    }

    // ==================== Minter Suggestion & Veto ====================

    /**
     * @notice Publicly accessible method to suggest a new way of minting Frankencoin.
     *
     * Wraps the existing functionality in Frankencoin to enforce a 90 days application period.
     * The fee is forwarded to Frankencoin. Minters suggested through this contract are recorded
     * and protected from being vetoed through denyMinter.
     */
    function suggestMinter(address _minter, uint256 _applicationPeriod, uint256 _applicationFee, string calldata _message) external {
        if (_applicationPeriod < MIN_APPLICATION_PERIOD) revert PeriodTooShort();
        if (_applicationFee < MIN_APPLICATION_FEE) revert FeeTooLow();
        ZCHF.transferFrom(msg.sender, address(this), _applicationFee);

        // refill the reward pool to contain at least 1000 ZCHF for the MEV bots that will help enforce the application period
        uint256 rewardPoolSize = rewardPool();
        uint256 rewardPoolRefill = rewardPoolSize > 1000 ether ? 0 : 1000 ether - rewardPoolSize; 

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
     * @dev To find the candidates for the 'minter' parameter, look for MinterApplied events emitted by the Frankencoin contract after this contract was deploed and whose minter parameter is not this contract's address.
     */
    function checkReward(address minter) public view returns (uint256) {
        if (announcements[minter] != 0) return 0;
        uint256 validityStart = ZCHF.minters(minter);
        if (validityStart == 0) return 0; // minter does not exist
        if (validityStart <= block.timestamp) return 0; // minter is already approved
        return rewardPool() / 10; // reward the caller with 10% of the reward pool for helping to enforce the application period
    }

    /**
     * @notice Veto a minter that was not announced through the MinterGovernance after MinterGovernance was deployed.
     * @param minter The minter to veto
     * 
     * @dev To find the candidates for the 'minter' parameter, look for MinterApplied events emitted by the Frankencoin contract after this contract was deploed and whose minter parameter is not this contract's address.
     */
    function denyUnannouncedMinter(address minter) external {
        if (announcements[minter] != 0) revert MinterCorrectlyAnnounced();
        uint256 reward = checkReward(minter);
        ZCHF.denyMinter(minter, fps2AsHelper(), "Minters must be suggested through the FPS2 contract");
        ZCHF.transfer(msg.sender, reward); // reward the caller with 10% of the reward pool for helping to enforce the announcement requirement
        emit Rewarded(msg.sender, reward, address(ZCHF));
    }

    /**
     * Allows qualified FPS2 holders to deny a minter, regardless of whether it was announced or not.
     * No reward is paid out in this case. If you want a reward, call denyUnannouncedMinter instead.
     */
    function denyMinter(address minter, address[] calldata helpers, string calldata message) external {
        checkQualified(msg.sender, helpers);
        ZCHF.denyMinter(minter, fps2AsHelper(), message);
    }

    function fps2AsHelper() internal view returns (address[] memory) {
        address[] memory helper = new address[](1);
        helper[0] = address(MAINNET_FPS2);
        return helper;
    }

}