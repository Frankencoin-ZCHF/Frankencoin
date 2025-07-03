// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IPositionFactoryV1 {
    function createNewPosition(
        address _owner,
        address _zchf,
        address _collateral,
        uint256 _minCollateral,
        uint256 _initialLimit,
        uint256 _initPeriodSeconds,
        uint256 _duration,
        uint64 _challengePeriod,
        uint32 _annualInterestPPM,
        uint256 _liqPrice,
        uint32 _reserve
    ) external returns (address);

    function clonePosition(address _existing) external returns (address);
}
