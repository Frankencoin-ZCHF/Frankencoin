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
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {DualPoolHook} from "../../src/alf/DualPoolHook.sol";
import {LiquidityBucket, MAX_BUCKETS, computeAllocations} from "../../src/alf/types/Distribution.sol";
import {VaultNotBootstrapped, AssetsAlreadyBound} from "../../src/alf/types/Shares.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";

/// @title AlfDualPoolRegressionTest
/// @notice Executable regressions for the DualPool findings in the ALF security review. Each test
///         pins the finding's behavior so a future fix flips the assertion deliberately, and any
///         unintended change is caught. Findings that describe current (unfixed) behavior are
///         asserted as-is with a note on the intended remediation.
contract AlfDualPoolRegressionTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    DualPoolHook hook;
    MockERC4626 vault0;
    MockERC4626 vault1;
    MockERC20 token0;
    MockERC20 token1;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");

    PoolId poolId;

    uint256 constant BOOTSTRAP = 1e22;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));
        vault0 = new MockERC4626(ERC20(address(token0)));
        vault1 = new MockERC4626(ERC20(address(token1)));

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        hook = DualPoolHook(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags)));
        deployCodeTo("DualPoolHook", abi.encode(manager, uint32(100_000), owner, type(uint64).max), address(hook));

        key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 1_000, tickSpacing: 10, hooks: IHooks(address(hook))
        });
        poolId = key.toId();

        LiquidityBucket[] memory dist = new LiquidityBucket[](1);
        dist[0] = LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 10_000});
        DualPoolHook.PoolConfig memory cfg = DualPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            distribution: dist,
            allowExternalDeposits: true,
            vault0: IERC4626(address(vault0)),
            vault1: IERC4626(address(vault1)),
            minDepositBlocks: 0
        });
        vm.prank(owner);
        hook.initializePool(key, cfg);

        token0.mint(owner, BOOTSTRAP);
        token1.mint(owner, BOOTSTRAP);
        vm.startPrank(owner);
        token0.approve(address(hook), BOOTSTRAP);
        token1.approve(address(hook), BOOTSTRAP);
        hook.bootstrap(key, BOOTSTRAP, BOOTSTRAP);
        vm.stopPrank();
        vm.roll(block.number + 1);
    }

    /// @notice L-01: burning the entire share supply permanently bricks the pool — no re-bootstrap
    ///         path exists. Documents current behavior; a fix (V2-style locked MINIMUM_LIQUIDITY)
    ///         would make the full burn impossible and flip these assertions.
    function test_L01_fullShareBurnBricksPool() public {
        uint256 all = hook.sharesOf(key, owner);
        assertGt(all, 0, "owner should hold the bootstrap supply");

        vm.prank(owner);
        hook.removeLiquidity(key, all, 0, 0, type(uint256).max);
        assertEq(hook.totalShares(poolId), 0, "supply fully burned");

        // (a) New deposits are impossible: the pool now reads as un-bootstrapped.
        (uint256 w0, uint256 w1) = (1e18, 1e18);
        token0.mint(alice, w0);
        token1.mint(alice, w1);
        vm.startPrank(alice);
        token0.approve(address(hook), w0);
        token1.approve(address(hook), w1);
        vm.expectRevert(VaultNotBootstrapped.selector);
        hook.addLiquidity(key, 1e18, type(uint256).max, type(uint256).max, type(uint256).max);
        vm.stopPrank();

        // (b) Re-bootstrap is impossible: the asset pair is already bound.
        token0.mint(owner, BOOTSTRAP);
        token1.mint(owner, BOOTSTRAP);
        vm.startPrank(owner);
        token0.approve(address(hook), BOOTSTRAP);
        token1.approve(address(hook), BOOTSTRAP);
        vm.expectRevert(AssetsAlreadyBound.selector);
        hook.bootstrap(key, BOOTSTRAP, BOOTSTRAP);
        vm.stopPrank();
    }

    /// @notice L-05: `emergencyRevokeVault` zeroes the vault allowance, but a subsequent owner
    ///         `addLiquidity` (not gated on liveness, and owner bypasses the deposit gate) silently
    ///         re-arms it via `ensureVaultAllowance`. Documents current behavior; the intended fix
    ///         is a revoked-latch that blocks re-arm until an explicit `refreshVaultApproval`.
    function test_L05_emergencyRevokeRearmedByOwnerDeposit() public {
        assertEq(token0.allowance(address(hook), address(vault0)), type(uint256).max, "init: max vault0 allowance");

        vm.prank(owner);
        hook.emergencyRevokeVault(key);
        assertEq(token0.allowance(address(hook), address(vault0)), 0, "revoked: allowance zeroed");

        // Owner deposits into the paused pool → re-arms the very allowance the emergency zeroed.
        (uint256 w0, uint256 w1) = hook.previewDeposit(key, 1e18);
        token0.mint(owner, w0);
        token1.mint(owner, w1);
        vm.startPrank(owner);
        token0.approve(address(hook), w0);
        token1.approve(address(hook), w1);
        hook.addLiquidity(key, 1e18, type(uint256).max, type(uint256).max, type(uint256).max);
        vm.stopPrank();

        assertEq(
            token0.allowance(address(hook), address(vault0)),
            type(uint256).max,
            "L-05: owner deposit silently re-armed the revoked vault allowance"
        );
    }

    /// @notice L-03: `computeAllocations` reverts (v4 `toUint128` overflow) for a narrow bucket at
    ///         extreme single-side balance, which would brick JIT deploys + quotes for the pool.
    ///         Verifies the boundary: fine at 1e33/side, reverts at 1e36/side.
    function test_L03_computeAllocationsOverflowBoundary() public {
        LiquidityBucket[] memory dist = new LiquidityBucket[](1);
        dist[0] = LiquidityBucket({tickLower: -1, tickUpper: 1, weightBps: 10_000});
        uint160 sp = TickMath.getSqrtPriceAtTick(0);

        // Below the boundary: succeeds.
        this.computeAllocationsExternal(dist, sp, 1e33, 1e33);

        // At extreme TVL in a narrow bucket: liquidity exceeds uint128 → revert.
        vm.expectRevert();
        this.computeAllocationsExternal(dist, sp, 1e36, 1e36);
    }

    /// @dev External wrapper so `vm.expectRevert` observes the free function's revert across a call
    ///      boundary (it is otherwise inlined into the test frame).
    function computeAllocationsExternal(LiquidityBucket[] memory buckets, uint160 sp, uint256 b0, uint256 b1)
        external
        pure
        returns (uint128[MAX_BUCKETS] memory liqs, uint256 need0, uint256 need1)
    {
        return computeAllocations(buckets, sp, b0, b1);
    }
}
