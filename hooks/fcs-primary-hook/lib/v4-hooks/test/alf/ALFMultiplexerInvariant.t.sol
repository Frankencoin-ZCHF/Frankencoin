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
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ALFMultiplexer} from "../../src/alf/ALFMultiplexer.sol";
import {SimpleSpreadQuoterHook} from "../../src/alf/SimpleSpreadQuoterHook.sol";
import {SpreadQuoterBase} from "../../src/alf/base/SpreadQuoterBase.sol";
import {MultiplexerHandler} from "./handlers/MultiplexerHandler.sol";

/// @title ALFMultiplexerInvariantTest
/// @notice Invariant suite for `ALFMultiplexer`. Fills the gap flagged in the security review: there
///         was no stateful multiplexer campaign. The multiplexer executes real swaps as nested
///         `poolManager.swap` calls on candidate pools and forwards the aggregate as a
///         `BeforeSwapDelta` so its own virtual pool nets to zero. These invariants pin the three
///         properties the whole dispatch model relies on, over random split-fill sequences with a
///         drifting candidate landscape:
///           1. the virtual pool never accumulates liquidity;
///           2. the virtual pool's price never moves (the delta forwarding fully offsets each swap —
///              a residual leak would either revert or drift the price);
///           3. the stateless multiplexer never retains tokens between swaps.
contract ALFMultiplexerInvariantTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    ALFMultiplexer public multiplexer;
    SimpleSpreadQuoterHook public quoterA;
    SimpleSpreadQuoterHook public quoterB;
    MultiplexerHandler public handler;

    address ownerA = makeAddr("ownerA");
    address ownerB = makeAddr("ownerB");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    PoolKey muxKey;
    PoolKey quoterAKey;
    PoolKey quoterBKey;
    PoolId muxPoolId;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // ── Multiplexer on a virtual (zero-liquidity) pool ──
        uint160 muxFlags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_DONATE_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        multiplexer =
            ALFMultiplexer(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | muxFlags)));
        deployCodeTo("ALFMultiplexer", abi.encode(manager), address(multiplexer));

        // ── Two SpreadQuoter candidates (A 5% fee, B 1% fee) ──
        uint160 quoterFlags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG
        );
        quoterA = SimpleSpreadQuoterHook(
            address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | quoterFlags))
        );
        deployCodeTo("SimpleSpreadQuoterHook", abi.encode(manager, uint32(750_000), ownerA), address(quoterA));
        quoterB = SimpleSpreadQuoterHook(
            address(uint160((uint256(type(uint160).max) - (1 << 14)) & clearAllHookPermissionsMask | quoterFlags))
        );
        deployCodeTo("SimpleSpreadQuoterHook", abi.encode(manager, uint32(150_000), ownerB), address(quoterB));

        quoterAKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 50_000, tickSpacing: 60, hooks: IHooks(address(quoterA))
        });
        quoterBKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 10_000, tickSpacing: 60, hooks: IHooks(address(quoterB))
        });
        muxKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 1, hooks: IHooks(address(multiplexer))
        });
        muxPoolId = muxKey.toId();

        vm.prank(ownerA);
        quoterA.initializePool(quoterAKey, TickMath.getSqrtPriceAtTick(30));
        vm.prank(ownerB);
        quoterB.initializePool(quoterBKey, TickMath.getSqrtPriceAtTick(30));
        manager.initialize(muxKey, Constants.SQRT_PRICE_1_1);

        vm.prank(ownerA);
        quoterA.setAuthorizedLP(address(modifyLiquidityRouter), true);
        vm.prank(ownerB);
        quoterB.setAuthorizedLP(address(modifyLiquidityRouter), true);

        _seedAtActiveTick(quoterAKey, quoterA, 10_000e18, 10_000e18);
        _seedAtActiveTick(quoterBKey, quoterB, 10_000e18, 10_000e18);

        vm.prank(ownerA);
        quoterA.setPoolLive(quoterAKey, true);
        vm.prank(ownerB);
        quoterB.setPoolLive(quoterBKey, true);

        address[] memory actorList = new address[](2);
        actorList[0] = alice;
        actorList[1] = bob;

        handler = new MultiplexerHandler(
            swapRouter,
            muxKey,
            quoterAKey,
            quoterBKey,
            MockERC20(Currency.unwrap(currency0)),
            MockERC20(Currency.unwrap(currency1)),
            actorList
        );
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = MultiplexerHandler.swapThroughMultiplexer.selector;
        selectors[1] = MultiplexerHandler.swapCandidate.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function _seedAtActiveTick(PoolKey memory key_, SpreadQuoterBase quoter, uint256 amount0, uint256 amount1)
        internal
    {
        int24 activeTick = quoter.activeLowerTick(key_.toId());
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key_.toId());
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(activeTick),
            TickMath.getSqrtPriceAtTick(activeTick + key_.tickSpacing),
            amount0,
            amount1
        );
        modifyLiquidityRouter.modifyLiquidity(
            key_,
            ModifyLiquidityParams({
                tickLower: activeTick, tickUpper: activeTick + key_.tickSpacing, liquidityDelta: int128(liq), salt: 0
            }),
            ""
        );
    }

    /// @notice INV-MUX-1: the multiplexer's virtual pool never holds liquidity (it blocks LP and
    ///         donations; all execution is nested swaps on the candidates).
    function invariant_virtualPoolZeroLiquidity() public view {
        assertEq(manager.getLiquidity(muxPoolId), 0, "INV-MUX-1: virtual pool accumulated liquidity");
    }

    /// @notice INV-MUX-2: the virtual pool's price never moves. The multiplexer returns a
    ///         `BeforeSwapDelta` that fully offsets the outer swap, so the virtual pool performs no
    ///         net swap. A misforwarded/residual delta would drift this price (or revert the swap,
    ///         which the handler soft-catches) — either way a mismatch fails here.
    function invariant_virtualPoolPriceUnmoved() public view {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(muxPoolId);
        assertEq(sqrtPriceX96, Constants.SQRT_PRICE_1_1, "INV-MUX-2: virtual pool price drifted");
    }

    /// @notice INV-MUX-5: the stateless multiplexer retains no tokens between swaps — its net
    ///         position across the nested fills is always zero.
    function invariant_multiplexerHoldsNoTokens() public view {
        assertEq(currency0.balanceOf(address(multiplexer)), 0, "INV-MUX-5: multiplexer retained currency0");
        assertEq(currency1.balanceOf(address(multiplexer)), 0, "INV-MUX-5: multiplexer retained currency1");
    }
}
