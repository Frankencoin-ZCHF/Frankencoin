// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {DualPoolHook} from "../../src/alf/DualPoolHook.sol";
import {LiquidityBucket} from "../../src/alf/types/Distribution.sol";
import {BootstrapTooSmall} from "../../src/alf/types/Shares.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";

/// @title DualPoolHookDecimalsTest
/// @notice Covers the per-pool virtual-shares offset derived from the pair's token decimals.
///         Before this was added, the hardcoded `_decimalsOffset = 12` made low-decimal pairs
///         (e.g. 6-decimal stablecoins) require ~100M tokens/side to bootstrap, effectively a
///         pool-creation DoS for the 6-decimal stablecoin pairs.
contract DualPoolHookDecimalsTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    DualPoolHook hook;
    address poolOwner = makeAddr("poolOwner");
    uint24 constant FEE = 1_000;
    int24 constant TICK_SPACING = 10;

    function setUp() public {
        deployFreshManagerAndRouters();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        hook = DualPoolHook(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags)));
        deployCodeTo("DualPoolHook", abi.encode(manager, uint32(100_000), poolOwner, type(uint64).max), address(hook));
    }

    /// @dev Create + initialize a pool over two freshly-minted tokens of the given decimals.
    ///      Returns the key and the address-sorted token pair (t0 < t1).
    function _makePool(uint8 dec0, uint8 dec1) internal returns (PoolKey memory poolKey, MockERC20 t0, MockERC20 t1) {
        MockERC20 a = new MockERC20("A", "A", dec0);
        MockERC20 b = new MockERC20("B", "B", dec1);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);

        poolKey = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        LiquidityBucket[] memory dist = new LiquidityBucket[](1);
        dist[0] = LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 10_000});
        DualPoolHook.PoolConfig memory cfg = DualPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            distribution: dist,
            allowExternalDeposits: false,
            vault0: IERC4626(address(new MockERC4626(ERC20(address(t0))))),
            vault1: IERC4626(address(new MockERC4626(ERC20(address(t1))))),
            minDepositBlocks: 0
        });
        vm.prank(poolOwner);
        hook.initializePool(poolKey, cfg);
    }

    function _bootstrap(PoolKey memory poolKey, MockERC20 t0, MockERC20 t1, uint256 a0, uint256 a1) internal {
        t0.mint(poolOwner, a0);
        t1.mint(poolOwner, a1);
        vm.startPrank(poolOwner);
        t0.approve(address(hook), a0);
        t1.approve(address(hook), a1);
        hook.bootstrap(poolKey, a0, a1);
        vm.stopPrank();
    }

    function test_offset_18dec_is12() public {
        (PoolKey memory k,,) = _makePool(18, 18);
        assertEq(hook.decimalsOffset(k.toId()), 12, "18/18 should keep offset 12");
    }

    function test_offset_6dec_is6() public {
        (PoolKey memory k,,) = _makePool(6, 6);
        assertEq(hook.decimalsOffset(k.toId()), 6, "6/6 should derive offset 6");
    }

    function test_offset_8dec_is6() public {
        (PoolKey memory k,,) = _makePool(8, 8);
        assertEq(hook.decimalsOffset(k.toId()), 6, "8/8 should clamp to offset 6");
    }

    function test_offset_mixed_6_18_is6() public {
        (PoolKey memory k,,) = _makePool(6, 18);
        assertEq(hook.decimalsOffset(k.toId()), 6, "6/18 (avg 12) should derive offset 6");
    }

    /// @dev A realistic stablecoin seed now bootstraps. 1_000 tokens/side = 1e9 base units →
    ///      sqrt = 1e9 shares, well above the offset-6 floor of 100 * 1e6 = 1e8.
    function test_bootstrap_6dec_realisticSeedSucceeds() public {
        (PoolKey memory k, MockERC20 t0, MockERC20 t1) = _makePool(6, 6);
        _bootstrap(k, t0, t1, 1_000 * 1e6, 1_000 * 1e6);
        assertEq(hook.totalShares(k.toId()), 1e9, "shares should equal sqrt(seed^2)");
    }

    /// @dev Exactly at the offset-6 floor: 100 tokens/side = 1e8 base → sqrt = 1e8 == floor.
    function test_bootstrap_6dec_atFloorSucceeds() public {
        (PoolKey memory k, MockERC20 t0, MockERC20 t1) = _makePool(6, 6);
        _bootstrap(k, t0, t1, 100 * 1e6, 100 * 1e6);
        assertEq(hook.totalShares(k.toId()), 1e8, "shares should equal the floor");
    }

    /// @dev Below the floor still reverts, but the floor is now 1e8 (≈100 tokens), not 1e14.
    function test_bootstrap_6dec_belowFloorReverts() public {
        (PoolKey memory k, MockERC20 t0, MockERC20 t1) = _makePool(6, 6);
        t0.mint(poolOwner, 50 * 1e6);
        t1.mint(poolOwner, 50 * 1e6);
        vm.startPrank(poolOwner);
        t0.approve(address(hook), 50 * 1e6);
        t1.approve(address(hook), 50 * 1e6);
        // sqrt(5e7 * 5e7) = 5e7 < 1e8 floor.
        vm.expectRevert(abi.encodeWithSelector(BootstrapTooSmall.selector, uint256(5e7), uint256(1e8)));
        hook.bootstrap(k, 50 * 1e6, 50 * 1e6);
        vm.stopPrank();
    }

    /// @dev 18-decimal pairs keep the original 1e14 floor: a tiny 0.001-token seed (1e15 base)
    ///      still succeeds, and a sub-floor seed still reverts with the same 1e14 minimum.
    function test_bootstrap_18dec_floorUnchanged() public {
        (PoolKey memory k, MockERC20 t0, MockERC20 t1) = _makePool(18, 18);
        _bootstrap(k, t0, t1, 1e15, 1e15); // sqrt = 1e15 >= 1e14
        assertEq(hook.totalShares(k.toId()), 1e15, "18-dec bootstrap should succeed at 1e15");
    }

    function test_bootstrap_18dec_belowFloorReverts() public {
        (PoolKey memory k, MockERC20 t0, MockERC20 t1) = _makePool(18, 18);
        t0.mint(poolOwner, 1e13);
        t1.mint(poolOwner, 1e13);
        vm.startPrank(poolOwner);
        t0.approve(address(hook), 1e13);
        t1.approve(address(hook), 1e13);
        // sqrt(1e13 * 1e13) = 1e13 < 1e14 floor (offset 12, unchanged).
        vm.expectRevert(abi.encodeWithSelector(BootstrapTooSmall.selector, uint256(1e13), uint256(1e14)));
        hook.bootstrap(k, 1e13, 1e13);
        vm.stopPrank();
    }
}
