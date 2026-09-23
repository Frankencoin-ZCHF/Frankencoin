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
import {PoolVault} from "../../src/alf/base/PoolVault.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";

/// @notice ERC-20 that burns a configurable fee on `transferFrom`, delivering less than the
///         requested amount to the recipient — the canonical fee-on-transfer behavior.
contract MockFeeOnTransferERC20 is MockERC20 {
    uint16 public feeBps;

    constructor(uint8 decimals_) MockERC20("FoT", "FoT", decimals_) {}

    function setFeeBps(uint16 bps) external {
        feeBps = bps;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;

        uint256 fee = (amount * feeBps) / 10_000;
        balanceOf[from] -= amount;
        unchecked {
            balanceOf[to] += amount - fee;
        }
        totalSupply -= fee; // burn the fee so balances still sum to totalSupply
        emit Transfer(from, to, amount - fee);
        return true;
    }
}

/// @title DualPoolHookFeeOnTransferTest
/// @notice Fee-on-transfer / rebasing tokens are unsupported: an inbound LP transfer that
///         delivers less than requested must revert `TransferReceiptShortfall` on BOTH the
///         bootstrap and the addLiquidity paths, so a fee-charging token can never seed a pool
///         (which would otherwise record balances the hook can never settle, bricking swaps).
contract DualPoolHookFeeOnTransferTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    DualPoolHook hook;
    MockFeeOnTransferERC20 t0;
    MockFeeOnTransferERC20 t1;
    PoolKey poolKey;
    address owner = makeAddr("owner");
    uint24 constant FEE = 1_000;

    function setUp() public {
        deployFreshManagerAndRouters();

        MockFeeOnTransferERC20 a = new MockFeeOnTransferERC20(18);
        MockFeeOnTransferERC20 b = new MockFeeOnTransferERC20(18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        hook = DualPoolHook(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags)));
        deployCodeTo("DualPoolHook", abi.encode(manager, uint32(100_000), owner, type(uint64).max), address(hook));

        poolKey = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: FEE,
            tickSpacing: 10,
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
        vm.prank(owner);
        hook.initializePool(poolKey, cfg);
    }

    function _fundOwner(uint256 amount) internal {
        t0.mint(owner, amount);
        t1.mint(owner, amount);
        vm.startPrank(owner);
        t0.approve(address(hook), type(uint256).max);
        t1.approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Bootstrap with a fee-charging token reverts rather than silently seeding a pool with
    ///      fewer assets than recorded. This is the path that previously slipped through.
    function test_bootstrap_feeOnTransfer_reverts() public {
        t0.setFeeBps(100); // 1% fee
        t1.setFeeBps(100);
        _fundOwner(1_000e18);

        vm.prank(owner);
        vm.expectRevert(PoolVault.TransferReceiptShortfall.selector);
        hook.bootstrap(poolKey, 1_000e18, 1_000e18);
    }

    /// @dev Control: with no fee, bootstrap succeeds (the mock behaves as a normal ERC-20).
    function test_bootstrap_zeroFee_succeeds() public {
        _fundOwner(1_000e18);
        vm.prank(owner);
        hook.bootstrap(poolKey, 1_000e18, 1_000e18);
        assertEq(hook.totalShares(poolKey.toId()), 1_000e18, "bootstrap should succeed with no fee");
    }

    /// @dev A token that begins charging a fee after a clean bootstrap is rejected on the next
    ///      addLiquidity, so it cannot dilute existing LPs by under-delivering.
    function test_addLiquidity_feeOnTransfer_reverts() public {
        _fundOwner(1_000e18);
        vm.prank(owner);
        hook.bootstrap(poolKey, 1_000e18, 1_000e18);
        vm.roll(block.number + 1);

        // Fee switched on after the pool is live.
        t0.setFeeBps(100);
        t1.setFeeBps(100);
        _fundOwner(1_000e18);

        vm.prank(owner);
        vm.expectRevert(PoolVault.TransferReceiptShortfall.selector);
        hook.addLiquidity(poolKey, 100e18, type(uint256).max, type(uint256).max, block.timestamp);
    }
}
