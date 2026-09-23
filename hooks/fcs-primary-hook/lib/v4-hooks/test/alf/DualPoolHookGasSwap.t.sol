// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

import {DualPoolHook} from "../../src/alf/DualPoolHook.sol";
import {LiquidityBucket} from "../../src/alf/types/Distribution.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";

/// @notice Focused gas guard for DualPool's real JIT swap path.
contract DualPoolHookGasSwapTest is Test, Deployers {
    using SafeERC20 for IERC20;

    DualPoolHook public hook;
    address owner = makeAddr("owner");
    MockERC20 token0;
    MockERC20 token1;
    MockERC4626 vault0;
    MockERC4626 vault1;

    uint24 constant FEE_PIPS = 1_000;
    uint256 constant POOL_SIZE = 10_000 ether;
    uint256 constant SINGLE_BUCKET_VAULTED_SWAP_GAS_TARGET = 704_000;

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

    function test_gas_singleBucketVaultedSwap() public {
        PoolKey memory key = _initPool(_singleBucket(), true);

        swap(key, true, -100 ether, "");
        uint256 gasUsed = vm.snapshotGasLastCall("DualPoolHook_swap_singleBucket_withVault");

        assertLt(gasUsed, SINGLE_BUCKET_VAULTED_SWAP_GAS_TARGET, "single-bucket vaulted swap gas");
    }

    function _initPool(LiquidityBucket[] memory dist, bool withVault) internal returns (PoolKey memory key) {
        key = PoolKey({
            currency0: currency0, currency1: currency1, fee: FEE_PIPS, tickSpacing: 10, hooks: IHooks(address(hook))
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
        IERC20(address(token0)).forceApprove(address(hook), POOL_SIZE);
        IERC20(address(token1)).forceApprove(address(hook), POOL_SIZE);
        hook.bootstrap(key, POOL_SIZE, POOL_SIZE);
        vm.stopPrank();
        vm.roll(block.number + 1);
    }

    function _singleBucket() internal pure returns (LiquidityBucket[] memory dist) {
        dist = new LiquidityBucket[](1);
        dist[0] = LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 10_000});
    }
}
