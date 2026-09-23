// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StablePairHook} from "../../src/stable/StablePairHook.sol";
import {BaseDynamicFeeHook} from "../../src/base/BaseDynamicFeeHook.sol";
import {BaseUUPSHook} from "../../src/base/BaseUUPSHook.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {StablePairTestBase} from "./base/StablePairTestBase.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StableFeeConfig, StableFeeState} from "../../src/stable/interfaces/IStableFeeConfiguration.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
// Real (unaliased) import: used directly below via `new ERC1967Proxy(...)` so that constructor
// reverts bubble to `vm.expectRevert` untouched (unlike `deployCodeTo`, which swallows the
// original revert data behind a generic `require` failure).
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice A realistic next-version implementation, shaped like a genuine V2 must be:
///         inherited storage untouched, new state in a NEW appended ERC-7201 namespace
///         (never inside an existing one), initialized via `reinitializer(2)` through
///         `upgradeToAndCall`. See docs/technical/UpgradeRunbook.md.
contract StablePairHookV2Mock is StablePairHook {
    /// @custom:storage-location erc7201:uniswap.storage.StablePairHookV2Mock
    struct StablePairHookV2MockStorage {
        uint256 newValue;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("uniswap.storage.StablePairHookV2Mock")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant V2_MOCK_STORAGE_LOCATION =
        0x4cecd936fa7a4d5ea0f7be60ce1e529399b70f566733e05a8b02ad544bd64400;

    constructor(IPoolManager _manager) StablePairHook(_manager) {}

    function _getV2MockStorage() private pure returns (StablePairHookV2MockStorage storage $) {
        assembly ("memory-safe") {
            $.slot := V2_MOCK_STORAGE_LOCATION
        }
    }

    /// @notice Initializes only the state this version added; V1's initializers already ran
    ///         in the proxy, so they are not (and must not be) called again.
    function initializeV2(uint256 _newValue) external reinitializer(2) {
        _getV2MockStorage().newValue = _newValue;
    }

    function newValue() external view returns (uint256) {
        return _getV2MockStorage().newValue;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @notice `StablePairHookBadV2Mock`'s storage: a copy of `StableFeeConfiguration`'s
///         namespace with a new field INSERTED at the front instead of appended at the
///         end — `feeConfig` and `feeState` shift down a slot, so V2 code would read V1's
///         data from the wrong places. It must be a copy (not inherit the real base):
///         defining the same namespace twice in one hierarchy crashes upgrades-core's
///         layout extraction for every contract in the build, not just this one.
abstract contract BadStableFeeConfigurationMock {
    /// @custom:storage-location erc7201:uniswap.storage.StableFeeConfiguration
    struct StableFeeConfigurationStorage {
        uint256 inserted; // INSERTED, not appended: everything below shifts down a slot
        mapping(PoolId => StableFeeConfig) feeConfig;
        mapping(PoolId => StableFeeState) feeState;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("uniswap.storage.StableFeeConfiguration")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STABLE_FEE_CONFIGURATION_STORAGE_LOCATION =
        0x4e65cbff7fdec8e7b73e40370c540338cf2b602902c10f166d6a73c4a7ee9e00;

    function _getStableFeeConfigurationStorage() internal pure returns (StableFeeConfigurationStorage storage $) {
        assembly ("memory-safe") {
            $.slot := STABLE_FEE_CONFIGURATION_STORAGE_LOCATION
        }
    }
}

/// @notice A DELIBERATELY INCOMPATIBLE next version: a full UUPS hook whose only mistake
///         is the inserted (rather than appended) field in `BadStableFeeConfigurationMock`.
/// @dev Never deployed by any test. It exists only as a negative control for the CI
///      "Validate upgrade storage layout" step, which must REJECT it (see
///      .github/workflows/test.yaml); if the validator ever accepts this contract, the
///      validation pipeline itself is broken. See docs/technical/UpgradeRunbook.md.
contract StablePairHookBadV2Mock is BaseDynamicFeeHook, BadStableFeeConfigurationMock {
    constructor(IPoolManager _manager) BaseDynamicFeeHook(_manager) {}

    /// @dev Inert stub for `IDynamicFeeHook` (the mock's logic is irrelevant, only its layout).
    function getFee(PoolKey calldata) external pure returns (uint24, uint24) {
        return (0, 0);
    }
}

/// @notice Not a UUPS implementation: has no proxiableUUID.
contract NotUUPSMock {}

/// @notice A UUPS hook implementation whose declared flag set differs from the frozen 6-flag set.
contract StableDifferentFlagsMock is BaseUUPSHook {
    constructor(IPoolManager _manager) BaseUUPSHook(_manager) {}

    function _authorizeUpgrade(address) internal view override {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}

/// @notice Upgrade mechanics of BaseUUPSHook/BaseDynamicFeeHook, exercised through the concrete StablePairHook.
contract StablePairHookUpgradeTest is StablePairTestBase, Deployers {
    using PoolIdLibrary for PoolKey;

    event Upgraded(address indexed implementation); // ERC1967

    StablePairHook internal impl;
    address internal other = makeAddr("other");

    function setUp() public override {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        impl = new StablePairHook(manager);
        hook = StablePairHook(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | HOOK_FLAGS)));
        deployCodeTo(
            "ERC1967Proxy.sol:ERC1967Proxy",
            abi.encode(
                address(impl), abi.encodeCall(BaseDynamicFeeHook.initialize, (owner, poolInitializer, configManager))
            ),
            address(hook)
        );

        testPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        vm.prank(poolInitializer);
        hook.initializePool(testPoolKey, Constants.SQRT_PRICE_1_1, _defaultConfig());
    }

    function _upgradeToV2() internal returns (StablePairHookV2Mock v2) {
        StablePairHookV2Mock v2Impl = new StablePairHookV2Mock(manager);
        vm.prank(owner);
        hook.upgradeToAndCall(address(v2Impl), "");
        v2 = StablePairHookV2Mock(address(hook));
    }

    // -------------------------------------------------------------------------
    // Authorization
    // -------------------------------------------------------------------------

    function test_upgrade_revertsForNonAdmin() public {
        StablePairHookV2Mock v2Impl = new StablePairHookV2Mock(manager);
        bytes32 adminRole = hook.DEFAULT_ADMIN_ROLE();
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, adminRole)
        );
        hook.upgradeToAndCall(address(v2Impl), "");
    }

    function test_upgrade_revertsForConfigManagerAndPoolInitializer() public {
        // Role separation: neither operational role can upgrade.
        StablePairHookV2Mock v2Impl = new StablePairHookV2Mock(manager);
        bytes32 adminRole = hook.DEFAULT_ADMIN_ROLE();
        vm.prank(configManager);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, configManager, adminRole)
        );
        hook.upgradeToAndCall(address(v2Impl), "");
        vm.prank(poolInitializer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, poolInitializer, adminRole)
        );
        hook.upgradeToAndCall(address(v2Impl), "");
    }

    function test_upgrade_revertsForNonUUPSImplementation() public {
        // `_validateNewImplementation` (inside `_authorizeUpgrade`) runs before OZ's ERC1967
        // `proxiableUUID` check, and its `poolManager()` call on a contract without that
        // function reverts with no data.
        NotUUPSMock notUUPS = new NotUUPSMock();
        vm.prank(owner);
        vm.expectRevert(bytes(""));
        hook.upgradeToAndCall(address(notUUPS), "");
    }

    // -------------------------------------------------------------------------
    // Upgrade-time implementation validation
    // -------------------------------------------------------------------------

    function test_upgrade_revertsForWrongPoolManager() public {
        PoolManager otherManager = new PoolManager(address(this));
        StablePairHookV2Mock badImpl = new StablePairHookV2Mock(otherManager);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BaseUUPSHook.InvalidPoolManager.selector, address(otherManager)));
        hook.upgradeToAndCall(address(badImpl), "");
    }

    function test_upgrade_revertsForDifferentHookPermissions() public {
        StableDifferentFlagsMock badImpl = new StableDifferentFlagsMock(manager);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, address(hook)));
        hook.upgradeToAndCall(address(badImpl), "");
    }

    // NOTE: Off-chain storage-layout validation (the upgrade rule `_validateNewImplementation`
    // cannot check on-chain) runs as a dedicated CI step (see `.github/workflows/test.yaml`):
    // OZ's upgrades-core diffs every ERC-7201 namespace of `StablePairHook` against
    // `StablePairHookV2Mock` and fails on any incompatible change. It cannot run inside
    // `forge test`: the validator requires build-info from a FULL compilation, and `forge test`
    // itself emits partial build-info for the multi-solc-version compile groups in this repo.

    // -------------------------------------------------------------------------
    // State preservation
    // -------------------------------------------------------------------------

    function test_upgrade_preservesStateAndAddress() public {
        (uint256 kBefore, uint24 feeBefore, uint8 multBefore, uint160 refBefore) = hook.feeConfig(testPoolKey.toId());

        address hookAddressBefore = address(hook);
        StablePairHookV2Mock v2 = _upgradeToV2();

        assertEq(address(v2), hookAddressBefore);
        assertEq(v2.version(), 2);
        // Roles live in the proxy's storage and survive the upgrade.
        assertTrue(v2.hasRole(v2.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(v2.hasRole(v2.POOL_INITIALIZER_ROLE(), poolInitializer));
        assertTrue(v2.hasRole(v2.CONFIG_MANAGER_ROLE(), configManager));

        (uint256 k, uint24 fee, uint8 mult, uint160 ref) = v2.feeConfig(testPoolKey.toId());
        assertEq(k, kBefore);
        assertEq(fee, feeBefore);
        assertEq(mult, multBefore);
        assertEq(ref, refBefore);
    }

    /// @notice Tracks the full upgrade cost, including `_validateNewImplementation`'s
    ///         staticcalls into the proposed implementation.
    function test_upgrade_gas() public {
        StablePairHookV2Mock v2Impl = new StablePairHookV2Mock(manager);
        vm.prank(owner);
        hook.upgradeToAndCall(address(v2Impl), "");
        vm.snapshotGasLastCall("upgradeToAndCall");
    }

    function test_upgrade_emitsUpgraded() public {
        StablePairHookV2Mock v2Impl = new StablePairHookV2Mock(manager);
        vm.expectEmit(true, false, false, false, address(hook));
        emit Upgraded(address(v2Impl));
        vm.prank(owner);
        hook.upgradeToAndCall(address(v2Impl), "");
    }

    /// @notice The production upgrade path: `upgradeToAndCall` with the V2 reinitializer as
    ///         calldata, in one atomic transaction. Old state must survive, the new version's
    ///         state must be initialized, and the reinitializer must be spent.
    function test_upgradeToAndCall_initializesV2State() public {
        (uint256 kBefore,,,) = hook.feeConfig(testPoolKey.toId());

        StablePairHookV2Mock v2Impl = new StablePairHookV2Mock(manager);
        vm.prank(owner);
        hook.upgradeToAndCall(address(v2Impl), abi.encodeCall(StablePairHookV2Mock.initializeV2, (42)));

        StablePairHookV2Mock v2 = StablePairHookV2Mock(address(hook));
        // New state landed in the appended namespace...
        assertEq(v2.newValue(), 42);
        assertEq(v2.version(), 2);
        // ...without disturbing V1's namespace.
        (uint256 k,,,) = v2.feeConfig(testPoolKey.toId());
        assertEq(k, kBefore);
        // The reinitializer is single-use.
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        v2.initializeV2(43);
    }

    /// @notice `feeState` also survives an upgrade: populated by a real swap, read back
    ///         identically through the V2.
    function test_upgrade_preservesFeeState() public {
        modifyLiquidityRouter.modifyLiquidity(
            testPoolKey,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 100e18, salt: 0}),
            ZERO_BYTES
        );
        // First swap after pool init persists this block's fee state.
        swap(testPoolKey, true, -1e15, ZERO_BYTES);

        (uint40 feeBefore, uint160 priceBefore, uint40 blockBefore) = hook.feeState(testPoolKey.toId());
        assertGt(priceBefore, 0); // sanity: the swap actually cached a price

        _upgradeToV2();

        (uint40 feeAfter, uint160 priceAfter, uint40 blockAfter) = hook.feeState(testPoolKey.toId());
        assertEq(feeAfter, feeBefore);
        assertEq(priceAfter, priceBefore);
        assertEq(blockAfter, blockBefore);
    }

    function test_upgrade_swapStillWorks() public {
        modifyLiquidityRouter.modifyLiquidity(
            testPoolKey,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 100e18, salt: 0}),
            ZERO_BYTES
        );
        _upgradeToV2();

        BalanceDelta delta = swap(testPoolKey, true, -1e15, ZERO_BYTES);
        assertGt(delta.amount1(), 0);
    }

    /// @notice After an upgrade, every enabled hook path must stay live: pool initialization,
    ///         add liquidity, swap, and (flag-disabled) remove liquidity. The on-chain upgrade
    ///         validation only checks the PoolManager and the declared permission set — a V2
    ///         whose callback bodies revert would pass it, so liveness needs exercising.
    function test_upgrade_allEnabledHookPathsStillWork() public {
        _upgradeToV2();

        // Fresh pool through the upgraded hook (beforeInitialize/afterInitialize).
        PoolKey memory freshKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING * 2,
            hooks: IHooks(address(hook))
        });
        vm.prank(poolInitializer);
        hook.initializePool(freshKey, Constants.SQRT_PRICE_1_1, _defaultConfig());

        // Add liquidity (beforeAddLiquidity/afterAddLiquidity).
        modifyLiquidityRouter.modifyLiquidity(
            freshKey,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 100e18, salt: 0}),
            ZERO_BYTES
        );

        // Swap (beforeSwap/afterSwap).
        BalanceDelta delta = swap(freshKey, true, -1e15, ZERO_BYTES);
        assertGt(delta.amount1(), 0);

        // Remove liquidity: the remove flags are permanently disabled by the mined address, so
        // LP exits must never route through the hook — including after upgrades.
        modifyLiquidityRouter.modifyLiquidity(
            freshKey,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: -100e18, salt: 0}),
            ZERO_BYTES
        );
    }

    /// @notice Access control must survive an upgrade BEHAVIORALLY — unauthorized callers still
    ///         revert on privileged entrypoints. `hasRole` getters alone execute the new
    ///         implementation's code, which could report preserved roles while enforcing nothing.
    function test_upgrade_accessControlStillEnforced() public {
        _upgradeToV2();

        bytes32 configRole = hook.CONFIG_MANAGER_ROLE();
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, configRole)
        );
        hook.updateFeeConfig(testPoolKey.toId(), _defaultConfig());

        bytes32 initializerRole = hook.POOL_INITIALIZER_ROLE();
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, initializerRole)
        );
        hook.initializePool(testPoolKey, Constants.SQRT_PRICE_1_1, _defaultConfig());
    }

    // -------------------------------------------------------------------------
    // Initialization safety
    // -------------------------------------------------------------------------

    function test_initialize_revertsOnReinitialization() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        hook.initialize(other, other, other);
    }

    /// @notice The initializer guard must survive upgrades: if a new implementation changed the
    ///         guard's storage slot or semantics, the proxy would look uninitialized again and
    ///         anyone could call `initialize()` to take `DEFAULT_ADMIN_ROLE` (upgrade authority).
    function test_initialize_revertsAfterUpgrade() public {
        _upgradeToV2();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        hook.initialize(other, other, other);

        // And again after a second upgrade.
        _upgradeToV2();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        hook.initialize(other, other, other);
    }

    function test_initialize_revertsOnBareImplementation() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(other, other, other);
    }

    function test_upgradeToAndCall_revertsOnBareImplementation() public {
        // onlyProxy: the implementation itself can never be upgraded.
        StablePairHookV2Mock v2Impl = new StablePairHookV2Mock(manager);
        vm.expectRevert(abi.encodeWithSignature("UUPSUnauthorizedCallContext()"));
        impl.upgradeToAndCall(address(v2Impl), "");
    }

    // -------------------------------------------------------------------------
    // Deployment-time flag validation
    // -------------------------------------------------------------------------

    /// @notice The proxy's mined address must carry exactly the frozen 6-flag set (widened from 2
    ///         to restore the old forwarder's upgrade headroom): BEFORE_INITIALIZE, AFTER_INITIALIZE,
    ///         BEFORE_ADD_LIQUIDITY, AFTER_ADD_LIQUIDITY, BEFORE_SWAP, AFTER_SWAP — no more, no less.
    function test_hookAddress_hasExactlyFrozenFlagSet() public view {
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, HOOK_FLAGS);
    }

    /// @notice `__BaseUUPSHook_init` calls `Hooks.validateHookPermissions(this, getHookPermissions())`
    ///         during the proxy's constructor-time `initialize` delegatecall. A plain `new
    ///         ERC1967Proxy(...)` lands at an ordinary CREATE address, which does not carry the
    ///         BEFORE_INITIALIZE/BEFORE_SWAP flag bits `getHookPermissions()` requires, so
    ///         construction must revert. OZ's `Address.functionDelegateCall` bubbles the raw
    ///         delegatecall revert data unchanged (see `LowLevelCall.bubbleRevert`), so the
    ///         top-level revert is the exact, un-wrapped `Hooks.HookAddressNotValid(address)`
    ///         with the proxy's own (about-to-be-deployed) address as the argument.
    function test_deploy_revertsForInvalidHookAddress() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new ERC1967Proxy(
            address(impl), abi.encodeCall(BaseDynamicFeeHook.initialize, (owner, poolInitializer, configManager))
        );
    }

    /// @notice The zero-admin check in `__BaseUUPSHook_init` runs before flag validation, so it
    ///         reverts regardless of the deployed proxy's address/flags.
    function test_deploy_revertsForZeroAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(BaseDynamicFeeHook.InvalidAdmin.selector, address(0)));
        new ERC1967Proxy(
            address(impl), abi.encodeCall(BaseDynamicFeeHook.initialize, (address(0), poolInitializer, configManager))
        );
    }

    /// @notice Same for admin == the proxy itself. The proxy's CREATE address is deterministic
    ///         and knowable pre-deploy via `vm.computeCreateAddress`, so it can be passed as the
    ///         `_admin` argument in the same `initialize` calldata used to construct it.
    function test_deploy_revertsForSelfAdmin() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(abi.encodeWithSelector(BaseDynamicFeeHook.InvalidAdmin.selector, predicted));
        new ERC1967Proxy(
            address(impl), abi.encodeCall(BaseDynamicFeeHook.initialize, (predicted, poolInitializer, configManager))
        );
    }

    // -------------------------------------------------------------------------
    // Admin handover (standard OZ pattern: grant new admin, old revokes itself)
    // -------------------------------------------------------------------------

    function test_adminHandover_movesUpgradeRights() public {
        address newAdmin = makeAddr("newAdmin");
        bytes32 adminRole = hook.DEFAULT_ADMIN_ROLE();

        // Grant the new admin, then the old admin revokes its own role (two holders transiently).
        vm.startPrank(owner);
        hook.grantRole(adminRole, newAdmin);
        hook.revokeRole(adminRole, owner);
        vm.stopPrank();
        assertFalse(hook.hasRole(adminRole, owner));
        assertTrue(hook.hasRole(adminRole, newAdmin));

        // Old admin has lost upgrade rights.
        StablePairHookV2Mock v2Impl = new StablePairHookV2Mock(manager);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, owner, adminRole)
        );
        hook.upgradeToAndCall(address(v2Impl), "");

        // New admin holds them.
        vm.prank(newAdmin);
        hook.upgradeToAndCall(address(v2Impl), "");
        assertEq(StablePairHookV2Mock(address(hook)).version(), 2);
    }

    /// @notice Renouncing DEFAULT_ADMIN_ROLE permanently freezes upgrades (the accepted
    ///         immutability endgame): no admin remains, and no one can grant one.
    function test_renounceAdmin_freezesUpgrades() public {
        bytes32 adminRole = hook.DEFAULT_ADMIN_ROLE();
        vm.prank(owner);
        hook.renounceRole(adminRole, owner);
        assertFalse(hook.hasRole(adminRole, owner));

        // The former admin can no longer upgrade...
        StablePairHookV2Mock v2Impl = new StablePairHookV2Mock(manager);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, owner, adminRole)
        );
        hook.upgradeToAndCall(address(v2Impl), "");

        // ...nor can it re-grant the admin role to anyone (upgrades are frozen forever).
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, owner, adminRole)
        );
        hook.grantRole(adminRole, owner);
    }
}
