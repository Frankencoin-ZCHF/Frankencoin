// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../../erc20/IERC20.sol";
import "./IPositionV3.sol";

/**
 * @title PositionV3
 * @notice Ultra-minimal collateral vault. All business logic lives in MintingHubV3.
 * @dev Holds ERC20 collateral. Only the hub can instruct transfers out.
 *      Users interact with MintingHubV3 directly — this contract is just a custody address.
 */
contract PositionV3 is IPositionV3 {
    address public immutable override hub;

    error NotHub();

    modifier onlyHub() {
        if (msg.sender != hub) revert NotHub();
        _;
    }

    constructor(address _hub) {
        hub = _hub;
    }

    /**
     * @notice Transfer tokens out of this vault. Only callable by the hub.
     * @dev Used by hub for: collateral withdrawals, challenge collateral return,
     *      forced sale transfers, roll operations.
     */
    function transfer(address token, address to, uint256 amount) external override onlyHub {
        if (amount > 0) {
            IERC20(token).transfer(to, amount);
        }
    }

    /**
     * @notice Set token allowance from this vault. Only callable by the hub.
     * @dev May be needed for certain repay/roll flows where position must
     *      authorize a third-party spend.
     */
    function approve(address token, address spender, uint256 amount) external override onlyHub {
        IERC20(token).approve(spender, amount);
    }
}
