// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {PrimaryHookTest, InertGovernanceFactory} from "./PrimaryHook.t.sol";
import {FCSPrimaryHook} from "../src/FCSPrimaryHook.sol";
import {FCSPrimaryRouter} from "../src/FCSPrimaryRouter.sol";
import {IFCS} from "../src/interfaces/IFCS.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {HookMiner} from "v4-hooks/utils/HookMiner.sol";
import {TestERC20} from "@uniswap/v4-core/src/test/TestERC20.sol";
import {Frankencoin} from "frankencoin/stablecoin/Frankencoin.sol";
import {FCS, IGovernanceFactory} from "frankencoin/equity/shares/FCS.sol";
import {Equity} from "frankencoin/equity/Equity.sol";
import {IFrankencoin} from "frankencoin/stablecoin/IFrankencoin.sol";
import {IGovernance} from "frankencoin/equity/IGovernance.sol";

/// @dev TEST ONLY generic unlock-callback executor. Lets a test compose arbitrary PoolManager
/// action sequences (prefund, ERC6909 claims, LP pools, nested calls) around the primary hook.
contract ActionRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    enum Kind {
        PREFUND,
        SWAP,
        SWAP_ALL_CREDIT,
        TAKE,
        TAKE_ALL,
        SETTLE_ALL,
        MINT_CLAIMS,
        BURN_CLAIMS,
        MODIFY_LIQ,
        DONATE,
        CALL
    }

    struct Action {
        Kind kind;
        bytes data;
    }

    struct Ctx {
        address payer;
        Action[] actions;
    }

    error CallFailed(bytes reason);

    IPoolManager public immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    function run(Action[] memory actions) external returns (bytes memory) {
        return manager.unlock(abi.encode(Ctx(msg.sender, actions)));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory last) {
        require(msg.sender == address(manager), "not manager");
        Ctx memory c = abi.decode(raw, (Ctx));
        for (uint256 i; i < c.actions.length; ++i) {
            Action memory a = c.actions[i];
            if (a.kind == Kind.PREFUND) {
                (Currency cur, uint256 amount) = abi.decode(a.data, (Currency, uint256));
                manager.sync(cur);
                IERC20(Currency.unwrap(cur)).transferFrom(c.payer, address(manager), amount);
                manager.settle();
            } else if (a.kind == Kind.SWAP) {
                (PoolKey memory k, SwapParams memory p, bytes memory hd) =
                    abi.decode(a.data, (PoolKey, SwapParams, bytes));
                last = abi.encode(manager.swap(k, p, hd));
            } else if (a.kind == Kind.SWAP_ALL_CREDIT) {
                (PoolKey memory k, bool zeroForOne, bytes memory hd) = abi.decode(a.data, (PoolKey, bool, bytes));
                int256 credit = manager.currencyDelta(address(this), zeroForOne ? k.currency0 : k.currency1);
                require(credit > 0, "no credit");
                last = abi.encode(
                    manager.swap(
                        k,
                        SwapParams(
                            zeroForOne, -credit, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                        ),
                        hd
                    )
                );
            } else if (a.kind == Kind.TAKE) {
                (Currency cur, address to, uint256 amount) = abi.decode(a.data, (Currency, address, uint256));
                manager.take(cur, to, amount);
            } else if (a.kind == Kind.TAKE_ALL) {
                (Currency cur, address to) = abi.decode(a.data, (Currency, address));
                int256 d = manager.currencyDelta(address(this), cur);
                if (d > 0) manager.take(cur, to, uint256(d));
            } else if (a.kind == Kind.SETTLE_ALL) {
                Currency cur = abi.decode(a.data, (Currency));
                int256 d = manager.currencyDelta(address(this), cur);
                if (d < 0) {
                    manager.sync(cur);
                    IERC20(Currency.unwrap(cur)).transferFrom(c.payer, address(manager), uint256(-d));
                    manager.settle();
                }
            } else if (a.kind == Kind.MINT_CLAIMS) {
                (Currency cur, uint256 amount) = abi.decode(a.data, (Currency, uint256));
                manager.mint(address(this), cur.toId(), amount);
            } else if (a.kind == Kind.BURN_CLAIMS) {
                (Currency cur, uint256 amount) = abi.decode(a.data, (Currency, uint256));
                manager.burn(address(this), cur.toId(), amount);
            } else if (a.kind == Kind.MODIFY_LIQ) {
                (PoolKey memory k, ModifyLiquidityParams memory p) =
                    abi.decode(a.data, (PoolKey, ModifyLiquidityParams));
                manager.modifyLiquidity(k, p, "");
            } else if (a.kind == Kind.DONATE) {
                (PoolKey memory k, uint256 a0, uint256 a1) = abi.decode(a.data, (PoolKey, uint256, uint256));
                manager.donate(k, a0, a1, "");
            } else if (a.kind == Kind.CALL) {
                (address target, bytes memory data) = abi.decode(a.data, (address, bytes));
                (bool ok, bytes memory ret) = target.call(data);
                if (!ok) revert CallFailed(ret);
                last = ret;
            }
        }
    }
}

