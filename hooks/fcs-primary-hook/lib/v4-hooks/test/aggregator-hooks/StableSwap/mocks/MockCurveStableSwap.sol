// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICurveStableSwap} from "../../../../src/aggregator-hooks/implementations/StableSwap/interfaces/IStableSwap.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockCurveStableSwap
/// @notice Mock Curve StableSwap pool with settable return values for unit tests.
contract MockCurveStableSwap is ICurveStableSwap {
    /// @notice Curve's convention for native ETH (matches StableSwapAggregator)
    address internal constant CURVE_NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address[] public coinsList;
    mapping(uint256 => uint256) public balancesMap;
    uint256 public returnGetDy;
    uint256 public returnExchange;
    bool public revertGetDy;
    bool public revertExchange;

    error GetDyRevert();
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

    function setReturnExchange(uint256 value) external {
        returnExchange = value;
    }

    function setRevertGetDy(bool doRevert) external {
        revertGetDy = doRevert;
    }

    function setRevertExchange(bool doRevert) external {
        revertExchange = doRevert;
    }

    function coins(uint256 i) external view override returns (address) {
        if (i >= coinsList.length) return address(0);
        return coinsList[i];
    }

    function balances(uint256 i) external view override returns (uint256) {
        return balancesMap[i];
    }

    function get_dy(int128 i, int128 j, uint256 dx) external view override returns (uint256) {
        if (revertGetDy) revert GetDyRevert();
        (i, j, dx); // silence unused
        return returnGetDy;
    }

    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external payable override returns (uint256) {
        if (revertExchange) revert ExchangeRevert();
        address tokenIn = coinsList[uint256(uint128(i))];
        address tokenOut = coinsList[uint256(uint128(j))];
        // Transfer tokenIn from caller (native ETH arrives via msg.value)
        if (tokenIn != address(0) && tokenIn != CURVE_NATIVE_ETH) {
            IERC20(tokenIn).transferFrom(msg.sender, address(this), dx);
        } else {
            require(msg.value == dx, "Native input amount mismatch");
        }
        // Transfer tokenOut to caller
        if (tokenOut != address(0) && tokenOut != CURVE_NATIVE_ETH) {
            IERC20(tokenOut).transfer(msg.sender, returnExchange);
        } else {
            (bool ok,) = payable(msg.sender).call{value: returnExchange}("");
            require(ok, "Native transfer failed");
        }
        (min_dy); // silence unused
        return returnExchange;
    }
}
