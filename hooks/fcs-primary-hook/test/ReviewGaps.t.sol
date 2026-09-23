// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PrimaryHookTest} from "./PrimaryHook.t.sol";
import {ExternalRouter} from "./ExternalRouter.sol";
import {FCSPrimaryHook} from "../src/FCSPrimaryHook.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {FCSMintRedeem} from "frankencoin/equity/shares/FCSMintRedeem.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Independent-review regressions using the real FCS/Equity/PoolManager fixture.
contract ReviewGapsTest is PrimaryHookTest {
    using PoolIdLibrary for PoolKey;
    using TransientStateLibrary for IPoolManager;

    bytes32 constant EXECUTION_TOPIC = keccak256("PrimaryExecution(bytes32,address,bool,uint256,uint256)");
    bytes32 constant ROUTER_TOPIC = keccak256("PrimarySwap(address,address,bool,uint256,uint256)");

    function test_hookExecutionEventBundledBuy() public {
        _eventSwap(true, false, 1000e18);
    }

    function test_hookExecutionEventBundledSell() public {
        _eventSwap(false, false, 1e18);
    }

    function test_hookExecutionEventExternalBuy() public {
        _eventSwap(true, true, 1000e18);
    }

    function test_hookExecutionEventExternalSell() public {
        _eventSwap(false, true, 1e18);
    }

    function testFuzz_hookExecutionEventExcludesGifts(uint96 raw, bool buy, bool externalRoute) public {
        // Ambient balances cannot become reported volume in either direction or through either router.
        zchf.transfer(address(hook), 1e18);
        fcs.transfer(address(hook), 1e18);
        zchf.transfer(address(manager), 1e18);
        fcs.transfer(address(manager), 1e18);
        _eventSwap(buy, externalRoute, bound(uint256(raw), 1e12, buy ? 100_000e18 : 90e18));
        assertEq(zchf.balanceOf(address(hook)), 1e18);
        assertEq(fcs.balanceOf(address(hook)), 1e18);
        assertEq(zchf.balanceOf(address(manager)), 1e18);
        assertEq(fcs.balanceOf(address(manager)), 1e18);
    }

    function _eventSwap(bool buy, bool externalRoute, uint256 amount) internal {
        ExternalRouter ext;
        if (externalRoute) ext = _externalRouter();
        IERC20 input = IERC20(buy ? address(zchf) : address(fcs));
        IERC20 output = IERC20(buy ? address(fcs) : address(zchf));
        uint256 beforeInput = input.balanceOf(alice);
        uint256 beforeOutput = output.balanceOf(alice);
        vm.recordLogs();
        uint256 out = _swap(buy, amount, 1, ext);
        Vm.Log[] memory logs = _executionLogs(vm.getRecordedLogs());
        assertEq(logs.length, 1, "missing hook-level execution event");
        _assertExecution(logs[0], externalRoute ? address(ext) : address(router), buy, amount, out);
        assertEq(beforeInput - input.balanceOf(alice), amount);
        assertEq(output.balanceOf(alice) - beforeOutput, out);
    }

    function test_hookExecutionEventForEachExternalRoundtripHop() public {
        ExternalRouter ext = _externalRouter();
        uint256 amount = 1000e18;
        uint256 intermediate = fcs.previewDeposit(amount);
        uint256 beforeCash = zchf.balanceOf(alice);
        uint256 beforeShares = fcs.balanceOf(alice);
        vm.recordLogs();
        vm.prank(alice);
        uint256 out = ext.swap(key, _params(true, -int256(amount)), abi.encode(uint256(1), block.timestamp), true, true);
        Vm.Log[] memory logs = _executionLogs(vm.getRecordedLogs());
        assertEq(logs.length, 2, "one execution log per primary hop");
        _assertExecution(logs[0], address(ext), true, amount, intermediate);
        _assertExecution(logs[1], address(ext), false, intermediate, out);
        assertEq(zchf.balanceOf(alice), beforeCash - amount + out);
        assertEq(fcs.balanceOf(alice), beforeShares);
        _clean(address(ext));
    }

    function test_noExecutionEventOnBundledBuyMinOutRevert() public {
        _minimumRevert(true, false);
    }

    function test_noExecutionEventOnBundledSellMinOutRevert() public {
        _minimumRevert(false, false);
    }

    function test_noExecutionEventOnExternalBuyMinOutRevert() public {
        _minimumRevert(true, true);
    }

    function test_noExecutionEventOnExternalSellMinOutRevert() public {
        _minimumRevert(false, true);
    }

    function _minimumRevert(bool buy, bool externalRoute) internal {
        ExternalRouter ext;
        if (externalRoute) ext = _externalRouter();
        uint256 amount = buy ? 1000e18 : 1e18;
        uint256 quote = buy ? fcs.previewDeposit(amount) : fcs.previewRedeem(amount);
        bytes32 beforeState = _economicState();
        // This specifically proves the hook rejects minOut before emitting. recordLogs can
        // include reverted-frame trace logs; it is not a substitute for transaction receipts.
        vm.recordLogs();
        vm.expectRevert(_wrapped(abi.encodeWithSelector(FCSPrimaryHook.InsufficientOutput.selector, quote, quote + 1)));
        _swap(buy, amount, quote + 1, ext);
        assertEq(_executionLogs(vm.getRecordedLogs()).length, 0, "rejected minimum must not emit execution");
        assertEq(_economicState(), beforeState);
        _clean(externalRoute ? address(ext) : address(router));
    }

    function test_noExecutionEventOnDisabledRedemptionBothRouters() public {
        ExternalRouter ext = _externalRouter();
        fps.invest(80_000_000e18, 0);
        vm.warp(block.timestamp + 100 days);
        assertFalse(fcs.isBinding());
        bytes32 beforeState = _economicState();
        for (uint256 i; i < 2; ++i) {
            vm.recordLogs();
            vm.expectRevert(_wrapped(abi.encodeWithSelector(FCSMintRedeem.RedemptionsDisabled.selector)));
            _swap(false, 1e18, 1, i == 0 ? ExternalRouter(address(0)) : ext);
            assertEq(_executionLogs(vm.getRecordedLogs()).length, 0);
            assertEq(_economicState(), beforeState);
        }
        _clean(address(ext));
    }

    function test_contractWalletPayerBuy() public {
        _walletSwap(true);
    }

    function test_contractWalletPayerSell() public {
        _walletSwap(false);
    }

    function _walletSwap(bool buy) internal {
        OwnerWallet wallet = new OwnerWallet(alice);
        uint256 amount = buy ? 1000e18 : 1e18;
        IERC20 input = IERC20(buy ? address(zchf) : address(fcs));
        IERC20 output = IERC20(buy ? address(fcs) : address(zchf));
        input.transfer(address(wallet), amount);
        uint256 ownerInput = input.balanceOf(alice);
        uint256 ownerOutput = output.balanceOf(alice);
        uint256 quote = buy ? fcs.previewDeposit(amount) : fcs.previewRedeem(amount);
        // Actual wallet calls: no impersonation of the contract payer, and no EOA-only shortcut.
        vm.prank(alice);
        wallet.execute(address(input), abi.encodeCall(IERC20.approve, (address(router), amount)));
        vm.recordLogs();
        vm.prank(alice);
        bytes memory result = wallet.execute(
            address(router),
            abi.encodeCall(router.swapExactInput, (buy, amount, quote, address(wallet), block.timestamp))
        );
        uint256 out = abi.decode(result, (uint256));
        assertEq(out, quote);
        assertEq(input.balanceOf(address(wallet)), 0);
        assertEq(output.balanceOf(address(wallet)), out);
        assertEq(input.balanceOf(alice), ownerInput);
        assertEq(output.balanceOf(alice), ownerOutput);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log[] memory execution = _executionLogs(logs);
        assertEq(execution.length, 1);
        _assertExecution(execution[0], address(router), buy, amount, out);
        uint256 routerEvents;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(router) && logs[i].topics[0] == ROUTER_TOPIC) {
                ++routerEvents;
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(address(wallet)))), "payer is wallet, not owner");
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(address(wallet)))));
                assertEq(logs[i].data, abi.encode(buy, amount, out));
            }
        }
        assertEq(routerEvents, 1);
        _clean(address(router));
    }

    function test_directBuyEqualsAdapterFromIdenticalSnapshot() public {
        _compareDirect(true, 1000e18, false);
    }

    function test_directSellEqualsAdapterFromIdenticalSnapshot() public {
        _compareDirect(false, 1e18, false);
    }

    function testFuzz_directEqualsAdapterFromIdenticalSnapshot(uint96 raw, bool buy, bool externalRoute) public {
        _compareDirect(buy, bound(uint256(raw), 1e12, buy ? 100_000e18 : 90e18), externalRoute);
    }

    function _compareDirect(bool buy, uint256 amount, bool externalRoute) internal {
        ExternalRouter ext;
        if (externalRoute) ext = _externalRouter();
        // Give Alice nonzero vote age so a same-timestamp balance-only comparison is not sufficient.
        vm.warp(block.timestamp + 2 days);
        assertGt(fcs.votes(alice), 0);
        vm.prank(alice);
        zchf.approve(address(fcs), type(uint256).max);
        bytes32 beforeState = _economicState();
        uint256 snapshot = vm.snapshotState();
        vm.prank(alice);
        uint256 direct = buy ? fcs.deposit(amount, alice) : fcs.redeem(amount, alice, alice);
        bytes32 directState = _economicState();
        assertTrue(vm.revertToStateAndDelete(snapshot));
        assertEq(_economicState(), beforeState, "direct execution must be fully rolled back before adapter branch");
        uint256 adapted = _swap(buy, amount, direct, ext);
        assertEq(adapted, direct, "executed output, not just a preview comparison");
        assertEq(_economicState(), directState, "same wallet, supply, reserves, discount, votes and gates");
        _clean(externalRoute ? address(ext) : address(router));
    }

    function test_staleSellQuoteAfterCompetingRedemption() public {
        (uint256 stale, bool available,) = hook.quoteExactInput(false, 1e18);
        assertTrue(available);
        // A different real FCS holder redeems before Alice's quote executes.
        fcs.redeem(100e18, address(this), address(this));
        (uint256 fresh, bool stillAvailable,) = hook.quoteExactInput(false, 1e18);
        assertTrue(stillAvailable);
        assertLt(fresh, stale);
        assertEq(fcs.recentlyRedeemed(), 100e18);
        bytes32 afterCompetitor = _economicState();
        vm.recordLogs();
        vm.expectRevert(_wrapped(abi.encodeWithSelector(FCSPrimaryHook.InsufficientOutput.selector, fresh, stale)));
        _swap(false, 1e18, stale, ExternalRouter(address(0)));
        assertEq(_executionLogs(vm.getRecordedLogs()).length, 0);
        assertEq(_economicState(), afterCompetitor, "failed stale swap cannot undo or add to competing redemption");
        _clean(address(router));
        assertEq(_swap(false, 1e18, fresh, ExternalRouter(address(0))), fresh);
        assertEq(fcs.recentlyRedeemed(), 101e18);
        _clean(address(router));
    }

    function test_redemptionRecoveryImmediatelyAfterRedemption() public {
        _recoveryExecution(0);
    }

    function test_redemptionRecoveryHalfway() public {
        _recoveryExecution(3 days + 12 hours);
    }

    function test_redemptionRecoveryOneSecondBeforeSevenDays() public {
        _recoveryExecution(7 days - 1);
    }

    function test_redemptionRecoveryExactlySevenDays() public {
        _recoveryExecution(7 days);
    }

    function test_redemptionRecoveryOneSecondAfterSevenDays() public {
        _recoveryExecution(7 days + 1);
    }

    function _recoveryExecution(uint256 elapsed) internal {
        uint256 redeemed = 100e18;
        fcs.redeem(redeemed, address(this), address(this));
        uint256 anchor = fcs.redemptionAnchor();
        uint256 period = fcs.RECOVERY_PERIOD();
        assertEq(period, 7 days);
        vm.warp(anchor + elapsed);
        uint256 recent = elapsed >= period ? 0 : redeemed * (period - elapsed) / period;
        assertEq(fcs.weightedRecentRedemptions(), recent);
        assertEq(fcs.recentlyRedeemed(), redeemed, "stored anchor amount only changes on execution");
        assertEq(fcs.redemptionAnchor(), anchor);
        if (elapsed < period) {
            assertGt(recent, 0);
            assertLt(fcs.currentDiscount(0), 1e18);
            assertLt(fcs.bid(), fcs.ask());
        } else {
            assertEq(fcs.currentDiscount(0), 1e18);
            assertEq(fcs.bid(), fcs.ask());
        }
        (uint256 quoted, bool available,) = hook.quoteExactInput(false, 1e18);
        assertTrue(available);
        assertEq(quoted, fcs.previewRedeem(1e18));
        // Recovery removes past-volume discount, not this redemption's own price impact or FPS fees.
        assertLt(quoted, fps.calculateProceeds(1e18));
        uint256 beforeCash = zchf.balanceOf(alice);
        assertEq(_swap(false, 1e18, quoted, ExternalRouter(address(0))), quoted);
        assertEq(zchf.balanceOf(alice), beforeCash + quoted);
        assertEq(fcs.recentlyRedeemed(), recent + 1e18);
        assertEq(fcs.weightedRecentRedemptions(), recent + 1e18);
        assertEq(fcs.redemptionAnchor(), anchor + elapsed);
        _clean(address(router));
    }

    function test_redemptionQuoteRecoversThenPlateausAtSevenDays() public {
        fcs.redeem(100e18, address(this), address(this));
        uint256 anchor = fcs.redemptionAnchor();
        uint256 immediate = fcs.previewRedeem(1e18);
        vm.warp(anchor + 7 days - 1);
        uint256 beforeBoundary = fcs.previewRedeem(1e18);
        assertGt(beforeBoundary, immediate);
        assertGt(fcs.weightedRecentRedemptions(), 0);
        vm.warp(anchor + 7 days);
        uint256 atBoundary = fcs.previewRedeem(1e18);
        assertGt(atBoundary, beforeBoundary);
        assertEq(fcs.weightedRecentRedemptions(), 0);
        vm.warp(anchor + 7 days + 1);
        assertEq(fcs.previewRedeem(1e18), atBoundary);
        assertEq(fcs.weightedRecentRedemptions(), 0);
        (uint256 quoted, bool available,) = hook.quoteExactInput(false, 1e18);
        assertTrue(available);
        assertEq(quoted, atBoundary);
    }

    function _externalRouter() internal returns (ExternalRouter ext) {
        ext = new ExternalRouter(manager);
        vm.startPrank(alice);
        zchf.approve(address(ext), type(uint256).max);
        fcs.approve(address(ext), type(uint256).max);
        vm.stopPrank();
    }

    function _swap(bool buy, uint256 amount, uint256 minimum, ExternalRouter ext) internal returns (uint256) {
        vm.prank(alice);
        if (address(ext) == address(0)) return router.swapExactInput(buy, amount, minimum, alice, block.timestamp);
        return ext.swap(key, _params(buy, -int256(amount)), abi.encode(minimum, block.timestamp), true, false);
    }

    function _executionLogs(Vm.Log[] memory logs) internal view returns (Vm.Log[] memory filtered) {
        filtered = new Vm.Log[](logs.length);
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics.length != 0 && logs[i].topics[0] == EXECUTION_TOPIC)
            {
                filtered[count++] = logs[i];
            }
        }
        assembly ("memory-safe") {
            mstore(filtered, count)
        }
    }

    function _assertExecution(Vm.Log memory entry, address route, bool buy, uint256 amount, uint256 out) internal view {
        assertEq(entry.topics.length, 3);
        assertEq(entry.topics[1], PoolId.unwrap(key.toId()));
        assertEq(entry.topics[2], bytes32(uint256(uint160(route))), "indexed caller must be the router, not payer");
        assertTrue(route != alice);
        assertEq(entry.data, abi.encode(buy, amount, out));
    }

    function _wrapped(bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.beforeSwap.selector,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _economicState() internal view returns (bytes32) {
        bytes32 balances = keccak256(
            abi.encode(
                zchf.balanceOf(alice),
                fcs.balanceOf(alice),
                zchf.balanceOf(address(this)),
                fcs.balanceOf(address(this)),
                zchf.balanceOf(address(fcs)),
                zchf.balanceOf(address(fps)),
                fps.balanceOf(address(fcs)),
                zchf.totalSupply(),
                fcs.totalSupply(),
                fps.totalSupply(),
                zchf.equity(),
                fcs.totalAssets()
            )
        );
        bytes32 votes = keccak256(
            abi.encode(
                fcs.votes(alice),
                fcs.totalVotes(),
                fps.votes(address(fcs)),
                fps.totalVotes(),
                fcs.isBinding(),
                fps.canRedeem(address(fcs))
            )
        );
        return keccak256(
            abi.encode(
                balances,
                votes,
                fcs.recentlyRedeemed(),
                fcs.redemptionAnchor(),
                fcs.weightedRecentRedemptions(),
                fcs.ask(),
                fcs.bid()
            )
        );
    }

    function _clean(address route) internal view {
        address[3] memory holders = [address(manager), address(hook), route];
        for (uint256 i; i < holders.length; ++i) {
            assertEq(zchf.balanceOf(holders[i]), 0);
            assertEq(fcs.balanceOf(holders[i]), 0);
            assertEq(manager.currencyDelta(holders[i], key.currency0), 0);
            assertEq(manager.currencyDelta(holders[i], key.currency1), 0);
        }
    }
}

/// @dev Minimal owner-authorized contract wallet; uses actual CALLs to tokens and router.
contract OwnerWallet {
    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function execute(address target, bytes calldata data) external returns (bytes memory result) {
        require(msg.sender == owner, "not owner");
        bool ok;
        (ok, result) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
    }
}
