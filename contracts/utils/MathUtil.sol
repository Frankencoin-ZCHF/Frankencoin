// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @title Functions for share valuation
 */
contract MathUtil {
    
    uint256 internal constant ONE_DEC18 = 10 ** 18;

    // Let's go for 12 digits of precision (18-6)
    uint256 internal constant THRESH_DEC18 = 10 ** 6;

    /**
     * @notice Cubic root with Halley approximation
     *         Number 1e18 decimal
     * @param _v     number for which we calculate x**(1/3)
     * @return returns _v**(1/3)
     */
    function _cubicRoot(uint256 _v) internal pure returns (uint256) {
        // Good first guess for _v slightly above 1.0, which is often the case in the Frankencoin system
        uint256 x = _v > ONE_DEC18 && _v < 10 ** 19 ? (_v - ONE_DEC18) / 3 + ONE_DEC18 : ONE_DEC18;
        uint256 diff;
        do {
            uint256 powX3 = _mulD18(_mulD18(x, x), x);
            uint256 xnew = x * (powX3 + 2 * _v) / (2 * powX3 + _v);
            diff = xnew > x ? xnew - x : x - xnew;
            x = xnew;
        } while (diff > THRESH_DEC18);
        return x;
    }

    function _mulD18(uint256 _a, uint256 _b) internal pure returns (uint256) {
        return (_a * _b) / ONE_DEC18;
    }

    function _divD18(uint256 _a, uint256 _b) internal pure returns (uint256) {
        return (_a * ONE_DEC18) / _b;
    }

    function _power3(uint256 _x) internal pure returns (uint256) {
        return _mulD18(_mulD18(_x, _x), _x);
    }

    function _eightPower(uint256 _x) internal pure returns (uint256) {
        uint256 x2 = _mulD18(_x, _x);
        uint256 x4 = _mulD18(x2, x2);
        return _mulD18(x4, x4);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
