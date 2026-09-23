// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    ISlipstreamFactory
} from "../../../../src/aggregator-hooks/implementations/Slipstream/interfaces/ISlipstreamFactory.sol";

contract MockSlipstreamFactory is ISlipstreamFactory {
    mapping(bytes32 => address) internal pools;

    function setPool(address tokenA, address tokenB, int24 tickSpacing, address pool) external {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pools[keccak256(abi.encode(t0, t1, tickSpacing))] = pool;
    }

    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view override returns (address pool) {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pool = pools[keccak256(abi.encode(t0, t1, tickSpacing))];
    }
}
