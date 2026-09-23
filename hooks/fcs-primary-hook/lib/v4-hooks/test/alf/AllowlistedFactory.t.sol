// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {HookMiner} from "../../src/utils/HookMiner.sol";
import {AllowlistedFactory} from "../../src/AllowlistedFactory.sol";
import {IAllowlistedFactory} from "../../src/interfaces/IAllowlistedFactory.sol";
import {DualPoolHook} from "../../src/alf/DualPoolHook.sol";
import {LiquidityBucket} from "../../src/alf/types/Distribution.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";

/// @title AllowlistedFactoryTest
/// @notice Tests for the AllowlistedFactory: hash-pinned CREATE2 deployment, registration and
///         discovery views, the hooks' `factory()` provenance getter, and the failure paths
///         (foreign bytecode, salt reuse, wrong-flag salts).
contract AllowlistedFactoryTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );

    uint32 constant MAX_GAS = 100_000;
    uint64 constant MAX_MIN_DEPOSIT_BLOCKS = 3_600;

    AllowlistedFactory factory;

    bytes32 dualPoolHash;

    address owner = makeAddr("owner");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        dualPoolHash = keccak256(type(DualPoolHook).creationCode);

        bytes32[] memory allowed = new bytes32[](1);
        allowed[0] = dualPoolHash;
        factory = new AllowlistedFactory(allowed);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    function _args() internal view returns (bytes memory) {
        return abi.encode(manager, MAX_GAS, owner, MAX_MIN_DEPOSIT_BLOCKS);
    }

    /// @dev Mine a flags-valid salt against the factory as CREATE2 deployer and deploy through it.
    function _mineAndDeploy(bytes memory creationCode) internal returns (address expected, bytes32 salt, address hook) {
        (expected, salt) = HookMiner.find(address(factory), FLAGS, creationCode, _args());
        hook = factory.deploy(creationCode, _args(), salt);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    function test_constructor_setsAllowlist() public view {
        assertTrue(factory.isAllowedCreationCode(dualPoolHash));
        assertFalse(factory.isAllowedCreationCode(keccak256("something else")));
        assertEq(factory.allDeploymentsLength(), 0);
    }

    function test_constructor_revertsWhen_emptyAllowlist() public {
        vm.expectRevert(IAllowlistedFactory.InvalidAllowlist.selector);
        new AllowlistedFactory(new bytes32[](0));
    }

    function test_constructor_revertsWhen_zeroHashEntry() public {
        bytes32[] memory allowed = new bytes32[](2);
        allowed[0] = dualPoolHash;
        allowed[1] = bytes32(0);
        vm.expectRevert(IAllowlistedFactory.InvalidAllowlist.selector);
        new AllowlistedFactory(allowed);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              DEPLOYMENT
    // ═══════════════════════════════════════════════════════════════════════════

    function test_deploy_deploysAtMinedAddress_withValidFlags() public {
        (address expected, bytes32 salt, address hook) = _mineAndDeploy(type(DualPoolHook).creationCode);

        assertEq(hook, expected);
        assertEq(hook, factory.computeAddress(type(DualPoolHook).creationCode, _args(), salt));
        assertEq(uint160(hook) & HookMiner.FLAG_MASK, FLAGS);
        assertGt(hook.code.length, 0);
    }

    function test_deploy_registersHook() public {
        (,, address hook) = _mineAndDeploy(type(DualPoolHook).creationCode);

        assertTrue(factory.isFromFactory(hook));
        assertEq(factory.creationCodeHashOf(hook), dualPoolHash);
        assertEq(factory.allDeploymentsLength(), 1);
        assertEq(factory.allDeployments(0), hook);

        assertFalse(factory.isFromFactory(makeAddr("not a hook")));
        assertEq(factory.creationCodeHashOf(makeAddr("not a hook")), bytes32(0));
    }

    function test_deploy_emitsDeployed() public {
        bytes memory creationCode = type(DualPoolHook).creationCode;
        (address expected, bytes32 salt) = HookMiner.find(address(factory), FLAGS, creationCode, _args());

        vm.expectEmit(true, true, true, true, address(factory));
        emit IAllowlistedFactory.Deployed(expected, dualPoolHash, address(this), _args(), salt);
        factory.deploy(creationCode, _args(), salt);
    }

    function test_deploy_hookReportsFactoryAndConfig() public {
        (,, address hookAddr) = _mineAndDeploy(type(DualPoolHook).creationCode);
        DualPoolHook hook = DualPoolHook(hookAddr);

        assertEq(hook.factory(), address(factory));
        assertEq(hook.owner(), owner);
        assertEq(hook.maxGas(), MAX_GAS);
        assertEq(hook.maxMinDepositBlocks(), MAX_MIN_DEPOSIT_BLOCKS);
    }

    function test_deploy_multipleHooks_enumerateInOrder() public {
        // HookMiner skips occupied addresses, so a second identical deploy mines a fresh salt.
        (,, address first) = _mineAndDeploy(type(DualPoolHook).creationCode);
        (,, address second) = _mineAndDeploy(type(DualPoolHook).creationCode);

        assertEq(factory.allDeploymentsLength(), 2);
        assertEq(factory.allDeployments(0), first);
        assertEq(factory.allDeployments(1), second);
    }

    /// @dev End-to-end sanity: a factory-deployed hook is fully operational against the
    ///      PoolManager (its guarded `initializePool` works and the pool registers).
    function test_deploy_deployedHookInitializesPool() public {
        (,, address hookAddr) = _mineAndDeploy(type(DualPoolHook).creationCode);
        DualPoolHook hook = DualPoolHook(hookAddr);

        MockERC4626 vault0 = new MockERC4626(ERC20(Currency.unwrap(currency0)));
        MockERC4626 vault1 = new MockERC4626(ERC20(Currency.unwrap(currency1)));

        LiquidityBucket[] memory dist = new LiquidityBucket[](1);
        dist[0] = LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 10_000});

        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 1_000, tickSpacing: 10, hooks: IHooks(hookAddr)});

        vm.prank(owner);
        hook.initializePool(
            key,
            DualPoolHook.PoolConfig({
                sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
                distribution: dist,
                allowExternalDeposits: false,
                vault0: IERC4626(address(vault0)),
                vault1: IERC4626(address(vault1)),
                minDepositBlocks: 0
            })
        );

        assertEq(hook.getDistribution(key.toId()).length, 1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              REVERTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_deploy_revertsWhen_creationCodeNotAllowed() public {
        bytes memory foreign = type(MockERC20).creationCode;
        vm.expectRevert(abi.encodeWithSelector(IAllowlistedFactory.CreationCodeNotAllowed.selector, keccak256(foreign)));
        factory.deploy(foreign, _args(), bytes32(0));
    }

    function test_deploy_revertsWhen_saltReused() public {
        (, bytes32 salt,) = _mineAndDeploy(type(DualPoolHook).creationCode);

        // Identical init code + salt resolves to the already-occupied address: CREATE2 fails and
        // OZ Create2 surfaces it, so the registry entry cannot be overwritten.
        vm.expectRevert(Errors.FailedDeployment.selector);
        factory.deploy(type(DualPoolHook).creationCode, _args(), salt);
    }

    function test_deploy_revertsWhen_saltNotMinedForFlags() public {
        bytes memory creationCode = type(DualPoolHook).creationCode;

        // Find a salt whose address does NOT carry the required flags (nearly any salt; step past
        // the astronomically rare accidental match so the test is stable across builds).
        uint256 saltSeed = uint256(keccak256("wrong flags"));
        address expected;
        while (true) {
            expected = factory.computeAddress(creationCode, _args(), bytes32(saltSeed));
            if (uint160(expected) & HookMiner.FLAG_MASK != FLAGS) break;
            ++saltSeed;
        }

        // BaseHook's constructor validates the address flags, so the CREATE2 reverts and the
        // factory bubbles the hook's own error.
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, expected));
        factory.deploy(creationCode, _args(), bytes32(saltSeed));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              PROVENANCE SEMANTICS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev `factory()` reports the constructor-time `msg.sender`, whoever that is: a hook
    ///      deployed outside the factory reports its direct deployer and is NOT registered.
    ///      Aggregators must therefore check provenance against the known factory address.
    function test_factory_reportsDirectDeployer_forNonFactoryDeploys() public {
        address hookAddr = address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | FLAGS));
        deployCodeTo("DualPoolHook", _args(), hookAddr);

        assertEq(DualPoolHook(hookAddr).factory(), address(this));
        assertFalse(factory.isFromFactory(hookAddr));
    }
}
