// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StableFeeCalculation} from "../../../src/stable/libraries/StableFeeCalculation.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

/// @title StableFeeCalculationSpreadsheetTest
/// @notice Validates StableFeeCalculation library against spreadsheet-derived test vectors
/// @dev Test data is loaded from test/stable/data/fee_calculation_test_data.csv
/// CSV format: priceE5,closeFeeE12,farFeeE12,targetFeeE12,block1,...,block1000 (all pre-scaled integers)
contract StableFeeCalculationSpreadsheetTest is Test {
    uint24 constant OPTIMAL_FEE_E6 = 90;
    uint160 constant REF = uint160(FixedPoint96.Q96); // reference sqrt price (1:1)
    uint256 constant TOLERANCE_E12 = 15_000; //15_000 / 1e12 = 0.000000015 = 0.0000015%

    /// @dev k = 0.99 in Q24 format: floor(0.99 * 2^24) = 16609443
    uint256 constant K_Q24 = 16_609_443;

    string constant DATA_PATH = "test/stable/data/fee_calculation_test_data.csv";

    struct PriceData {
        uint256 priceRatioX96;
        int256 closeFeeE12;
        uint256 farFeeE12;
        uint256 targetFeeE12;
    }

    function _computePriceData(uint256 priceE5) internal pure returns (PriceData memory data) {
        uint256 ammPriceX192 = uint256(REF) * uint256(REF) * priceE5 / 100_000;
        uint160 sqrtAmmPriceX96 = uint160(FixedPointMathLib.sqrt(ammPriceX192));
        data.priceRatioX96 = StableFeeCalculation.calculatePriceRatioX96(sqrtAmmPriceX96, REF);
        data.closeFeeE12 = StableFeeCalculation.calculateCloseBoundaryFee(data.priceRatioX96, OPTIMAL_FEE_E6);
        data.farFeeE12 = StableFeeCalculation.calculateFarBoundaryFee(data.priceRatioX96, OPTIMAL_FEE_E6);
        // Safe to cast: all test prices are outside the optimal range, so closeFeeE12 is always positive
        data.targetFeeE12 = data.farFeeE12 - uint256(data.closeFeeE12) / 2;
    }

    function test_spreadsheetData_closeFee_farFee_targetFee() public view {
        string memory csv = vm.readFile(DATA_PATH);
        string[] memory lines = vm.split(csv, "\n");

        uint256 rowCount;
        for (uint256 i = 1; i < lines.length; i++) {
            if (bytes(lines[i]).length == 0) continue;

            string[] memory cols = vm.split(lines[i], ",");

            uint256 priceE5 = vm.parseUint(cols[0]);
            uint256 expectedCloseFeeE12 = vm.parseUint(cols[1]);
            uint256 expectedFarFeeE12 = vm.parseUint(cols[2]);
            uint256 expectedTargetFeeE12 = vm.parseUint(cols[3]);

            PriceData memory data = _computePriceData(priceE5);

            assertApproxEqAbs(uint256(data.closeFeeE12), expectedCloseFeeE12, TOLERANCE_E12, "closeFee mismatch");
            assertApproxEqAbs(data.farFeeE12, expectedFarFeeE12, TOLERANCE_E12, "farFee mismatch");
            assertApproxEqAbs(data.targetFeeE12, expectedTargetFeeE12, TOLERANCE_E12, "targetFee mismatch");

            rowCount++;
        }

        assertGt(rowCount, 0, "No rows parsed from CSV");
    }

    function test_spreadsheetData_decayingFee() public view {
        // Block counts corresponding to CSV columns 4..16
        uint256[13] memory blocks = [uint256(1), 2, 3, 4, 5, 10, 20, 50, 100, 200, 500, 750, 1000];

        string memory csv = vm.readFile(DATA_PATH);
        string[] memory lines = vm.split(csv, "\n");

        uint256 rowCount;
        for (uint256 i = 1; i < lines.length; i++) {
            if (bytes(lines[i]).length == 0) continue;

            string[] memory cols = vm.split(lines[i], ",");
            uint256 priceE5 = vm.parseUint(cols[0]);

            PriceData memory data = _computePriceData(priceE5);

            for (uint256 j = 0; j < 13; j++) {
                uint256 expectedDecayE12 = vm.parseUint(cols[4 + j]);
                uint256 actualDecayE12 =
                    StableFeeCalculation.calculateDecayingFee(data.targetFeeE12, data.farFeeE12, K_Q24, blocks[j]);
                assertApproxEqAbs(actualDecayE12, expectedDecayE12, TOLERANCE_E12, "decayingFee mismatch");
            }

            rowCount++;
        }

        assertGt(rowCount, 0, "No rows parsed from CSV");
    }
}
