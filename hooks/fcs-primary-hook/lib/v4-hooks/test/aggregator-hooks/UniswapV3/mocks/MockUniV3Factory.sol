// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    IUniswapV3Factory
} from "../../../../src/aggregator-hooks/implementations/UniswapV3/interfaces/IUniswapV3Factory.sol";

contract MockUniV3Factory is IUniswapV3Factory {
    mapping(bytes32 => address) internal pools;

    function setPool(address tokenA, address tokenB, uint24 fee_, address pool) external {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pools[keccak256(abi.encode(t0, t1, fee_))] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee_) external view override returns (address pool) {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pool = pools[keccak256(abi.encode(t0, t1, fee_))];
    }
}
