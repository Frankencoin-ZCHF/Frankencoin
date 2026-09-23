// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {PrimaryHookTest} from "./PrimaryHook.t.sol";
import {ExternalRouter} from "./ExternalRouter.sol";
import {FCSPrimaryHook} from "../src/FCSPrimaryHook.sol";
import {FCSPrimaryRouter} from "../src/FCSPrimaryRouter.sol";
import {BaseTokenWrapperHook} from "../src/base/BaseTokenWrapperHook.sol";
import {IFCS} from "../src/interfaces/IFCS.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FCSMintRedeem} from "frankencoin/equity/shares/FCSMintRedeem.sol";

contract SecurityTest is PrimaryHookTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    function _wrapped(bytes4 callback, bytes memory inner) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            inner,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _swapError(bytes4 inner) internal view returns (bytes memory) {
        return _wrapped(IHooks.beforeSwap.selector, abi.encodeWithSelector(inner));
    }

    function _ext() internal returns (ExternalRouter ext) {
        ext = new ExternalRouter(manager);
        vm.startPrank(alice);
        zchf.approve(address(ext), type(uint256).max);
        fcs.approve(address(ext), type(uint256).max);
        vm.stopPrank();
    }

    function _clean() internal view {
        assertEq(zchf.balanceOf(address(hook)), 0);
        assertEq(fcs.balanceOf(address(hook)), 0);
        assertEq(zchf.balanceOf(address(router)), 0);
        assertEq(fcs.balanceOf(address(router)), 0);
        assertEq(zchf.balanceOf(address(manager)), 0);
        assertEq(fcs.balanceOf(address(manager)), 0);
        assertEq(manager.currencyDelta(address(router), key.currency0), 0);
        assertEq(manager.currencyDelta(address(router), key.currency1), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
        assertEq(manager.getLiquidity(key.toId()), 0);
    }

    function _state() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                zchf.balanceOf(alice),
                fcs.balanceOf(alice),
                fcs.totalSupply(),
                fps.totalSupply(),
                zchf.equity(),
                fcs.recentlyRedeemed(),
                fcs.redemptionAnchor(),
                fps.balanceOf(address(fcs)),
                fps.votes(address(fcs)),
                fcs.votes(alice)
            )
        );
    }

    function test_noLPInventoryAndSlot0DoesNotPricePrimary() public {
        assertEq(manager.getLiquidity(key.toId()), 0);
        (uint160 priceBefore,,,) = manager.getSlot0(key.toId());
        vm.prank(alice);
        router.swapExactInput(true, 1000e18, 1, alice, block.timestamp);
        (uint160 priceAfter,,,) = manager.getSlot0(key.toId());
        assertEq(priceBefore, priceAfter);
        _clean();
    }

    function test_externalRouterTwoPrimaryHopsUsesIntermediateCredit() public {
        ExternalRouter ext = _ext();
        uint256 beforeBalance = zchf.balanceOf(alice);
        vm.prank(alice);
        uint256 out =
            ext.swap(key, _params(true, -int256(1000e18)), abi.encode(uint256(1), block.timestamp), true, true);
        assertGt(out, 0);
        assertLt(out, 1000e18);
        assertEq(zchf.balanceOf(alice), beforeBalance - 1000e18 + out);
        _clean();
    }

    function test_directHookCallbackIsUnauthorized() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeSwap(address(router), key, _params(true, -1e18), abi.encode(uint256(1), block.timestamp));
    }

    function test_routerCallbackCannotDrainApprovals() public {
        bytes32 beforeState = _state();
        vm.expectRevert(FCSPrimaryRouter.Unauthorized.selector);
        router.unlockCallback(abi.encode(alice));
        assertEq(_state(), beforeState);
    }

    function test_managerSpoofedCallbackWhenRouterInactiveIsRejected() public {
        vm.prank(address(manager));
        vm.expectRevert(FCSPrimaryRouter.Unauthorized.selector);
        router.unlockCallback(abi.encode(alice));
    }

    function test_missingAllowanceReverts() public {
        vm.startPrank(alice);
        zchf.approve(address(router), 0);
        vm.expectRevert();
        router.swapExactInput(true, 1000e18, 1, alice, block.timestamp);
        vm.stopPrank();
        _clean();
    }

    function test_cannotSpendAnotherUsersApproval() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        router.swapExactInput(true, 1000e18, 1, alice, block.timestamp);
        _clean();
    }

    function test_routerExpired() public {
        vm.prank(alice);
        vm.expectRevert(FCSPrimaryRouter.Expired.selector);
        router.swapExactInput(true, 1000e18, 1, alice, block.timestamp - 1);
        _clean();
    }

    function test_routerRejectsZeroMinimum() public {
        vm.prank(alice);
        vm.expectRevert(FCSPrimaryRouter.InvalidMinimum.selector);
        router.swapExactInput(true, 1000e18, 0, alice, block.timestamp);
    }

    function test_routerRejectsZeroInput() public {
        vm.expectRevert(FCSPrimaryRouter.InvalidAmount.selector);
        router.swapExactInput(true, 0, 1, alice, block.timestamp);
    }

    function test_routerRejectsOverflowInput() public {
        vm.expectRevert(FCSPrimaryRouter.InvalidAmount.selector);
        router.swapExactInput(true, uint256(uint128(type(int128).max)) + 1, 1, alice, block.timestamp);
    }

    function test_routerRejectsInvalidRecipients() public {
        address[4] memory recipients = [address(0), address(router), address(hook), address(manager)];
        for (uint256 i; i < recipients.length; ++i) {
            vm.expectRevert(FCSPrimaryRouter.InvalidRecipient.selector);
            router.swapExactInput(true, 1e18, 1, recipients[i], block.timestamp);
        }
    }

    function test_separateRecipientReceivesOnlyTradeOutput() public {
        uint256 expected = fcs.previewDeposit(1000e18);
        vm.prank(alice);
        router.swapExactInput(true, 1000e18, expected, address(0xB0B), block.timestamp);
        assertEq(fcs.balanceOf(address(0xB0B)), expected);
        _clean();
    }

    function test_hookEnforcesNonzeroMinimumForExternalRouter() public {
        ExternalRouter ext = _ext();
        vm.prank(alice);
        vm.expectRevert(_swapError(FCSPrimaryHook.InvalidMinimum.selector));
        ext.swap(key, _params(true, -1e18), abi.encode(uint256(0), block.timestamp), true, false);
    }

    function test_hookEnforcesDeadlineForExternalRouter() public {
        ExternalRouter ext = _ext();
        vm.prank(alice);
        vm.expectRevert(_swapError(FCSPrimaryHook.Expired.selector));
        ext.swap(key, _params(true, -1e18), abi.encode(uint256(1), block.timestamp - 1), true, false);
    }

    function test_hookRejectsEmptyHookData() public {
        ExternalRouter ext = _ext();
        vm.prank(alice);
        vm.expectRevert(_swapError(FCSPrimaryHook.InvalidHookData.selector));
        ext.swap(key, _params(true, -1e18), "", true, false);
    }

    function testFuzz_hookRejectsMalformedHookData(uint8 length) public {
        vm.assume(length != 64);
        ExternalRouter ext = _ext();
        vm.prank(alice);
        vm.expectRevert(_swapError(FCSPrimaryHook.InvalidHookData.selector));
        ext.swap(key, _params(true, -1e18), new bytes(length), true, false);
    }

    function test_exactOutputBuyRejectedExplicitly() public {
        ExternalRouter ext = _ext();
        vm.prank(alice);
        vm.expectRevert(_swapError(BaseTokenWrapperHook.ExactOutputNotSupported.selector));
        ext.swap(key, _params(true, 1e18), abi.encode(uint256(1), block.timestamp), false, false);
    }

    function test_exactOutputSellRejectedExplicitly() public {
        ExternalRouter ext = _ext();
        vm.prank(alice);
        vm.expectRevert(_swapError(BaseTokenWrapperHook.ExactOutputNotSupported.selector));
        ext.swap(key, _params(false, 1e18), abi.encode(uint256(1), block.timestamp), false, false);
    }

    function test_unfundedRouterCannotRelyOnSingletonInventory() public {
        ExternalRouter ext = _ext();
        zchf.transfer(address(manager), 100e18);
        vm.prank(alice);
        vm.expectRevert(_swapError(FCSPrimaryHook.InputNotPrefunded.selector));
        ext.swap(key, _params(true, -1e18), abi.encode(uint256(1), block.timestamp), false, false);
        assertEq(zchf.balanceOf(address(manager)), 100e18);
    }

    function test_unfundedRouterRejectedWithEmptyManager() public {
        ExternalRouter ext = _ext();
        vm.prank(alice);
        vm.expectRevert(_swapError(FCSPrimaryHook.InputNotPrefunded.selector));
        ext.swap(key, _params(true, -1e18), abi.encode(uint256(1), block.timestamp), false, false);
        _clean();
    }

    function test_addLiquidityRejected() public {
        ExternalRouter ext = _ext();
        vm.expectRevert(
            _wrapped(
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(BaseTokenWrapperHook.LiquidityNotAllowed.selector)
            )
        );
        ext.addLiquidity(key);
    }

    function test_invalidPoolTokensRejected() public {
        PoolKey memory bad = key;
        bad.currency0 = Currency.wrap(address(1));
        vm.expectRevert(
            _wrapped(
                IHooks.beforeInitialize.selector, abi.encodeWithSelector(BaseTokenWrapperHook.InvalidPoolToken.selector)
            )
        );
        manager.initialize(bad, uint160(1 << 96));
    }

    function test_nonzeroPoolFeeRejected() public {
        PoolKey memory bad = key;
        bad.fee = 500;
        vm.expectRevert(
            _wrapped(
                IHooks.beforeInitialize.selector, abi.encodeWithSelector(BaseTokenWrapperHook.InvalidPoolFee.selector)
            )
        );
        manager.initialize(bad, uint160(1 << 96));
    }

    function test_wrongTickSpacingRejected() public {
        PoolKey memory bad = key;
        bad.tickSpacing = 60;
        vm.expectRevert(
            _wrapped(
                IHooks.beforeInitialize.selector, abi.encodeWithSelector(FCSPrimaryHook.InvalidTickSpacing.selector)
            )
        );
        manager.initialize(bad, uint160(1 << 96));
    }

    function test_forgedVictimDuringActiveRequestCannotDrainApproval() public {
        TamperingManager evil = new TamperingManager();
        FCSPrimaryRouter guarded = new FCSPrimaryRouter(IPoolManager(address(evil)), IFCS(address(fcs)), address(hook));
        zchf.approve(address(guarded), type(uint256).max);
        evil.configure(0, address(this));
        uint256 beforeBalance = zchf.balanceOf(address(this));
        vm.prank(alice);
        vm.expectRevert(FCSPrimaryRouter.Unauthorized.selector);
        guarded.swapExactInput(true, 1000e18, 1, alice, block.timestamp);
        assertEq(zchf.balanceOf(address(this)), beforeBalance);
    }

    function test_activeRequestRejectsReentrantUserEntry() public {
        TamperingManager evil = new TamperingManager();
        FCSPrimaryRouter guarded = new FCSPrimaryRouter(IPoolManager(address(evil)), IFCS(address(fcs)), address(hook));
        evil.configure(1, alice);
        vm.prank(alice);
        vm.expectRevert(FCSPrimaryRouter.Reentrancy.selector);
        guarded.swapExactInput(true, 1000e18, 1, alice, block.timestamp);
    }

    function test_replayedValidLookingRequestCannotDrainApproval() public {
        TamperingManager evil = new TamperingManager();
        FCSPrimaryRouter guarded = new FCSPrimaryRouter(IPoolManager(address(evil)), IFCS(address(fcs)), address(hook));
        vm.prank(alice);
        zchf.approve(address(guarded), type(uint256).max);
        bytes memory recorded = abi.encode(FCSPrimaryRouter.Request(alice, alice, true, 1000e18, 1, block.timestamp));
        bytes32 beforeState = _state();
        vm.expectRevert(FCSPrimaryRouter.Unauthorized.selector);
        evil.replay(guarded, recorded);
        assertEq(_state(), beforeState);
    }

    function test_routerConstructorRejectsZeroHook() public {
        vm.expectRevert(bytes4(keccak256("InvalidConfiguration()")));
        new FCSPrimaryRouter(manager, IFCS(address(fcs)), address(0));
    }

    function test_constructorRejectsNoCodeManager() public {
        vm.expectRevert(FCSPrimaryHook.InvalidConfiguration.selector);
        new FCSPrimaryHook(IPoolManager(address(0)), IFCS(address(fcs)));
    }

    function test_constructorRejectsNoCodeFCS() public {
        vm.expectRevert(FCSPrimaryHook.InvalidConfiguration.selector);
        new FCSPrimaryHook(manager, IFCS(address(0)));
    }

    function test_constructorRejectsInconsistentUnderlying() public {
        vm.mockCall(address(fcs), abi.encodeWithSelector(IFCS.ZCHF.selector), abi.encode(address(fps)));
        vm.expectRevert(FCSPrimaryHook.InvalidConfiguration.selector);
        new FCSPrimaryHook(manager, IFCS(address(fcs)));
    }

    function test_buySlippageRollsBackProtocolAndWallets() public {
        uint256 out = fcs.previewDeposit(1000e18);
        bytes32 beforeState = _state();
        vm.prank(alice);
        vm.expectRevert(
            _wrapped(
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(FCSPrimaryHook.InsufficientOutput.selector, out, out + 1)
            )
        );
        router.swapExactInput(true, 1000e18, out + 1, alice, block.timestamp);
        assertEq(_state(), beforeState);
        _clean();
        vm.prank(alice);
        router.swapExactInput(true, 1000e18, out, alice, block.timestamp);
        _clean();
    }

    function test_sellSlippageRollsBackRedemptionDiscountAndSupply() public {
        uint256 out = fcs.previewRedeem(1e18);
        bytes32 beforeState = _state();
        vm.prank(alice);
        vm.expectRevert(
            _wrapped(
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(FCSPrimaryHook.InsufficientOutput.selector, out, out + 1)
            )
        );
        router.swapExactInput(false, 1e18, out + 1, alice, block.timestamp);
        assertEq(_state(), beforeState);
        _clean();
    }

    function test_staleBuyQuoteRevertsAfterCompetingInvestment() public {
        uint256 stale = fcs.previewDeposit(1000e18);
        fcs.deposit(100_000e18, address(this));
        assertLt(fcs.previewDeposit(1000e18), stale);
        bytes32 beforeState = _state();
        vm.prank(alice);
        vm.expectRevert();
        router.swapExactInput(true, 1000e18, stale, alice, block.timestamp);
        assertEq(_state(), beforeState);
        _clean();
    }

    function test_tinyInputCannotSilentlyDonate() public {
        assertEq(fcs.previewDeposit(1), 0);
        bytes32 beforeState = _state();
        vm.prank(alice);
        vm.expectRevert(_swapError(FCSPrimaryHook.InvalidOutput.selector));
        router.swapExactInput(true, 1, 1, alice, block.timestamp);
        assertEq(_state(), beforeState);
        (uint256 out, bool available, FCSPrimaryHook.QuoteStatus reason) = hook.quoteExactInput(true, 1);
        assertEq(out, 0);
        assertFalse(available);
        assertEq(uint256(reason), uint256(FCSPrimaryHook.QuoteStatus.ZeroOutput));
    }

    function test_largePrimaryBuyDilutesFPSAgeAndClosesSellGate() public {
        zchf.transfer(alice, 80_000_000e18);
        vm.prank(alice);
        router.swapExactInput(true, 80_000_000e18, 1, alice, block.timestamp);
        assertTrue(fcs.isBinding());
        assertFalse(fps.canRedeem(address(fcs)));
        (uint256 out, bool available, FCSPrimaryHook.QuoteStatus reason) = hook.quoteExactInput(false, 1e18);
        assertGt(out, 0);
        assertFalse(available);
        assertEq(uint256(reason), uint256(FCSPrimaryHook.QuoteStatus.FPSRedemptionDisabled));
        bytes32 beforeState = _state();
        vm.prank(alice);
        vm.expectRevert(_swapError(FCSMintRedeem.RedemptionsDisabled.selector));
        router.swapExactInput(false, 1e18, 1, alice, block.timestamp);
        assertEq(_state(), beforeState);
        _clean();
    }

    function test_nonbindingGateClosesEvenWithPositivePreview() public {
        fps.invest(80_000_000e18, 0);
        vm.warp(block.timestamp + 100 days);
        assertFalse(fcs.isBinding());
        assertTrue(fps.canRedeem(address(fcs)));
        (uint256 out, bool available, FCSPrimaryHook.QuoteStatus reason) = hook.quoteExactInput(false, 1e18);
        assertGt(out, 0);
        assertFalse(available);
        assertEq(uint256(reason), uint256(FCSPrimaryHook.QuoteStatus.NotBinding));
        bytes32 beforeState = _state();
        vm.prank(alice);
        vm.expectRevert(_swapError(FCSMintRedeem.RedemptionsDisabled.selector));
        router.swapExactInput(false, 1e18, 1, alice, block.timestamp);
        assertEq(_state(), beforeState);
    }

    function test_quoteOversupplyAndZeroInputUnavailable() public view {
        (, bool zeroAvailable, FCSPrimaryHook.QuoteStatus zeroReason) = hook.quoteExactInput(true, 0);
        assertFalse(zeroAvailable);
        assertEq(uint256(zeroReason), uint256(FCSPrimaryHook.QuoteStatus.InvalidInput));
        (, bool overAvailable, FCSPrimaryHook.QuoteStatus overReason) =
            hook.quoteExactInput(false, fcs.totalSupply() + 1);
        assertFalse(overAvailable);
        assertEq(uint256(overReason), uint256(FCSPrimaryHook.QuoteStatus.InsufficientSupply));
    }

    function test_quotePreviewFailureDoesNotRevert() public view {
        (, bool available, FCSPrimaryHook.QuoteStatus reason) = hook.quoteExactInput(false, fcs.totalSupply());
        assertFalse(available);
        assertEq(uint256(reason), uint256(FCSPrimaryHook.QuoteStatus.PreviewFailed));
    }

    function test_redeemAboveTenPercentDoesNotUseWithdrawCap() public {
        fcs.transfer(alice, 150e18);
        uint256 amount = 200e18;
        assertGt(amount, fcs.totalSupply() / 10);
        uint256 expected = fcs.previewRedeem(amount);
        vm.prank(alice);
        uint256 out = router.swapExactInput(false, amount, expected, alice, block.timestamp);
        assertEq(out, expected);
        _clean();
    }

    function test_donatedOutputCannotSatisfyMinimum() public {
        fcs.transfer(address(hook), 10e18);
        uint256 expected = fcs.previewDeposit(1000e18);
        bytes32 beforeState = _state();
        vm.prank(alice);
        vm.expectRevert(
            _wrapped(
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(FCSPrimaryHook.InsufficientOutput.selector, expected, expected + 1)
            )
        );
        router.swapExactInput(true, 1000e18, expected + 1, alice, block.timestamp);
        assertEq(_state(), beforeState);
        assertEq(fcs.balanceOf(address(hook)), 10e18);
    }

    function test_quotesAreStaticAndSideEffectFree() public view {
        bytes32 beforeState = _state();
        (bool ok, bytes memory result) = address(hook).staticcall(abi.encodeCall(hook.quoteExactInput, (false, 1e18)));
        assertTrue(ok);
        (uint256 out, bool available,) = abi.decode(result, (uint256, bool, FCSPrimaryHook.QuoteStatus));
        assertTrue(available);
        assertEq(out, fcs.previewRedeem(1e18));
        assertEq(_state(), beforeState);
        _clean();
    }

    function test_hookRejectsSignedBoundsBeforeNegation() public {
        ExternalRouter ext = _ext();
        int256[2] memory invalid = [int256(type(int128).min), type(int256).min];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(_swapError(FCSPrimaryHook.InvalidAmount.selector));
            ext.swap(key, _params(true, invalid[i]), abi.encode(uint256(1), block.timestamp), false, false);
        }
    }

    function test_quoteInputOverflowIsUnavailable() public view {
        (, bool available, FCSPrimaryHook.QuoteStatus reason) = hook.quoteExactInput(true, type(uint256).max);
        assertFalse(available);
        assertEq(uint256(reason), uint256(FCSPrimaryHook.QuoteStatus.InvalidInput));
    }

    function test_quoteDependencyFailuresAndOversizedOutput() public {
        vm.mockCallRevert(
            address(fcs), abi.encodeCall(IFCS.previewDeposit, (1000e18)), abi.encodeWithSignature("PrimaryFailure()")
        );
        (, bool available, FCSPrimaryHook.QuoteStatus reason) = hook.quoteExactInput(true, 1000e18);
        assertFalse(available);
        assertEq(uint256(reason), uint256(FCSPrimaryHook.QuoteStatus.PreviewFailed));
        vm.clearMockedCalls();
        vm.mockCall(address(fcs), abi.encodeCall(IFCS.previewDeposit, (1000e18)), abi.encode(type(uint256).max));
        (, available, reason) = hook.quoteExactInput(true, 1000e18);
        assertFalse(available);
        assertEq(uint256(reason), uint256(FCSPrimaryHook.QuoteStatus.OutputTooLarge));
    }

    function testFuzz_buyExactInputNoStrandedCredit(uint96 raw) public {
        uint256 amount = bound(uint256(raw), 1e12, 100_000e18);
        uint256 expected = fcs.previewDeposit(amount);
        uint256 beforeBalance = fcs.balanceOf(alice);
        vm.prank(alice);
        uint256 out = router.swapExactInput(true, amount, expected, alice, block.timestamp);
        assertEq(out, expected);
        assertEq(fcs.balanceOf(alice), beforeBalance + out);
        _clean();
    }

    function testFuzz_sellExactInputNoStrandedCredit(uint96 raw) public {
        uint256 amount = bound(uint256(raw), 1e10, 90e18);
        uint256 expected = fcs.previewRedeem(amount);
        uint256 beforeBalance = zchf.balanceOf(alice);
        vm.prank(alice);
        uint256 out = router.swapExactInput(false, amount, expected, alice, block.timestamp);
        assertEq(out, expected);
        assertEq(zchf.balanceOf(alice), beforeBalance + out);
        _clean();
    }

    function testFuzz_donationsNeverAttributedToTrade(uint64 raw, bool buy) public {
        uint256 gift = bound(uint256(raw), 1, 1e15);
        zchf.transfer(address(hook), gift);
        fcs.transfer(address(hook), gift);
        zchf.transfer(address(router), gift);
        fcs.transfer(address(router), gift);
        zchf.transfer(address(manager), gift);
        fcs.transfer(address(manager), gift);
        uint256 amount = buy ? 1000e18 : 1e18;
        uint256 expected = buy ? fcs.previewDeposit(amount) : fcs.previewRedeem(amount);
        vm.prank(alice);
        uint256 out = router.swapExactInput(buy, amount, expected, alice, block.timestamp);
        assertEq(out, expected);
        assertEq(zchf.balanceOf(address(hook)), gift);
        assertEq(fcs.balanceOf(address(hook)), gift);
        assertEq(zchf.balanceOf(address(router)), gift);
        assertEq(fcs.balanceOf(address(router)), gift);
        assertEq(zchf.balanceOf(address(manager)), gift);
        assertEq(fcs.balanceOf(address(manager)), gift);
    }

    function testFuzz_repeatedBothDirections(uint8 raw) public {
        uint256 count = bound(uint256(raw), 1, 12);
        for (uint256 i; i < count; ++i) {
            vm.prank(alice);
            uint256 bought = router.swapExactInput(true, 100e18, 1, alice, block.timestamp);
            vm.prank(alice);
            router.swapExactInput(false, bought, 1, alice, block.timestamp);
            _clean();
        }
    }
}

/// @dev Adversarial callback transport ONLY. Swap/settlement/curve tests use real PoolManager.
contract TamperingManager {
    uint256 mode;
    address victim;

    function configure(uint256 mode_, address victim_) external {
        mode = mode_;
        victim = victim_;
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        FCSPrimaryRouter r = FCSPrimaryRouter(msg.sender);
        if (mode == 1) r.swapExactInput(true, 1e18, 1, victim, block.timestamp);
        FCSPrimaryRouter.Request memory request = abi.decode(data, (FCSPrimaryRouter.Request));
        request.payer = victim;
        return r.unlockCallback(abi.encode(request));
    }

    function replay(FCSPrimaryRouter r, bytes calldata data) external {
        r.unlockCallback(data);
    }
}
