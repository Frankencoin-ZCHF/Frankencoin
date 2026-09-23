// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MakerInventory, InsufficientInventory} from "../../src/alf/types/MakerInventory.sol";

/// @notice Isolated coverage for the `MakerInventory` capability type: credit/debit/balanceOf
///         accounting and the insufficient-balance guard. Revert paths route through external
///         self-calls so `vm.expectRevert` sees a call frame.
contract MakerInventoryTest is Test {
    MakerInventory internal inventory;

    address internal maker = makeAddr("maker");
    Currency internal currency = Currency.wrap(makeAddr("token"));

    function extDebit(address who, Currency c, uint256 amount) external {
        inventory.debit(who, c, amount);
    }

    function test_creditIncreasesBalance() public {
        inventory.credit(maker, currency, 100);
        assertEq(inventory.balanceOf(maker, currency), 100);
        inventory.credit(maker, currency, 25);
        assertEq(inventory.balanceOf(maker, currency), 125);
    }

    function test_debitDecreasesBalance() public {
        inventory.credit(maker, currency, 100);
        inventory.debit(maker, currency, 60);
        assertEq(inventory.balanceOf(maker, currency), 40);
        inventory.debit(maker, currency, 40);
        assertEq(inventory.balanceOf(maker, currency), 0);
    }

    function test_debit_insufficient_reverts() public {
        inventory.credit(maker, currency, 10);
        vm.expectRevert(abi.encodeWithSelector(InsufficientInventory.selector, maker, currency, 10, 11));
        this.extDebit(maker, currency, 11);
    }

    function test_debit_zeroBalance_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(InsufficientInventory.selector, maker, currency, 0, 1));
        this.extDebit(maker, currency, 1);
    }

    function test_balancesAreMakerAndCurrencyScoped() public {
        address otherMaker = makeAddr("otherMaker");
        Currency otherCurrency = Currency.wrap(makeAddr("otherToken"));

        inventory.credit(maker, currency, 100);
        assertEq(inventory.balanceOf(otherMaker, currency), 0);
        assertEq(inventory.balanceOf(maker, otherCurrency), 0);
    }

    function testFuzz_creditDebitRoundtrip(uint128 creditAmount, uint128 debitAmount) public {
        inventory.credit(maker, currency, creditAmount);
        if (debitAmount > creditAmount) {
            vm.expectRevert(
                abi.encodeWithSelector(InsufficientInventory.selector, maker, currency, creditAmount, debitAmount)
            );
            this.extDebit(maker, currency, debitAmount);
        } else {
            inventory.debit(maker, currency, debitAmount);
            assertEq(inventory.balanceOf(maker, currency), uint256(creditAmount) - debitAmount);
        }
    }
}