/// @notice Additional deep tests: hostile/alternate pool states, both token orderings, realistic
/// aggregator funding paths (ERC6909 claims, LP-pool multi-hop), protocol fee, nesting, bootstrap.
contract DeepTestingTest is PrimaryHookTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    bytes32 constant EXECUTION_TOPIC = keccak256("PrimaryExecution(bytes32,address,bool,uint256,uint256)");

    struct Stack {
        Frankencoin zchf;
        Equity fps;
        FCS fcs;
        IPoolManager manager;
        FCSPrimaryHook hook;
        FCSPrimaryRouter router;
        PoolKey key;
    }

    // ---------------------------------------------------------------- fixtures

    /// @dev Builds a complete independent stack. fcsAt != 0 places the genuine FCS at a chosen
    /// address (to force a token ordering). seed == 0 leaves the system un-bootstrapped.
    function _buildStack(address fcsAt, uint256 seed, bool init, uint160 price) internal returns (Stack memory s) {
        s.zchf = new Frankencoin(14 days);
        s.zchf.initialize(address(this), "deep test fixture");
        s.zchf.mint(address(this), 100_000_000e18);
        s.fps = Equity(address(s.zchf.reserve()));
        IGovernanceFactory factory = IGovernanceFactory(address(new InertGovernanceFactory()));
        if (fcsAt == address(0)) {
            s.fcs = new FCS(factory, IGovernance(address(s.fps)), IFrankencoin(address(s.zchf)));
        } else {
            deployCodeTo(
                "FCS.sol:FCS", abi.encode(factory, IGovernance(address(s.fps)), IFrankencoin(address(s.zchf))), fcsAt
            );
            s.fcs = FCS(fcsAt);
        }
        s.zchf.approve(address(s.fcs), type(uint256).max);
        if (seed != 0) {
            s.fcs.deposit(seed, address(this));
            vm.warp(block.timestamp + 100 days);
            assertTrue(s.fcs.isBinding());
            assertTrue(s.fps.canRedeem(address(s.fcs)));
        }
        s.manager = IPoolManager(address(new PoolManager(address(this))));
        bytes memory args = abi.encode(s.manager, IFCS(address(s.fcs)));
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), 0x2888, type(FCSPrimaryHook).creationCode, args);
        s.hook = new FCSPrimaryHook{salt: salt}(s.manager, IFCS(address(s.fcs)));
        assertEq(address(s.hook), predicted);
        s.router = s.hook.router();
        s.key = s.router.poolKey();
        if (init) s.manager.initialize(s.key, price);
    }

    function _user(Stack memory s, uint256 salt) internal returns (address user) {
        user = address(uint160(uint256(keccak256(abi.encode(address(s.fcs), salt)))));
        s.zchf.transfer(user, 10_000e18);
        s.fcs.transfer(user, 10e18);
        vm.startPrank(user);
        s.zchf.approve(address(s.router), type(uint256).max);
        s.fcs.approve(address(s.router), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Buys and sells through the bundled router; both must equal the amount-specific preview.
    function _roundTrip(Stack memory s, address user) internal {
        uint256 buyQuote = s.fcs.previewDeposit(1000e18);
        uint256 fcsBefore = s.fcs.balanceOf(user);
        vm.prank(user);
        uint256 bought = s.router.swapExactInput(true, 1000e18, buyQuote, user, block.timestamp);
        assertEq(bought, buyQuote, "buy != preview");
        assertEq(s.fcs.balanceOf(user), fcsBefore + bought);
        uint256 sellQuote = s.fcs.previewRedeem(1e18);
        uint256 zchfBefore = s.zchf.balanceOf(user);
        vm.prank(user);
        uint256 sold = s.router.swapExactInput(false, 1e18, sellQuote, user, block.timestamp);
        assertEq(sold, sellQuote, "sell != preview");
        assertEq(s.zchf.balanceOf(user), zchfBefore + sold);
        _residue(s);
    }

    function _residue(Stack memory s) internal view {
        assertEq(s.zchf.balanceOf(address(s.hook)), 0);
        assertEq(s.fcs.balanceOf(address(s.hook)), 0);
        assertEq(s.zchf.balanceOf(address(s.router)), 0);
        assertEq(s.fcs.balanceOf(address(s.router)), 0);
        assertEq(s.zchf.balanceOf(address(s.manager)), 0);
        assertEq(s.fcs.balanceOf(address(s.manager)), 0);
        assertEq(s.manager.getLiquidity(s.key.toId()), 0);
    }

    function _main() internal view returns (Stack memory s) {
        s = Stack(zchf, fps, fcs, manager, hook, router, key);
    }

    function _actionRouter() internal returns (ActionRouter ar) {
        ar = new ActionRouter(manager);
        vm.startPrank(alice);
        zchf.approve(address(ar), type(uint256).max);
        fcs.approve(address(ar), type(uint256).max);
        vm.stopPrank();
    }

    function _act(ActionRouter.Kind kind, bytes memory data) internal pure returns (ActionRouter.Action memory) {
        return ActionRouter.Action(kind, data);
    }

    function _hookRevert(address h, bytes4 inner) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            h,
            IHooks.beforeSwap.selector,
            abi.encodeWithSelector(inner),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _executionLogs(Vm.Log[] memory logs, address h) internal pure returns (Vm.Log[] memory filtered) {
        filtered = new Vm.Log[](logs.length);
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == h && logs[i].topics.length != 0 && logs[i].topics[0] == EXECUTION_TOPIC) {
                filtered[count++] = logs[i];
            }
        }
        assembly ("memory-safe") {
            mstore(filtered, count)
        }
    }

    // ------------------------------------------------- pool state independence

    /// @dev Anyone can initialize the canonical pool first, at any valid price. The bundled router
    /// hardcodes extreme sqrtPriceLimits; execution must not depend on the initializer's choice.
    function test_hostileInitialPriceCannotBrickBundledRouter() public {
        uint160[3] memory prices = [TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1, uint160(1 << 96) * 12345];
        for (uint256 i; i < prices.length; ++i) {
            Stack memory s = _buildStack(address(0), 1_000_000e18, false, 0);
            vm.prank(address(0xBAD));
            s.manager.initialize(s.key, prices[i]);
            (uint160 price, int24 tick,,) = s.manager.getSlot0(s.key.toId());
            assertEq(price, prices[i]);
            address user = _user(s, i);
            _roundTrip(s, user);
            (uint160 priceAfter, int24 tickAfter,,) = s.manager.getSlot0(s.key.toId());
            assertEq(priceAfter, price, "primary execution must not move slot0");
            assertEq(tickAfter, tick);
        }
    }

    function test_uninitializedCanonicalPoolRevertsThenWorksAfterAnyoneInitializes() public {
        Stack memory s = _buildStack(address(0), 1_000_000e18, false, 0);
        address user = _user(s, 7);
        vm.prank(user);
        vm.expectRevert(IPoolManager.PoolNotInitialized.selector);
        s.router.swapExactInput(true, 1000e18, 1, user, block.timestamp);
        vm.prank(address(0xBAD));
        s.manager.initialize(s.key, 1 << 96);
        _roundTrip(s, user);
    }

    /// @dev Local fixtures happen to produce one token ordering; the base contract has a branch
    /// for each. Force both orderings with the genuine FCS bytecode at chosen addresses.
    function test_bothCurrencyOrderingsExecuteAndLabelDirection() public {
        Stack memory low = _buildStack(address(uint160(4037)), 1_000_000e18, true, 1 << 96);
        Stack memory high = _buildStack(address(type(uint160).max - 58), 1_000_000e18, true, 1 << 96);
        assertFalse(low.hook.wrapZeroForOne(), "FCS below ZCHF => wrapZeroForOne false");
        assertTrue(high.hook.wrapZeroForOne(), "FCS above ZCHF => wrapZeroForOne true");
        assertEq(Currency.unwrap(low.key.currency0), address(low.fcs));
        assertEq(Currency.unwrap(high.key.currency0), address(high.zchf));
        _orderingCase(low);
        _orderingCase(high);
    }

    function _orderingCase(Stack memory s) internal {
        address user = _user(s, 99);
        uint256 buyQuote = s.fcs.previewDeposit(1000e18);
        vm.recordLogs();
        vm.prank(user);
        uint256 bought = s.router.swapExactInput(true, 1000e18, buyQuote, user, block.timestamp);
        Vm.Log[] memory logs = _executionLogs(vm.getRecordedLogs(), address(s.hook));
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[1], PoolId.unwrap(s.key.toId()));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(s.router)))));
        assertEq(logs[0].data, abi.encode(true, 1000e18, bought), "buy event must be labelled buyFCS=true");
        uint256 sellQuote = s.fcs.previewRedeem(1e18);
        vm.recordLogs();
        vm.prank(user);
        uint256 sold = s.router.swapExactInput(false, 1e18, sellQuote, user, block.timestamp);
        logs = _executionLogs(vm.getRecordedLogs(), address(s.hook));
        assertEq(logs.length, 1);
        assertEq(logs[0].data, abi.encode(false, 1e18, sold), "sell event must be labelled buyFCS=false");
        _residue(s);
    }

    function test_routerAddressMatchesNonceOnePrediction() public view {
        address predicted = address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", address(hook), hex"01")))));
        assertEq(address(router), predicted);
        assertEq(uint160(address(hook)) & ((1 << 14) - 1), 0x2888);
    }

    // ---------------------------------------------- protocol fee / donate paths

    function test_maxProtocolFeeOnCanonicalPoolIsInertForPrimaryExecution() public {
        PoolManager pm = PoolManager(address(manager));
        pm.setProtocolFeeController(address(this));
        uint24 fee = 1000 | (1000 << 12);
        pm.setProtocolFee(key, fee);
        (,, uint24 stored,) = manager.getSlot0(key.toId());
        assertEq(stored, fee);
        _roundTrip(_main(), alice);
        assertEq(manager.protocolFeesAccrued(key.currency0), 0);
        assertEq(manager.protocolFeesAccrued(key.currency1), 0);
    }

    function test_donateToLiquidityLessPrimaryPoolReverts() public {
        ActionRouter ar = _actionRouter();
        ActionRouter.Action[] memory a = new ActionRouter.Action[](1);
        a[0] = _act(ActionRouter.Kind.DONATE, abi.encode(key, uint256(1e18), uint256(0)));
        vm.prank(alice);
        vm.expectRevert(bytes4(keccak256("NoLiquidityToReceiveFees()")));
        ar.run(a);
    }

    // ------------------------------------------- external funding / prefunding

    function test_externalRouterFundsInputWithBurnedERC6909Claims() public {
        ActionRouter ar = _actionRouter();
        Currency cz = Currency.wrap(address(zchf));
        Currency cf = Currency.wrap(address(fcs));
        ActionRouter.Action[] memory a1 = new ActionRouter.Action[](2);
        a1[0] = _act(ActionRouter.Kind.PREFUND, abi.encode(cz, uint256(1000e18)));
        a1[1] = _act(ActionRouter.Kind.MINT_CLAIMS, abi.encode(cz, uint256(1000e18)));
        vm.prank(alice);
        ar.run(a1);
        assertEq(manager.balanceOf(address(ar), cz.toId()), 1000e18, "claims minted");
        assertEq(zchf.balanceOf(address(manager)), 1000e18);
        // Separate transaction: burn claims for credit, then route through the hook.
        uint256 expected = fcs.previewDeposit(1000e18);
        ActionRouter.Action[] memory a2 = new ActionRouter.Action[](3);
        a2[0] = _act(ActionRouter.Kind.BURN_CLAIMS, abi.encode(cz, uint256(1000e18)));
        a2[1] = _act(
            ActionRouter.Kind.SWAP,
            abi.encode(key, _params(true, -int256(1000e18)), abi.encode(expected, block.timestamp))
        );
        a2[2] = _act(ActionRouter.Kind.TAKE_ALL, abi.encode(cf, alice));
        uint256 before = fcs.balanceOf(alice);
        vm.prank(alice);
        ar.run(a2);
        assertEq(fcs.balanceOf(alice) - before, expected);
        assertEq(manager.balanceOf(address(ar), cz.toId()), 0);
        assertEq(zchf.balanceOf(address(manager)), 0);
        assertEq(fcs.balanceOf(address(manager)), 0);
    }

    /// @dev The singleton physically holds one wei less than the swap needs: clear hook-level error.
    function test_swapLargerThanSingletonInventoryRevertsClearly() public {
        ActionRouter ar = _actionRouter();
        ActionRouter.Action[] memory a = new ActionRouter.Action[](3);
        a[0] = _act(ActionRouter.Kind.PREFUND, abi.encode(Currency.wrap(address(zchf)), uint256(1000e18 - 1)));
        a[1] = _act(
            ActionRouter.Kind.SWAP,
            abi.encode(key, _params(true, -int256(1000e18)), abi.encode(uint256(1), block.timestamp))
        );
        a[2] = _act(ActionRouter.Kind.TAKE_ALL, abi.encode(Currency.wrap(address(fcs)), alice));
        uint256 before = zchf.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(FCSPrimaryHook.InsufficientInventory.selector, 1000e18, 1000e18 - 1),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        ar.run(a);
        assertEq(zchf.balanceOf(alice), before);
    }

    function test_excessPrefundStaysWithCallerAndOnlyExactInputIsConsumed() public {
        ActionRouter ar = _actionRouter();
        uint256 expected = fcs.previewDeposit(1000e18);
        ActionRouter.Action[] memory a = new ActionRouter.Action[](4);
        a[0] = _act(ActionRouter.Kind.PREFUND, abi.encode(Currency.wrap(address(zchf)), uint256(1500e18)));
        a[1] = _act(
            ActionRouter.Kind.SWAP,
            abi.encode(key, _params(true, -int256(1000e18)), abi.encode(expected, block.timestamp))
        );
        a[2] = _act(ActionRouter.Kind.TAKE_ALL, abi.encode(Currency.wrap(address(fcs)), alice));
        a[3] = _act(ActionRouter.Kind.TAKE_ALL, abi.encode(Currency.wrap(address(zchf)), alice));
        uint256 z = zchf.balanceOf(alice);
        uint256 f = fcs.balanceOf(alice);
        vm.prank(alice);
        ar.run(a);
        assertEq(z - zchf.balanceOf(alice), 1000e18, "only the specified input is consumed");
        assertEq(fcs.balanceOf(alice) - f, expected);
        assertEq(zchf.balanceOf(address(manager)), 0);
    }

    /// @dev Realistic aggregator route: X -> ZCHF on a normal LP pool, then ZCHF -> FCS through the
    /// primary hook, in one unlock, funded only by the intermediate credit.
    struct Agg {
        TestERC20 x;
        PoolKey lp;
        ActionRouter ar;
        uint256 lpZchf;
        uint256 intermediate;
        uint256 expected;
    }

    function _setupLPPool() internal returns (Agg memory g) {
        g.x = new TestERC20(10_000_000e18);
        Currency cx = Currency.wrap(address(g.x));
        Currency cz = Currency.wrap(address(zchf));
        g.lp = PoolKey(cx < cz ? cx : cz, cx < cz ? cz : cx, 3000, 60, IHooks(address(0)));
        manager.initialize(g.lp, 1 << 96);
        g.ar = _actionRouter();
        g.x.approve(address(g.ar), type(uint256).max);
        zchf.approve(address(g.ar), type(uint256).max);
        ActionRouter.Action[] memory add = new ActionRouter.Action[](3);
        add[0] = _act(ActionRouter.Kind.MODIFY_LIQ, abi.encode(g.lp, ModifyLiquidityParams(-600, 600, 2_000_000e18, 0)));
        add[1] = _act(ActionRouter.Kind.SETTLE_ALL, abi.encode(cx));
        add[2] = _act(ActionRouter.Kind.SETTLE_ALL, abi.encode(cz));
        g.ar.run(add);
        g.lpZchf = zchf.balanceOf(address(manager));
        assertGt(g.lpZchf, 0, "LP pool holds ZCHF reserves inside the singleton");
        g.x.mint(alice, 1000e18);
        vm.prank(alice);
        g.x.approve(address(g.ar), type(uint256).max);
    }

    function _lpLeg(Agg memory g) internal view returns (ActionRouter.Action[] memory leg) {
        bool xForZ = Currency.wrap(address(g.x)) < Currency.wrap(address(zchf));
        leg = new ActionRouter.Action[](2);
        leg[0] = _act(ActionRouter.Kind.PREFUND, abi.encode(Currency.wrap(address(g.x)), uint256(1000e18)));
        leg[1] = _act(
            ActionRouter.Kind.SWAP,
            abi.encode(
                g.lp,
                SwapParams(xForZ, -int256(1000e18), xForZ ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
                bytes("")
            )
        );
    }

    /// @dev Learns the intermediate ZCHF amount in a discarded snapshot.
    function _probeIntermediate(Agg memory g) internal returns (uint256 intermediate) {
        uint256 snap = vm.snapshotState();
        ActionRouter.Action[] memory leg = _lpLeg(g);
        ActionRouter.Action[] memory probe = new ActionRouter.Action[](3);
        probe[0] = leg[0];
        probe[1] = leg[1];
        probe[2] = _act(ActionRouter.Kind.TAKE_ALL, abi.encode(Currency.wrap(address(zchf)), alice));
        uint256 zBefore = zchf.balanceOf(alice);
        vm.prank(alice);
        g.ar.run(probe);
        intermediate = zchf.balanceOf(alice) - zBefore;
        assertTrue(vm.revertToStateAndDelete(snap));
        assertGt(intermediate, 900e18);
    }

    function test_aggregatorRouteFromLPPoolIntoPrimaryInOneUnlock() public {
        Agg memory g = _setupLPPool();
        g.intermediate = _probeIntermediate(g);
        g.expected = fcs.previewDeposit(g.intermediate);
        ActionRouter.Action[] memory leg = _lpLeg(g);
        ActionRouter.Action[] memory route = new ActionRouter.Action[](4);
        route[0] = leg[0];
        route[1] = leg[1];
        route[2] = _act(
            ActionRouter.Kind.SWAP_ALL_CREDIT,
            abi.encode(key, address(zchf) < address(fcs), abi.encode(g.expected, block.timestamp))
        );
        route[3] = _act(ActionRouter.Kind.TAKE_ALL, abi.encode(Currency.wrap(address(fcs)), alice));
        uint256 fBefore = fcs.balanceOf(alice);
        uint256 zBefore = zchf.balanceOf(alice);
        vm.recordLogs();
        vm.prank(alice);
        g.ar.run(route);
        assertEq(fcs.balanceOf(alice) - fBefore, g.expected, "primary leg output equals preview of intermediate");
        assertEq(zchf.balanceOf(alice), zBefore, "intermediate ZCHF never leaves the manager");
        assertEq(g.x.balanceOf(alice), 0);
        _assertAggregatorLogs(g);
        // The LP pool paid the intermediate ZCHF out of its reserves; the hook then physically took it.
        assertEq(zchf.balanceOf(address(manager)), g.lpZchf - g.intermediate);
        assertEq(fcs.balanceOf(address(manager)), 0);
        assertEq(zchf.balanceOf(address(hook)), 0);
        assertEq(fcs.balanceOf(address(hook)), 0);
    }

    function _assertAggregatorLogs(Agg memory g) internal {
        Vm.Log[] memory logs = _executionLogs(vm.getRecordedLogs(), address(hook));
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(g.ar)))));
        assertEq(logs[0].data, abi.encode(true, g.intermediate, g.expected));
    }

    function test_bundledRouterCannotBeNestedInsideAnotherUnlock() public {
        ActionRouter ar = _actionRouter();
        ActionRouter.Action[] memory a = new ActionRouter.Action[](1);
        a[0] = _act(
            ActionRouter.Kind.CALL,
            abi.encode(address(router), abi.encodeCall(router.swapExactInput, (true, 1e18, 1, alice, block.timestamp)))
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                ActionRouter.CallFailed.selector, abi.encodeWithSelector(IPoolManager.AlreadyUnlocked.selector)
            )
        );
        ar.run(a);
    }

    // ------------------------------------------------------- misc edge cases

    function test_routerConsumesExactlyAmountInOfAllowance() public {
        vm.startPrank(alice);
        zchf.approve(address(router), 1000e18);
        router.swapExactInput(true, 1000e18, 1, alice, block.timestamp);
        assertEq(zchf.allowance(alice, address(router)), 0);
        zchf.approve(address(router), 1000e18 - 1);
        vm.expectRevert();
        router.swapExactInput(true, 1000e18, 1, alice, block.timestamp);
        vm.stopPrank();
    }

    function test_deadlineBoundaryIsInclusive() public {
        vm.prank(alice);
        router.swapExactInput(true, 1000e18, 1, alice, block.timestamp);
        ActionRouter ar = _actionRouter();
        ActionRouter.Action[] memory a = new ActionRouter.Action[](3);
        a[0] = _act(ActionRouter.Kind.PREFUND, abi.encode(Currency.wrap(address(zchf)), uint256(1000e18)));
        a[1] = _act(
            ActionRouter.Kind.SWAP,
            abi.encode(key, _params(true, -int256(1000e18)), abi.encode(uint256(1), block.timestamp))
        );
        a[2] = _act(ActionRouter.Kind.TAKE_ALL, abi.encode(Currency.wrap(address(fcs)), alice));
        vm.prank(alice);
        ar.run(a);
    }

    function test_dustSellCannotBurnSharesForZeroProceeds() public {
        uint256 preview = fcs.previewRedeem(1);
        (uint256 q, bool available, FCSPrimaryHook.QuoteStatus status) = hook.quoteExactInput(false, 1);
        uint256 supply = fcs.totalSupply();
        if (preview == 0) {
            assertFalse(available);
            assertEq(uint256(status), uint256(FCSPrimaryHook.QuoteStatus.ZeroOutput));
            vm.prank(alice);
            vm.expectRevert(_hookRevert(address(hook), FCSPrimaryHook.InvalidOutput.selector));
            router.swapExactInput(false, 1, 1, alice, block.timestamp);
            assertEq(fcs.totalSupply(), supply, "no shares burned for zero proceeds");
        } else {
            assertTrue(available);
            vm.prank(alice);
            assertEq(router.swapExactInput(false, 1, q, alice, block.timestamp), preview);
        }
    }

    /// @dev Documents a known quote limitation (README): an un-bootstrapped system previews a
    /// bootstrap mint but Equity.invest rejects deposits below MINIMUM_EQUITY.
    function test_bootstrapQuoteAvailableButExecutionRejectedBelowMinimumEquity() public {
        Stack memory s = _buildStack(address(0), 0, true, 1 << 96);
        address user = address(0xB007);
        s.zchf.transfer(user, 10_000e18);
        vm.prank(user);
        s.zchf.approve(address(s.router), type(uint256).max);
        (uint256 q, bool available,) = s.hook.quoteExactInput(true, 500e18);
        assertTrue(available, "quote cannot see the MINIMUM_EQUITY gate");
        assertGt(q, 0);
        vm.prank(user);
        vm.expectRevert();
        s.router.swapExactInput(true, 500e18, q, user, block.timestamp);
        // At/above the bootstrap minimum the same route succeeds.
        uint256 q2 = s.fcs.previewDeposit(1000e18);
        vm.prank(user);
        assertEq(s.router.swapExactInput(true, 1000e18, q2, user, block.timestamp), q2);
    }

    function test_hookAndRouterHoldNoAllowancesExceptZchfToFcs() public view {
        assertEq(zchf.allowance(address(hook), address(fcs)), type(uint256).max);
        assertEq(fcs.allowance(address(hook), address(fcs)), 0);
        assertEq(zchf.allowance(address(hook), address(manager)), 0);
        assertEq(fcs.allowance(address(hook), address(manager)), 0);
        assertEq(zchf.allowance(address(router), address(manager)), 0);
        assertEq(fcs.allowance(address(router), address(manager)), 0);
        assertEq(zchf.allowance(address(router), address(hook)), 0);
    }
}

