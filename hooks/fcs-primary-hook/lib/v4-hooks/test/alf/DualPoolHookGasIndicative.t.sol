// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

import {DualPoolHook} from "../../src/alf/DualPoolHook.sol";
import {LiquidityBucket} from "../../src/alf/types/Distribution.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";

/// @notice Isolated gas measurements for `getIndicativeQuote`. Each test sets up a fresh pool
///         and runs *only* the quote call inside the gasleft() window so the reported numbers
///         exclude bootstrap, deposit, and assertion overhead.
contract DualPoolHookGasIndicativeTest is Test, Deployers {
    DualPoolHook public hook;
    address owner = makeAddr("owner");
    MockERC20 token0;
    MockERC20 token1;
    MockERC4626 vault0;
    MockERC4626 vault1;

    uint24 constant FEE_PIPS = 1_000;
    uint256 constant POOL_SIZE = 10_000 ether;

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
    }

    function test_gas_singleBucket_noVault() public {
        PoolKey memory key = _initPool(_singleBucket(), 10, false);
        _measure(key, "1-bucket, no vault");
    }

    function test_gas_singleBucket_withVault() public {
        PoolKey memory key = _initPool(_singleBucket(), 10, true);
        _measure(key, "1-bucket, ERC-4626 vault");
    }

    function test_gas_threeBuckets_withVault() public {
        PoolKey memory key = _initPool(_conservative(), 10, true);
        _measure(key, "3-bucket conservative, ERC-4626 vault");
    }

    function test_gas_eightBuckets_withVault() public {
        PoolKey memory key = _initPool(_eightBuckets(), 10, true);
        _measure(key, "8-bucket (max), ERC-4626 vault");
    }

    function test_gas_eightBuckets_noVault() public {
        PoolKey memory key = _initPool(_eightBuckets(), 10, false);
        _measure(key, "8-bucket (max), no vault");
    }

    /// @dev Measures gas for a single quote call. Uses `gasleft()` deltas, which include ~150
    ///      gas of EVM call-frame overhead -- subtract that mentally for the pure work cost.
    ///      Runs at multiple swap sizes so we can see whether the "compact quote" really is
    ///      size-invariant (it should be: one computeSwapStep regardless of amount).
    function _measure(PoolKey memory key, string memory label) internal {
        console2.log("");
        console2.log(label);

        // Warm caches with one throwaway call so we measure the steady-state hit pattern,
        // not the cold-storage opening cost (which routers won't pay every time).
        hook.getIndicativeQuote(key, true, -1 ether, "");

        uint256 g;

        g = gasleft();
        hook.getIndicativeQuote(key, true, -1 ether, "");
        console2.log("  ZF1   1 t0  :", g - gasleft(), "gas");

        g = gasleft();
        hook.getIndicativeQuote(key, true, -100 ether, "");
        console2.log("  ZF1 100 t0  :", g - gasleft(), "gas");

        g = gasleft();
        hook.getIndicativeQuote(key, true, -5_000 ether, "");
        console2.log("  ZF1 5000 t0 :", g - gasleft(), "gas");

        g = gasleft();
        hook.getIndicativeQuote(key, false, -100 ether, "");
        console2.log("  1F0 100 t1  :", g - gasleft(), "gas");
    }

    function _initPool(LiquidityBucket[] memory dist, int24 tickSpacing, bool withVault)
        internal
        returns (PoolKey memory key)
    {
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: FEE_PIPS,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(hook))
        });
        DualPoolHook.PoolConfig memory cfg = DualPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            distribution: dist,
            allowExternalDeposits: false,
            vault0: withVault ? IERC4626(address(vault0)) : IERC4626(address(0)),
            vault1: withVault ? IERC4626(address(vault1)) : IERC4626(address(0)),
            minDepositBlocks: 0
        });
        vm.prank(owner);
        hook.initializePool(key, cfg);

        token0.mint(owner, POOL_SIZE);
        token1.mint(owner, POOL_SIZE);
        vm.startPrank(owner);
        token0.approve(address(hook), POOL_SIZE);
        token1.approve(address(hook), POOL_SIZE);
        hook.bootstrap(key, POOL_SIZE, POOL_SIZE);
        vm.stopPrank();
        vm.roll(block.number + 1);
    }

    function _singleBucket() internal pure returns (LiquidityBucket[] memory dist) {
        dist = new LiquidityBucket[](1);
        dist[0] = LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 10_000});
    }

    function _conservative() internal pure returns (LiquidityBucket[] memory dist) {
        dist = new LiquidityBucket[](3);
        dist[0] = LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 7_500});
        dist[1] = LiquidityBucket({tickLower: -30, tickUpper: 30, weightBps: 1_500});
        dist[2] = LiquidityBucket({tickLower: -60, tickUpper: 60, weightBps: 1_000});
    }

    function _eightBuckets() internal pure returns (LiquidityBucket[] memory dist) {
        dist = new LiquidityBucket[](8);
        dist[0] = LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 3_000});
        dist[1] = LiquidityBucket({tickLower: -20, tickUpper: 20, weightBps: 1_500});
        dist[2] = LiquidityBucket({tickLower: -30, tickUpper: 30, weightBps: 1_000});
        dist[3] = LiquidityBucket({tickLower: -40, tickUpper: 40, weightBps: 1_000});
        dist[4] = LiquidityBucket({tickLower: -50, tickUpper: 50, weightBps: 1_000});
        dist[5] = LiquidityBucket({tickLower: -60, tickUpper: 60, weightBps: 1_000});
        dist[6] = LiquidityBucket({tickLower: -80, tickUpper: 80, weightBps: 1_000});
        dist[7] = LiquidityBucket({tickLower: -100, tickUpper: 100, weightBps: 500});
    }
}
