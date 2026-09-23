// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {BaseALFHook} from "../../src/alf/base/BaseALFHook.sol";
import {IALFHook, ALFHookData} from "../../src/alf/interfaces/IALFHook.sol";
import {MockQuoterHook} from "./mocks/MockQuoterHook.sol";

/// @dev Minimal concrete BaseALFHook that overrides NOTHING optional: every default surface
///      (`_price` → 0, `getReserves`/`getEffectiveLiquidity` → (0, 0), `swapToPrice` → (0, 0))
///      is served by the base implementation. Declares no hook permissions, so it deploys at a
///      flag-free address.
contract BareALFHook is BaseALFHook {
    constructor(IPoolManager _poolManager, uint32 maxGas_) BaseALFHook(_poolManager, maxGas_) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function isLive() external pure override returns (bool) {
        return true;
    }
}

contract BaseALFHookTest is Test, Deployers {
    MockQuoterHook public hook;

    address owner = makeAddr("owner");

    Currency tokenA;
    Currency tokenB;
    PoolKey testPoolKey;

    function setUp() public {
        deployFreshManagerAndRouters();

        // Deploy MockQuoterHook at a flag-mined address
        uint160 flags =
            uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        hook = MockQuoterHook(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags)));
        deployCodeTo("MockQuoterHook", abi.encode(manager, uint32(50_000)), address(hook));

        tokenA = Currency.wrap(address(0xA));
        tokenB = Currency.wrap(address(0xB));
        testPoolKey =
            PoolKey({currency0: tokenA, currency1: tokenB, fee: 3000, tickSpacing: 60, hooks: IHooks(address(hook))});

        // Set default prices
        hook.setPrice(1000e18, 1001e18);
    }

    // ──── maxGas ────

    function test_maxGas_returnsConstructorValue() public view {
        assertEq(hook.maxGas(), 50_000);
    }

    // ──── getIndicativeQuote ────

    function test_getIndicativeQuote_unattested() public view {
        uint256 output = hook.getIndicativeQuote(testPoolKey, true, -1e18, "");
        assertEq(output, 1000e18);
    }

    // ──── isLive ────

    function test_isLive() public view {
        assertTrue(hook.isLive());
    }

    function test_isLive_afterSetFalse() public {
        hook.setLive(false);
        assertFalse(hook.isLive());
    }

    // ──── ERC-165 advertisement ────

    function test_supportsInterface_advertisesALFSurfaces() public view {
        assertTrue(hook.supportsInterface(type(IALFHook).interfaceId), "IALFHook advertised");
        assertTrue(hook.supportsInterface(type(IHooks).interfaceId), "IHooks advertised");
        assertTrue(hook.supportsInterface(type(IERC165).interfaceId), "IERC165 advertised");
        assertFalse(hook.supportsInterface(bytes4(0xdeadbeef)), "unknown interface rejected");
    }

    // ──── hookData resolution ────

    /// @dev A well-formed ALFHookData envelope resolves through the default (non-verifying)
    ///      attestation path: the quote is served exactly as for empty hookData.
    function test_getIndicativeQuote_withHookDataEnvelope_unattestedByDefault() public view {
        bytes memory hookData = abi.encode(ALFHookData({attestationData: "attestation-bytes"}));
        uint256 output = hook.getIndicativeQuote(testPoolKey, true, -1e18, hookData);
        assertEq(output, 1000e18, "default attestation resolution treats the call as unattested");
    }

    // ──── Base defaults (no overrides) ────

    /// @dev The base contract's optional surfaces must be safe no-ops for quoters that do not
    ///      implement them: 0 for the indicative (IALFHook's "cannot price this swap"), and
    ///      (0, 0) for reserves and price-bounded simulation.
    function test_baseDefaults_reportNoPricingAndNoReserves() public {
        // Flag-free address: BareALFHook declares no hook permissions.
        BareALFHook bare = BareALFHook(payable(address(uint160(0xBA5E) << 20)));
        deployCodeTo("BaseALFHook.t.sol:BareALFHook", abi.encode(manager, uint32(75_000)), address(bare));

        assertEq(bare.maxGas(), 75_000);
        assertTrue(bare.isLive());
        assertEq(bare.getIndicativeQuote(testPoolKey, true, -1e18, ""), 0, "default _price is 0");

        (uint256 r0, uint256 r1) = bare.getReserves(testPoolKey);
        assertEq(r0, 0, "default reserves are zero");
        assertEq(r1, 0);

        (uint256 e0, uint256 e1) = bare.getEffectiveLiquidity(testPoolKey);
        assertEq(e0, 0, "default effective liquidity is zero");
        assertEq(e1, 0);

        (uint256 amountIn, uint256 amountOut) = bare.swapToPrice(testPoolKey, true, -1e18, 0, "");
        assertEq(amountIn, 0, "default swapToPrice is unsupported");
        assertEq(amountOut, 0);
    }

    /// @dev MockQuoterHook overrides `getEffectiveLiquidity` but inherits `getReserves` and
    ///      `swapToPrice` from the base: the pairing invariant (effective <= reserves) is the
    ///      override's responsibility, but the untouched defaults must still be (0, 0).
    function test_inheritedDefaults_onPartialOverride() public view {
        (uint256 r0, uint256 r1) = hook.getReserves(testPoolKey);
        assertEq(r0, 0);
        assertEq(r1, 0);

        (uint256 amountIn, uint256 amountOut) = hook.swapToPrice(testPoolKey, true, -1e18, 0, "");
        assertEq(amountIn, 0);
        assertEq(amountOut, 0);
    }
}
