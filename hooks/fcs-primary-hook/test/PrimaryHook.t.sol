// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {ExternalRouter} from "./ExternalRouter.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FCSPrimaryHook} from "../src/FCSPrimaryHook.sol";
import {FCSPrimaryRouter} from "../src/FCSPrimaryRouter.sol";
import {IFCS} from "../src/interfaces/IFCS.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "v4-hooks/utils/HookMiner.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Frankencoin} from "frankencoin/stablecoin/Frankencoin.sol";
import {FCS, IGovernanceFactory} from "frankencoin/equity/shares/FCS.sol";
import {Equity} from "frankencoin/equity/Equity.sol";
import {IFrankencoin} from "frankencoin/stablecoin/IFrankencoin.sol";
import {IGovernance} from "frankencoin/equity/IGovernance.sol";

// Only governance-helper deployment is stubbed. Token, curve, voting and age logic are real.
contract InertGovernanceFactory {
    function deploy(address) external pure returns (address) {
        return address(0xBEEF);
    }
}

contract PrimaryHookTest is Test {
    using StateLibrary for IPoolManager;
    IPoolManager manager;
    Frankencoin zchf;
    FCS fcs;
    Equity fps;
    FCSPrimaryHook hook;
    FCSPrimaryRouter router;
    PoolKey key;
    address alice = address(0xA11CE);

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        zchf = new Frankencoin(14 days);
        zchf.initialize(address(this), "test fixture only");
        zchf.mint(address(this), 100_000_000e18);
        fps = Equity(address(zchf.reserve()));
        fcs = new FCS(
            IGovernanceFactory(address(new InertGovernanceFactory())),
            IGovernance(address(fps)),
            IFrankencoin(address(zchf))
        );
        zchf.approve(address(fcs), type(uint256).max);
        fcs.deposit(1_000_000e18, address(this));
        vm.warp(block.timestamp + 100 days);
        assertTrue(fcs.isBinding());
        assertTrue(fps.canRedeem(address(fcs)));
        manager = IPoolManager(address(new PoolManager(address(this))));
        _deployHook();
        zchf.transfer(alice, 1_000_000e18);
        fcs.transfer(alice, 100e18);
        vm.startPrank(alice);
        zchf.approve(address(router), type(uint256).max);
        fcs.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _deployHook() internal {
        bytes memory args = abi.encode(manager, IFCS(address(fcs)));
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), 0x2888, type(FCSPrimaryHook).creationCode, args);
        hook = new FCSPrimaryHook{salt: salt}(manager, IFCS(address(fcs)));
        assertEq(address(hook), predicted);
        router = hook.router();
        key = router.poolKey();
        manager.initialize(key, uint160(1 << 96));
    }

    function test_sellFromEmptyManager_realMatureBindingFCS() public {
        uint256 amount = 1e18;
        uint256 expected = fcs.previewRedeem(amount);
        uint256 beforeZchf = zchf.balanceOf(alice);
        uint256 beforeSupply = fcs.totalSupply();
        assertEq(zchf.balanceOf(address(manager)), 0);
        assertEq(fcs.balanceOf(address(manager)), 0);
        vm.prank(alice);
        uint256 out = router.swapExactInput(false, amount, expected, alice, block.timestamp);
        assertEq(out, expected);
        assertEq(zchf.balanceOf(alice), beforeZchf + expected);
        assertEq(fcs.totalSupply(), beforeSupply - amount);
        assertEq(fcs.recentlyRedeemed(), amount);
        assertEq(zchf.balanceOf(address(manager)), 0);
        assertEq(fcs.balanceOf(address(manager)), 0);
        assertEq(zchf.balanceOf(address(hook)), 0);
        assertEq(fcs.balanceOf(address(hook)), 0);
    }

    function test_quoteBuyMatchesAmountSpecificPreview() public view {
        (uint256 out, bool available,) = hook.quoteExactInput(true, 1000e18);
        assertTrue(available);
        assertEq(out, fcs.previewDeposit(1000e18));
    }

    function test_quoteSellDoesNotUseEmptyHookMaxRedeem() public view {
        assertEq(fcs.maxRedeem(address(hook)), 0);
        (uint256 out, bool available,) = hook.quoteExactInput(false, 1e18);
        assertTrue(available);
        assertEq(out, fcs.previewRedeem(1e18));
    }

    function test_externalPrefundedRouterCanBuy() public {
        ExternalRouter ext = new ExternalRouter(manager);
        vm.startPrank(alice);
        zchf.approve(address(ext), type(uint256).max);
        uint256 out = ext.swap(
            key, _params(true, -int256(1000e18)), abi.encode(fcs.previewDeposit(1000e18), block.timestamp), true, false
        );
        vm.stopPrank();
        assertGt(out, 0);
    }

    function _params(bool buy, int256 amount) internal view returns (SwapParams memory) {
        bool zeroForOne = buy == (address(zchf) < address(fcs));
        return SwapParams(zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    function test_buyFromEmptyManager() public {
        assertEq(zchf.balanceOf(address(manager)), 0);
        assertEq(fcs.balanceOf(address(manager)), 0);
        uint256 amount = 1000e18;
        uint256 expected = fcs.previewDeposit(amount);
        uint256 beforeFcs = fcs.balanceOf(alice);
        vm.prank(alice);
        uint256 out = router.swapExactInput(true, amount, expected, alice, block.timestamp);
        assertEq(out, expected);
        assertEq(fcs.balanceOf(alice), beforeFcs + expected);
        assertEq(zchf.balanceOf(address(manager)), 0);
        assertEq(fcs.balanceOf(address(manager)), 0);
        assertEq(zchf.balanceOf(address(hook)), 0);
        assertEq(fcs.balanceOf(address(hook)), 0);
    }
}