/// @dev Stateful handler: random users trade through the router while competing investors,
/// direct redeemers and FPS1 investors mutate the protocol state and time advances.
contract PrimaryHandler is CommonBase, StdCheats, StdUtils {
    Frankencoin zchf;
    Equity fps;
    FCS fcs;
    FCSPrimaryHook hook;
    FCSPrimaryRouter router;
    address[3] actors;

    uint256 public buys;
    uint256 public sells;
    uint256 public rejectedByQuote;
    uint256 public quoteMismatches;
    uint256 public directDeposits;
    uint256 public directRedeems;
    uint256 public fpsInvests;

    constructor(Frankencoin z, Equity p, FCS f, FCSPrimaryHook h, FCSPrimaryRouter r, address[3] memory a) {
        zchf = z;
        fps = p;
        fcs = f;
        hook = h;
        router = r;
        actors = a;
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(a[i]);
            zchf.approve(address(router), type(uint256).max);
            fcs.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
    }

    function buy(uint256 seed, uint256 raw) external {
        address actor = actors[seed % 3];
        uint256 amount = bound(raw, 1e12, 200_000e18);
        if (zchf.balanceOf(address(this)) < amount) return;
        zchf.transfer(actor, amount);
        (uint256 q, bool available,) = hook.quoteExactInput(true, amount);
        vm.prank(actor);
        if (!available) {
            rejectedByQuote++;
            vm.expectRevert();
            router.swapExactInput(true, amount, 1, actor, block.timestamp);
            return;
        }
        uint256 out = router.swapExactInput(true, amount, q, actor, block.timestamp);
        if (out != q) quoteMismatches++;
        buys++;
    }

    function sell(uint256 seed, uint256 raw) external {
        address actor = actors[seed % 3];
        uint256 balance = fcs.balanceOf(actor);
        if (balance == 0) return;
        uint256 amount = bound(raw, 1, balance);
        (uint256 q, bool available,) = hook.quoteExactInput(false, amount);
        vm.prank(actor);
        if (!available) {
            rejectedByQuote++;
            vm.expectRevert();
            router.swapExactInput(false, amount, 1, actor, block.timestamp);
            return;
        }
        uint256 out = router.swapExactInput(false, amount, q, actor, block.timestamp);
        if (out != q) quoteMismatches++;
        sells++;
    }

    function directDeposit(uint256 raw) external {
        uint256 amount = bound(raw, 1e15, 1_000_000e18);
        if (zchf.balanceOf(address(this)) < amount) return;
        zchf.approve(address(fcs), amount);
        fcs.deposit(amount, address(this));
        directDeposits++;
    }

    function directRedeem(uint256 raw) external {
        uint256 max = fcs.maxRedeem(address(this));
        if (max == 0) return;
        uint256 cap = fcs.totalSupply() / 20;
        uint256 amount = bound(raw, 1, max < cap ? max : cap);
        if (fcs.previewRedeem(amount) == 0) return;
        fcs.redeem(amount, address(this), address(this));
        directRedeems++;
    }

    function investFPSDirectly(uint256 raw) external {
        uint256 amount = bound(raw, 1e18, 3_000_000e18);
        if (zchf.balanceOf(address(this)) < amount) return;
        zchf.approve(address(fps), amount);
        fps.invest(amount, 0);
        fpsInvests++;
    }

    function warp(uint256 raw) external {
        vm.warp(block.timestamp + bound(raw, 1, 5 days));
    }
}

