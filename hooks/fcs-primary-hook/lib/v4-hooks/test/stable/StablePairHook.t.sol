// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StablePairHook} from "../../src/stable/StablePairHook.sol";
import {BaseDynamicFeeHook} from "../../src/base/BaseDynamicFeeHook.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IStablePairHook} from "../../src/stable/interfaces/IStablePairHook.sol";
import {IDynamicFeeHook} from "../../src/interfaces/IDynamicFeeHook.sol";
import {StableFeeConfig, IStableFeeConfiguration} from "../../src/stable/interfaces/IStableFeeConfiguration.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StableFeeCalculation} from "../../src/stable/libraries/StableFeeCalculation.sol";
import {StablePairTestBase} from "./base/StablePairTestBase.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
// Referenced only by name in `deployCodeTo`; imported so forge includes its artifact in the build.
import {ERC1967Proxy as _ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Tests StablePairHook in its real deployment shape: an `ERC1967Proxy` is the
///         registered v4 hook, delegating to the StablePairHook implementation.
contract StablePairHookTest is StablePairTestBase, Deployers {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    event PoolInitialized(PoolKey indexed poolKey, uint160 sqrtPriceX96, StableFeeConfig feeConfig);

    StablePairHook internal impl;

    StableFeeConfig public feeConfig = StableFeeConfig({
        k: K,
        optimalFeeE6: OPTIMAL_FEE_E6, // 0.9 bps
        targetMultiplier: TARGET_MULTIPLIER,
        referenceSqrtPriceX96: REFERENCE_SQRT_PRICE_X96
    });

    function setUp() public override {
        deployFreshManagerAndRouters();

        impl = new StablePairHook(manager);

        // The proxy is the registered v4 hook, so its address must encode the permission flags.
        hook = StablePairHook(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | HOOK_FLAGS)));
        // configManager is seeded to `owner` so the existing role-separation assertions hold.
        deployCodeTo(
            "ERC1967Proxy.sol:ERC1967Proxy",
            abi.encode(address(impl), abi.encodeCall(BaseDynamicFeeHook.initialize, (owner, poolInitializer, owner))),
            address(hook)
        );

        testPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    // -------------------------------------------------------------------------
    // Wiring
    // -------------------------------------------------------------------------

    function test_setUp_wiring() public view {
        assertTrue(hook.hasRole(hook.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(hook.hasRole(hook.CONFIG_MANAGER_ROLE(), owner)); // seeded to owner in setUp
        assertTrue(hook.hasRole(hook.POOL_INITIALIZER_ROLE(), poolInitializer));
        // The ERC1967 implementation slot points at the deployed implementation.
        assertEq(address(uint160(uint256(vm.load(address(hook), ERC1967Utils.IMPLEMENTATION_SLOT)))), address(impl));
    }

    function test_setUp_setsPoolInitializer() public view {
        assertTrue(hook.hasRole(hook.POOL_INITIALIZER_ROLE(), poolInitializer));
    }

    /// @notice Pins `StableFeeConfiguration`'s ERC-7201 namespace slot. `feeConfig` is the first
    ///         member of the namespaced struct, so its mapping data hashes from the base slot
    ///         itself; the packed struct must sit exactly there.
    ///         This slot is part of the proxy's permanent storage contract — it must never change.
    function test_storageLayout_feeConfigAtBaseSlot() public {
        // keccak256(abi.encode(uint256(keccak256("uniswap.storage.StableFeeConfiguration")) - 1)) & ~bytes32(uint256(0xff))
        bytes32 baseSlot = 0x4e65cbff7fdec8e7b73e40370c540338cf2b602902c10f166d6a73c4a7ee9e00;

        vm.prank(poolInitializer);
        hook.initializePool(testPoolKey, Constants.SQRT_PRICE_1_1, feeConfig);

        uint256 raw = uint256(vm.load(address(hook), keccak256(abi.encode(testPoolKey.toId(), baseSlot))));
        assertEq(uint24(raw), K);
        assertEq(uint24(raw >> 24), OPTIMAL_FEE_E6);
        assertEq(uint8(raw >> 48), feeConfig.targetMultiplier);
        assertEq(uint160(raw >> 56), REFERENCE_SQRT_PRICE_X96);

        // feeState is the struct's second member: base slot + 1. initializePool reset it to
        // (UNDEFINED_DECAYING_FEE_E12, 0, current block).
        uint256 rawState =
            uint256(vm.load(address(hook), keccak256(abi.encode(testPoolKey.toId(), uint256(baseSlot) + 1))));
        assertEq(uint40(rawState), uint40(StableFeeCalculation.UNDEFINED_DECAYING_FEE_E12));
        assertEq(uint160(rawState >> 40), 0);
        assertEq(uint40(rawState >> 200), uint40(block.number));
    }

    // -------------------------------------------------------------------------
    // initializePool (admin path, called directly on the implementation)
    // -------------------------------------------------------------------------

    function test_initializePool_revertsWithNotPoolInitializer() public {
        bytes32 role = hook.POOL_INITIALIZER_ROLE();
        vm.prank(address(this));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), role)
        );
        hook.initializePool(testPoolKey, Constants.SQRT_PRICE_1_1, feeConfig);
    }

    function test_initializePool_revertsForConfigManager() public {
        // The config manager holds fee-config rights only; it cannot initialize pools.
        bytes32 role = hook.POOL_INITIALIZER_ROLE();
        vm.prank(owner); // owner is the configManager here
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, owner, role));
        hook.initializePool(testPoolKey, Constants.SQRT_PRICE_1_1, feeConfig);
    }

    /// @notice Rotation is now admin-managed: the admin grants the new initializer and revokes the old.
    function test_grantAndRevokePoolInitializer_rotatesAndEmits() public {
        address next = makeAddr("nextPoolInitializer");
        bytes32 role = hook.POOL_INITIALIZER_ROLE();

        vm.expectEmit(true, true, true, true, address(hook));
        emit IAccessControl.RoleGranted(role, next, owner);
        vm.prank(owner);
        hook.grantRole(role, next);
        assertTrue(hook.hasRole(role, next));

        vm.expectEmit(true, true, true, true, address(hook));
        emit IAccessControl.RoleRevoked(role, poolInitializer, owner);
        vm.prank(owner);
        hook.revokeRole(role, poolInitializer);
        assertFalse(hook.hasRole(role, poolInitializer));
    }

    /// @notice A non-admin cannot grant roles; DEFAULT_ADMIN_ROLE is the only admin of every role.
    function test_grantRole_revertsForNonAdmin() public {
        bytes32 adminRole = hook.DEFAULT_ADMIN_ROLE();
        bytes32 poolInitializerRole = hook.POOL_INITIALIZER_ROLE();
        vm.prank(address(this));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), adminRole)
        );
        hook.grantRole(poolInitializerRole, address(this));
    }

    /// @notice After rotation, only the new pool initializer can initialize; the old one cannot.
    function test_rotatePoolInitializer_rotatesInitRights() public {
        address next = makeAddr("nextPoolInitializer");
        bytes32 role = hook.POOL_INITIALIZER_ROLE();
        vm.startPrank(owner);
        hook.grantRole(role, next);
        hook.revokeRole(role, poolInitializer);
        vm.stopPrank();

        // Old initializer has lost the right.
        vm.prank(poolInitializer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, poolInitializer, role)
        );
        hook.initializePool(testPoolKey, Constants.SQRT_PRICE_1_1, feeConfig);

        // New initializer holds it.
        vm.prank(next);
        hook.initializePool(testPoolKey, Constants.SQRT_PRICE_1_1, feeConfig);
        (uint160 slot0SqrtPriceX96,,,) = manager.getSlot0(testPoolKey.toId());
        assertEq(slot0SqrtPriceX96, Constants.SQRT_PRICE_1_1);
    }

    /// @notice Role separation: the pool initializer holds no fee-config rights.
    function test_poolInitializer_cannotUpdateFeeConfig() public {
        bytes32 role = hook.CONFIG_MANAGER_ROLE();
        vm.prank(poolInitializer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, poolInitializer, role)
        );
        hook.updateFeeConfig(testPoolKey.toId(), feeConfig);
    }

    /// @notice Config can only be updated for a pool whose config was seeded by initializePool —
    ///         the only way a pool with this hook can exist. testPoolKey is not initialized in
    ///         setUp, so a config update reverts — orphan config is unrepresentable.
    function test_updateFeeConfig_revertsForUninitializedPool() public {
        vm.prank(owner); // owner doubles as configManager in this suite
        vm.expectRevert(abi.encodeWithSelector(IDynamicFeeHook.PoolNotInitialized.selector, testPoolKey.toId()));
        hook.updateFeeConfig(testPoolKey.toId(), feeConfig);
    }

    /// @notice batchUpdateFeeConfig applies the same pool-initialized guard per element.
    function test_batchUpdateFeeConfig_revertsForUninitializedPool() public {
        PoolId[] memory poolIds = new PoolId[](1);
        poolIds[0] = testPoolKey.toId();
        StableFeeConfig[] memory feeConfigs = new StableFeeConfig[](1);
        feeConfigs[0] = feeConfig;

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IDynamicFeeHook.PoolNotInitialized.selector, testPoolKey.toId()));
        hook.batchUpdateFeeConfig(poolIds, feeConfigs);
    }

    /// @notice A pool that exists on the PoolManager but does not use this hook is rejected the
    ///         same way: config can only target pools whose config was seeded by initializePool,
    ///         so a foreign poolId (which can never collide with ours — the id hashes the hook
    ///         address) has no config and the update reverts instead of writing orphan config.
    function test_updateFeeConfig_revertsForForeignPool() public {
        PoolKey memory foreignKey = PoolKey({
            currency0: Currency.wrap(address(2)),
            currency1: Currency.wrap(address(3)),
            fee: 3000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        manager.initialize(foreignKey, Constants.SQRT_PRICE_1_1);
        (uint160 slot0SqrtPriceX96,,,) = manager.getSlot0(foreignKey.toId());
        assertEq(slot0SqrtPriceX96, Constants.SQRT_PRICE_1_1); // the pool genuinely exists

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IDynamicFeeHook.PoolNotInitialized.selector, foreignKey.toId()));
        hook.updateFeeConfig(foreignKey.toId(), feeConfig);
    }

    /// @notice Once the pool is initialized, the config manager can update its config normally.
    function test_updateFeeConfig_succeedsForInitializedPool() public {
        vm.prank(poolInitializer);
        hook.initializePool(testPoolKey, Constants.SQRT_PRICE_1_1, feeConfig);

        StableFeeConfig memory updated = StableFeeConfig({
            k: K,
            optimalFeeE6: OPTIMAL_FEE_E6 + 1,
            targetMultiplier: TARGET_MULTIPLIER,
            referenceSqrtPriceX96: REFERENCE_SQRT_PRICE_X96
        });
        vm.prank(owner);
        hook.updateFeeConfig(testPoolKey.toId(), updated);

        (, uint24 optimalFeeE6,,) = hook.feeConfig(testPoolKey.toId());
        assertEq(optimalFeeE6, OPTIMAL_FEE_E6 + 1);
    }

    /// @notice Role separation: neither the config manager nor the pool initializer can grant or
    ///         revoke any role — only DEFAULT_ADMIN_ROLE administers roles. Uses a plain
    ///         configManager-only address (in this suite `owner` doubles as configManager AND admin,
    ///         so it cannot demonstrate the role's own lack of admin rights).
    function test_configManagerAndPoolInitializer_cannotGrantOrRevokeRoles() public {
        bytes32 adminRole = hook.DEFAULT_ADMIN_ROLE();
        bytes32 poolInitializerRole = hook.POOL_INITIALIZER_ROLE();
        bytes32 configManagerRole = hook.CONFIG_MANAGER_ROLE();

        address plainConfigManager = makeAddr("plainConfigManager");
        vm.prank(owner);
        hook.grantRole(configManagerRole, plainConfigManager);

        // The config manager cannot grant or revoke roles.
        vm.prank(plainConfigManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, plainConfigManager, adminRole
            )
        );
        hook.grantRole(poolInitializerRole, plainConfigManager);

        vm.prank(plainConfigManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, plainConfigManager, adminRole
            )
        );
        hook.revokeRole(poolInitializerRole, poolInitializer);

        // The pool initializer cannot grant or revoke roles.
        vm.prank(poolInitializer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, poolInitializer, adminRole)
        );
        hook.grantRole(configManagerRole, poolInitializer);

        vm.prank(poolInitializer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, poolInitializer, adminRole)
        );
        hook.revokeRole(configManagerRole, plainConfigManager);
    }

    function test_initializePool_revertsWithMustUseDynamicFee() public {
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: LPFeeLibrary.MAX_LP_FEE, // static fee
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        vm.prank(poolInitializer);
        vm.expectRevert(abi.encodeWithSelector(IStablePairHook.MustUseDynamicFee.selector, LPFeeLibrary.MAX_LP_FEE));
        hook.initializePool(poolKey, Constants.SQRT_PRICE_1_1, feeConfig);
    }

    function test_initializePool_revertsWithInvalidHookAddress() public {
        // Pool must register the proxy as its hook, not the implementation or anything else.
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(impl)) // the implementation, which is the wrong address
        });
        vm.prank(poolInitializer);
        vm.expectRevert(abi.encodeWithSelector(IStablePairHook.InvalidHookAddress.selector, address(impl)));
        hook.initializePool(poolKey, Constants.SQRT_PRICE_1_1, feeConfig);
    }

    function test_initializePool_succeeds() public {
        vm.expectEmit(true, false, false, true);
        emit PoolInitialized(testPoolKey, Constants.SQRT_PRICE_1_1, feeConfig);
        vm.prank(poolInitializer);
        hook.initializePool(testPoolKey, Constants.SQRT_PRICE_1_1, feeConfig);

        (uint160 slot0SqrtPriceX96, int24 slot0Tick, uint24 slot0ProtocolFee,) = manager.getSlot0(testPoolKey.toId());
        assertEq(slot0SqrtPriceX96, Constants.SQRT_PRICE_1_1);
        assertEq(slot0ProtocolFee, 0);
        assertEq(slot0Tick, TickMath.getTickAtSqrtPrice(Constants.SQRT_PRICE_1_1));
        (uint256 k, uint24 optimalFeeE6, uint8 targetMultiplier, uint160 referenceSqrtPriceX96) =
            hook.feeConfig(testPoolKey.toId());
        assertEq(k, K);
        assertEq(optimalFeeE6, OPTIMAL_FEE_E6);
        assertEq(targetMultiplier, TARGET_MULTIPLIER);
        assertEq(referenceSqrtPriceX96, REFERENCE_SQRT_PRICE_X96);
        (uint256 previousDecayingFeeE12, uint160 previousSqrtAmmPriceX96, uint256 blockNumber) =
            hook.feeState(testPoolKey.toId());
        assertEq(previousDecayingFeeE12, StableFeeCalculation.UNDEFINED_DECAYING_FEE_E12);
        assertEq(previousSqrtAmmPriceX96, 0);
        assertEq(blockNumber, block.number);
    }

    function test_initializePool_gas() public {
        vm.prank(poolInitializer);
        hook.initializePool(testPoolKey, TickMath.MIN_SQRT_PRICE, feeConfig);
        vm.snapshotGasLastCall("initializePool");
    }

    // -------------------------------------------------------------------------
    // Access control on the hook callbacks
    // -------------------------------------------------------------------------

    /// @notice A foreign address initializing the pool directly on the PoolManager is rejected.
    function test_beforeInitialize_revertsForForeignInitializer() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook), // the registered hook is the proxy
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(BaseDynamicFeeHook.InvalidInitializer.selector, address(this)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        vm.prank(address(this));
        manager.initialize(testPoolKey, TickMath.MIN_SQRT_PRICE); // not initiated by the hook
    }

    /// @notice beforeInitialize may only be called by the PoolManager.
    function test_beforeInitialize_revertsWhenNotPoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeInitialize(address(hook), testPoolKey, Constants.SQRT_PRICE_1_1);
    }

    /// @notice beforeSwap may only be called by the PoolManager.
    function test_beforeSwap_revertsWhenNotPoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeSwap(address(this), testPoolKey, SwapParams(true, 1e18, TickMath.MIN_SQRT_PRICE + 1), "");
    }

    // -------------------------------------------------------------------------
    // End-to-end: a real swap routed PoolManager -> proxy -> implementation
    // -------------------------------------------------------------------------

    function test_swap_appliesDynamicFee() public {
        (Currency currency0, Currency currency1) = deployMintAndApprove2Currencies();
        PoolKey memory swapKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        vm.prank(poolInitializer);
        hook.initializePool(swapKey, Constants.SQRT_PRICE_1_1, feeConfig);

        modifyLiquidityRouter.modifyLiquidity(
            swapKey,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 100e18, salt: bytes32(0)}),
            ""
        );

        // The swap must route beforeSwap down to the implementation, where the dynamic fee is computed.
        vm.expectCall(address(hook), abi.encodeWithSelector(IHooks.beforeSwap.selector));

        uint256 balance0Before = currency0.balanceOf(address(this));
        uint256 balance1Before = currency1.balanceOf(address(this));
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(
            swapKey,
            SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            settings,
            ""
        );

        // Swap executed end-to-end through the proxy: token0 was spent and token1 received.
        assertLt(currency0.balanceOf(address(this)), balance0Before, "token0 should be spent");
        assertGt(currency1.balanceOf(address(this)), balance1Before, "token1 should be received");
    }
}
