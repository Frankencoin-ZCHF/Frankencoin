// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../utils/MathUtil.sol";

contract TestMathUtil is MathUtil {

    uint256 public result;

    constructor(){
        result = 1;
    }

    // make it a transaction so we can measure gas costs in our tests
    function cubicRoot(uint256 a, bool recordResult) external {
        uint256 r = _cubicRoot(a); 
        if (recordResult){
            result = r;
        }
    }

    function calculateShares(uint256 totalShares, uint256 capitalBefore, uint256 investment) external pure returns (uint256) {
        uint256 newTotalShares = _mulD18(totalShares, _cubicRoot(_divD18(capitalBefore + investment, capitalBefore)));
        return newTotalShares - totalShares;
    }

    function mulD18(uint256 _a, uint256 _b) external pure returns (uint256) {
        return _mulD18(_a, _b);
    }

    function divD18(uint256 _a, uint256 _b) external pure returns (uint256) {
        return _divD18(_a, _b);
    }

    function power3(uint256 _x) external pure returns (uint256) {
        return _power3(_x);
    }
}