contract PrimaryHookInvariants is PrimaryHookTest {
    PrimaryHandler handler;
    address bob = address(0xB0B);
    address carol = address(0xCA201);

    function setUp() public override {
        super.setUp();
        handler = new PrimaryHandler(zchf, fps, fcs, hook, router, [alice, bob, carol]);
        zchf.transfer(address(handler), 60_000_000e18);
        fcs.transfer(address(handler), 500e18);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_adapterAndSingletonHoldNothing() public view {
        assertEq(zchf.balanceOf(address(hook)), 0);
        assertEq(fcs.balanceOf(address(hook)), 0);
        assertEq(zchf.balanceOf(address(router)), 0);
        assertEq(fcs.balanceOf(address(router)), 0);
        assertEq(zchf.balanceOf(address(manager)), 0);
        assertEq(fcs.balanceOf(address(manager)), 0);
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_fcsBackedOneToOneAndHoldsNoCash() public view {
        assertEq(fps.balanceOf(address(fcs)), fcs.totalSupply(), "FCS supply must equal wrapped FPS");
        assertEq(zchf.balanceOf(address(fcs)), 0, "FCS forwards all ZCHF");
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_supplyConservationAcrossKnownHolders() public view {
        uint256 sum = fcs.balanceOf(address(this)) + fcs.balanceOf(alice) + fcs.balanceOf(bob) + fcs.balanceOf(carol)
            + fcs.balanceOf(address(handler));
        assertEq(sum, fcs.totalSupply());
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_executionAlwaysEqualsImmediateQuote() public view {
        assertEq(handler.quoteMismatches(), 0);
        (uint256 q,,) = hook.quoteExactInput(true, 1000e18);
        assertEq(q, fcs.previewDeposit(1000e18));
    }
}
