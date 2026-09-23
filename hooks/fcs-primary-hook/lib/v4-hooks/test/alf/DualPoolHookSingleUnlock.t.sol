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
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {DualPoolHook} from "../../src/alf/DualPoolHook.sol";
import {LiquidityBucket} from "../../src/alf/types/Distribution.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";

/// @notice Minimal router that performs TWO swaps on the same pool inside a SINGLE
///         `poolManager.unlock`, deferring all settlement to the end. This is the path that
///         exposes the claim-redemption-vs-physical-backing bug: the first swap leaves the hook
///         holding ERC-6909 claims backed only by the (not-yet-settled) swapper input, and the
///         second swap's `_redeemPoolClaims` tries to `take` those claims as real ERC-20 before
///         the PoolManager physically holds them.
contract SingleUnlockDoubleSwapper is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    function doubleSwap(PoolKey calldata key, bool zeroForOne, int256 amountEach) external {
        pm.unlock(abi.encode(key, zeroForOne, amountEach));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        (PoolKey memory key, bool zfo, int256 amt) = abi.decode(data, (PoolKey, bool, int256));
        uint160 limit = zfo ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        // Two swaps on the SAME pool, no settlement between them.
        BalanceDelta d1 =
            pm.swap(key, SwapParams({zeroForOne: zfo, amountSpecified: amt, sqrtPriceLimitX96: limit}), "");
        BalanceDelta d2 =
            pm.swap(key, SwapParams({zeroForOne: zfo, amountSpecified: amt, sqrtPriceLimitX96: limit}), "");

        // Settle the aggregate at the very end.
        _resolve(key.currency0, d1.amount0() + d2.amount0());
        _resolve(key.currency1, d1.amount1() + d2.amount1());
        return "";
    }

    function _resolve(Currency c, int128 amt) internal {
        if (amt < 0) {
            pm.sync(c);
            ERC20(Currency.unwrap(c)).transfer(address(pm), uint256(uint128(-amt)));
            pm.settle();
        } else if (amt > 0) {
            pm.take(c, address(this), uint256(uint128(amt)));
        }
    }
}

/// @title DualPoolHookSingleUnlockTest
/// @notice Regression for multiple swaps on the same DualPool pool within a single v4 unlock.
///         Asserts the desired behavior (the batch succeeds); fails on the pre-fix code where the
///         second swap reverts trying to `take` claims the PoolManager does not yet physically
///         hold.
contract DualPoolHookSingleUnlockTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    DualPoolHook public hook;
    MockERC4626 public vault0;
    MockERC4626 public vault1;
    MockERC20 token0;
    MockERC20 token1;

    address poolOwner = makeAddr("poolOwner");

    PoolKey testKey;
    PoolId poolId;

    SingleUnlockDoubleSwapper router;

    uint24 constant FEE_PIPS = 1_000;
    int24 constant TICK_SPACING = 10;
    uint256 constant BOOTSTRAP_AMOUNT = 10_000e18;

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
        deployCodeTo("DualPoolHook", abi.encode(manager, uint32(100_000), poolOwner, type(uint64).max), address(hook));

        testKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: FEE_PIPS,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        poolId = testKey.toId();

        LiquidityBucket[] memory dist = new LiquidityBucket[](1);
        dist[0] = LiquidityBucket({tickLower: -60, tickUpper: 60, weightBps: 10_000});
        DualPoolHook.PoolConfig memory cfg = DualPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            distribution: dist,
            allowExternalDeposits: false,
            vault0: IERC4626(address(vault0)),
            vault1: IERC4626(address(vault1)),
            minDepositBlocks: 0
        });
        vm.prank(poolOwner);
        hook.initializePool(testKey, cfg);

        token0.mint(poolOwner, BOOTSTRAP_AMOUNT);
        token1.mint(poolOwner, BOOTSTRAP_AMOUNT);
        vm.startPrank(poolOwner);
        token0.approve(address(hook), BOOTSTRAP_AMOUNT);
        token1.approve(address(hook), BOOTSTRAP_AMOUNT);
        hook.bootstrap(testKey, BOOTSTRAP_AMOUNT, BOOTSTRAP_AMOUNT);
        vm.stopPrank();
        vm.roll(block.number + 1);

        router = new SingleUnlockDoubleSwapper(manager);
        // Fund the router so it can settle the aggregate input at the end of the unlock.
        token0.mint(address(router), 1_000e18);
        token1.mint(address(router), 1_000e18);
    }

    /// @dev Two exact-input swaps on the same pool inside one unlock must succeed. On the pre-fix
    ///      code the second swap reverts: it burns the claims minted by the first swap and tries
    ///      to `take` the underlying from the PoolManager, but the first swapper's input is not
    ///      yet settled, so the PoolManager's physical balance is short and the transfer reverts.
    function test_doubleSwapSingleUnlock_succeeds() public {
        // Pre-state: an isolated DualPool keeps inventory in the vault, so the PoolManager
        // physically holds ~no token0 — the condition under which the bug bites.
        assertEq(token0.balanceOf(address(manager)), 0, "precondition: PM holds no token0");

        router.doubleSwap(testKey, true, -100e18);

        // Post-state: JIT positions torn down, pool coherent.
        assertEq(manager.getLiquidity(poolId), 0, "no orphaned liquidity after batched swaps");
        (uint256 r0, uint256 r1) = hook.getReserves(testKey);
        assertGt(r0 + r1, 0, "reserves intact after batched swaps");
    }
}
