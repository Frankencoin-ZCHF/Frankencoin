// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import {AggregatorHookMiner} from "../../src/aggregator-hooks/utils/AggregatorHookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

contract AggregatorHookMinerTest is Test {
    /// @notice Test that the first byte mask calculation is correct
    function test_firstByteMask() public pure {
        // The mask should select bits 152-159 (the most significant byte of a 160-bit address)
        uint160 firstByteMask = uint160(0xFF) << 152;

        // Expected: 0xFF followed by 38 zero hex chars = 0xFF * 2^152
        uint160 expectedMask = uint160(0xFF) << 152;
        assertEq(firstByteMask, expectedMask);

        // Test extracting first byte from an address
        address testAddr = address(uint160(0xC2) << 152 | 0xAABBCCDD112233445566778899AABBCCDDEEFF);
        uint160 extracted = uint160(testAddr) & firstByteMask;
        uint160 expected = uint160(0xC2) << 152;

        assertEq(extracted, expected, "First byte extraction failed");
    }

    /// @notice Test that desiredFirstByte is computed correctly
    function test_desiredFirstByte() public pure {
        uint8 firstByte = 0xC2;
        uint160 desiredFirstByte = uint160(firstByte) << 152;

        // Should be 0xC2 shifted to the highest byte position
        uint160 expected = uint160(0xC2) << 152;
        assertEq(desiredFirstByte, expected);
    }

    /// @notice Test computeAddress produces valid addresses
    function test_computeAddress() public pure {
        address deployer = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);
        bytes memory creationCodeWithArgs = hex"deadbeef";

        // Compute a few addresses and verify they're non-zero
        for (uint256 salt = 0; salt < 10; salt++) {
            address computed = AggregatorHookMiner.computeAddress(deployer, salt, creationCodeWithArgs);
            assertTrue(computed != address(0), "Computed address should not be zero");
        }
    }

    /// @notice Debug test - count how many addresses match just the first byte vs just flags
    function test_matchRates() public pure {
        address deployer = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);
        bytes memory creationCodeWithArgs = hex"deadbeef1234567890";

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );
        uint160 FLAG_MASK = Hooks.ALL_HOOK_MASK;
        flags = flags & FLAG_MASK;

        uint8 firstByte = 0xC2;
        uint160 firstByteMask = uint160(0xFF) << 152;
        uint160 desiredFirstByte = uint160(firstByte) << 152;

        uint256 flagMatches = 0;
        uint256 byteMatches = 0;
        uint256 bothMatches = 0;
        uint256 iterations = 100000;

        for (uint256 salt = 0; salt < iterations; salt++) {
            address hookAddress = AggregatorHookMiner.computeAddress(deployer, salt, creationCodeWithArgs);

            bool flagMatch = (uint160(hookAddress) & FLAG_MASK) == flags;
            bool byteMatch = (uint160(hookAddress) & firstByteMask) == desiredFirstByte;

            if (flagMatch) flagMatches++;
            if (byteMatch) byteMatches++;
            if (flagMatch && byteMatch) bothMatches++;
        }

        console.log("Iterations:", iterations);
        console.log("Flag matches:", flagMatches);
        console.log("Byte matches:", byteMatches);
        console.log("Both matches:", bothMatches);

        // Expected: ~6 flag matches per 100k (1 in 16384)
        // Expected: ~390 byte matches per 100k (1 in 256)
        // Expected: ~0.024 both matches per 100k (1 in 4.2M)

        // Flag matches should be roughly 100000 / 16384 ≈ 6
        assertTrue(flagMatches > 0 || iterations < 16384, "Should have some flag matches");

        // Byte matches should be roughly 100000 / 256 ≈ 390
        assertTrue(byteMatches > 200, "Should have many byte matches");
    }
}
