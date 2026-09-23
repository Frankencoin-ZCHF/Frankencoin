// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Position.sol";
import "../stablecoin/IFrankencoin.sol";

contract PositionFactory {
    /**
     * Create a completely new position in a newly deployed contract.
     * Must be called through minting hub to be recognized as valid position.
     */
    function createNewPosition(
        address _owner,
        address _zchf,
        address _collateral,
        uint256 _minCollateral,
        uint256 _initialLimit,
        uint40 _initPeriod,
        uint40 _duration,
        uint40 _challengePeriod,
        uint24 _riskPremiumPPM,
        uint256 _liqPrice,
        uint24 _reserve
    ) external returns (address) {
        return
            address(
                new Position(
                    _owner,
                    msg.sender,
                    _zchf,
                    _collateral,
                    _minCollateral,
                    _initialLimit,
                    _initPeriod,
                    _duration,
                    _challengePeriod,
                    _riskPremiumPPM,
                    _liqPrice,
                    _reserve
                )
            );
    }

    /**
     * @notice clone an existing position. This can be a clone of another clone,
     * or an original position.
     * @param _parent address of the position we want to clone
     * @return address of the newly created clone position
     */
    function clonePosition(address _parent) external returns (address) {
        Position parent = Position(_parent);
        parent.assertCloneable();
        Position clone = Position(_createClone(parent.original()));
        return address(clone);
    }

    // github.com/optionality/clone-factory/blob/32782f82dfc5a00d103a7e61a17a5dedbd1e8e9d/contracts/CloneFactory.sol
    function _createClone(address target) internal returns (address result) {
        bytes20 targetBytes = bytes20(target);
        assembly {
            let clone := mload(0x40)
            mstore(clone, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(clone, 0x14), targetBytes)
            mstore(add(clone, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            result := create(0, clone, 0x37)
        }
        require(result != address(0), "ERC1167: create failed");
    }
}
