// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    ICurveStableSwapNG
} from "../../../../src/aggregator-hooks/implementations/StableSwapNG/interfaces/ICurveStableSwapNG.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockCurveStableSwapNG
/// @notice Mock Curve StableSwap NG pool with settable return values for unit tests.
contract MockCurveStableSwapNG is ICurveStableSwapNG {
    address[] public coinsList;
    mapping(uint256 => uint256) public balancesMap;
    uint256 public returnGetDy;
    uint256 public returnGetDx;
    uint256 public returnExchange;
    bool public revertGetDy;
    bool public revertGetDx;
    bool public revertExchange;

    error InvalidIndex();
    error GetDyRevert();
    error GetDxRevert();
    error ExchangeRevert();

    constructor(address[] memory _coins) {
        coinsList = _coins;
    }

    function setCoins(address[] calldata _coins) external {
        coinsList = _coins;
    }

    function setBalance(uint256 index, uint256 balance) external {
        balancesMap[index] = balance;
    }

    function setReturnGetDy(uint256 value) external {
        returnGetDy = value;
    }

    function setReturnGetDx(uint256 value) external {
        returnGetDx = value;
    }

    function setReturnExchange(uint256 value) external {
        returnExchange = value;
    }

    function setRevertGetDy(bool doRevert) external {
        revertGetDy = doRevert;
    }

    function setRevertGetDx(bool doRevert) external {
        revertGetDx = doRevert;
    }

    function setRevertExchange(bool doRevert) external {
        revertExchange = doRevert;
    }

    function N_COINS() external view override returns (uint256) {
        return coinsList.length;
    }

    function coins(uint256 i) external view override returns (address) {
        if (i >= coinsList.length) revert InvalidIndex();
        return coinsList[i];
    }

    function balances(uint256 i) external view override returns (uint256) {
        return balancesMap[i];
    }

    function get_dy(int128 i, int128 j, uint256 dx) external view override returns (uint256) {
        if (revertGetDy) revert GetDyRevert();
        (i, j, dx);
        return returnGetDy;
    }

    function get_dx(int128 i, int128 j, uint256 dy) external view override returns (uint256) {
        if (revertGetDx) revert GetDxRevert();
        (i, j, dy);
        return returnGetDx;
    }

    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy, address receiver)
        external
        override
        returns (uint256)
    {
        if (revertExchange) revert ExchangeRevert();
        // Transfer tokenIn from caller
        IERC20(coinsList[uint256(uint128(i))]).transferFrom(msg.sender, address(this), dx);
        // Transfer tokenOut to receiver
        IERC20(coinsList[uint256(uint128(j))]).transfer(receiver, returnExchange);
        (min_dy); // silence unused
        return returnExchange;
    }
}
