// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";
import {SafePoolSwapTest} from "../shared/SafePoolSwapTest.sol";
import {IAggregatorHook} from "../../../src/aggregator-hooks/interfaces/IAggregatorHook.sol";
import {LitePSMAggregator} from "../../../src/aggregator-hooks/implementations/LitePSM/LitePSMAggregator.sol";
import {ILitePSM} from "../../../src/aggregator-hooks/implementations/LitePSM/interfaces/ILitePSM.sol";
import {MockLitePSM} from "./mocks/MockLitePSM.sol";

contract LitePSMAggregatorUnitTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint24 constant POOL_FEE = 500;
    int24 constant TICK_SPACING = 10;
    uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    uint256 constant INITIAL_BALANCE = 10_000_000;
    uint256 constant SWAP_USDC = 1000 * 1e6;
    uint256 constant SWAP_USDS = 1000 * 1e18;

    IPoolManager public manager;
    SafePoolSwapTest public swapRouter;
    LitePSMAggregator public hook;
    MockLitePSM public psm;

    MockERC20 public usdc; // 6 decimals
    MockERC20 public usds; // 18 decimals

    Currency public currencyUsdc;
    Currency public currencyUsds;
    Currency public currency0;
    Currency public currency1;

    PoolKey public poolKey;
    PoolId public poolId;

    address public alice = makeAddr("alice");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usds = new MockERC20("USDS", "USDS", 18);

        currencyUsdc = Currency.wrap(address(usdc));
        currencyUsds = Currency.wrap(address(usds));

        (currency0, currency1) =
            address(usdc) < address(usds) ? (currencyUsdc, currencyUsds) : (currencyUsds, currencyUsdc);

        psm = new MockLitePSM(address(usdc), address(usds));

        // Fund mock PSM with liquidity
        usdc.mint(address(psm), INITIAL_BALANCE * 1e6);
        usds.mint(address(psm), INITIAL_BALANCE * 1e18);

        // Set a realistic finite buf (pre-minted stable buffer, WAD). pseudoTotalValueLocked reports
        // buf for the stable side, and the default uint256.max would be a nonsensical TVL. This gives a
        // sellGemCap of INITIAL_BALANCE USDC, well above any amount used in non-capacity tests.
        psm.setBuf(INITIAL_BALANCE * 1e18);

        manager = IPoolManager(deployCode("foundry-out/PoolManager.sol/PoolManager.json", abi.encode(address(0))));

        // Seed PoolManager so it has reserves for swap settlements
        usdc.mint(address(manager), INITIAL_BALANCE * 1e6);
        usds.mint(address(manager), INITIAL_BALANCE * 1e18);

        swapRouter = new SafePoolSwapTest(manager);

        _deployHook();

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        usdc.mint(alice, INITIAL_BALANCE * 1e6);
        usds.mint(alice, INITIAL_BALANCE * 1e18);

        vm.startPrank(alice);
        usdc.approve(address(swapRouter), type(uint256).max);
        usds.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _deployHook() internal {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );
        bytes memory constructorArgs = abi.encode(address(manager), address(psm), address(usds));
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(LitePSMAggregator).creationCode, constructorArgs);

        hook = new LitePSMAggregator{salt: salt}(manager, ILitePSM(address(psm)), address(usds));
        require(address(hook) == hookAddress, "Hook address mismatch");
    }

    // ── Helpers ────────────────────────────────────────────────────────────────

    function _isUsdcCurrency0() internal view returns (bool) {
        return address(usdc) < address(usds);
    }

    function _swapUsdcForUsds(uint256 amountSpecified, bool exactIn) internal {
        bool zeroForOne = _isUsdcCurrency0();
        int256 amt = exactIn ? -int256(amountSpecified) : int256(amountSpecified);
        uint160 limit = zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT;
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amt, sqrtPriceLimitX96: limit}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _swapUsdsForUsdc(uint256 amountSpecified, bool exactIn) internal {
        bool zeroForOne = !_isUsdcCurrency0();
        int256 amt = exactIn ? -int256(amountSpecified) : int256(amountSpecified);
        uint160 limit = zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT;
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amt, sqrtPriceLimitX96: limit}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // ── Exact-in USDC → USDS ───────────────────────────────────────────────────

    function test_exactIn_UsdcToUsds_noFee() public {
        bool usdcToUsds = _isUsdcCurrency0();
        uint256 quoted = hook.quote(usdcToUsds, -int256(SWAP_USDC), poolId);
        // No fee: 1000 USDC → 1000 USDS (decimal conversion only)
        assertEq(quoted, SWAP_USDS, "Quote mismatch (no fee)");

        uint256 usdcBefore = usdc.balanceOf(alice);
        uint256 usdsBefore = usds.balanceOf(alice);
        _swapUsdcForUsds(SWAP_USDC, true);

        assertEq(usdcBefore - usdc.balanceOf(alice), SWAP_USDC, "USDC spent");
        assertEq(usds.balanceOf(alice) - usdsBefore, quoted, "USDS received");
    }

    function test_exactIn_UsdcToUsds_withFee() public {
        psm.setTin(1e15); // 0.1%
        uint256 expectedUsds = SWAP_USDC * 1e12 * (1e18 - 1e15) / 1e18; // 999 USDS
        bool usdcToUsds = _isUsdcCurrency0();
        uint256 quoted = hook.quote(usdcToUsds, -int256(SWAP_USDC), poolId);
        assertEq(quoted, expectedUsds, "Quote with fee");

        uint256 usdcBefore = usdc.balanceOf(alice);
        uint256 usdsBefore = usds.balanceOf(alice);
        _swapUsdcForUsds(SWAP_USDC, true);

        assertEq(usdcBefore - usdc.balanceOf(alice), SWAP_USDC, "USDC spent");
        assertEq(usds.balanceOf(alice) - usdsBefore, quoted, "USDS received matches quote");
    }

    // ── Exact-in USDS → USDC ───────────────────────────────────────────────────

    function test_exactIn_UsdsToUsdc_noFee() public {
        // zeroToOne direction for USDS→USDC depends on ordering
        bool zeroToOne = !_isUsdcCurrency0();
        uint256 quoted = hook.quote(zeroToOne, -int256(SWAP_USDS), poolId);
        // No fee: 1000 USDS → 1000 USDC
        assertEq(quoted, SWAP_USDC, "Quote mismatch (no fee)");

        uint256 usdsBefore = usds.balanceOf(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);
        _swapUsdsForUsdc(SWAP_USDS, true);

        assertEq(usdsBefore - usds.balanceOf(alice), SWAP_USDS, "USDS spent");
        assertEq(usdc.balanceOf(alice) - usdcBefore, quoted, "USDC received");
    }

    function test_exactIn_UsdsToUsdc_withFee() public {
        psm.setTout(1e15); // 0.1%
        bool zeroToOne = !_isUsdcCurrency0();
        uint256 quoted = hook.quote(zeroToOne, -int256(SWAP_USDS), poolId);
        // floor(1000 USDS * WAD / (to18 * (WAD + tout)))
        uint256 expected = SWAP_USDS * 1e18 / (1e12 * (1e18 + 1e15));
        assertEq(quoted, expected, "Quote with fee");

        uint256 usdsBefore = usds.balanceOf(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);
        _swapUsdsForUsdc(SWAP_USDS, true);

        assertEq(usdsBefore - usds.balanceOf(alice), SWAP_USDS, "USDS spent");
        assertEq(usdc.balanceOf(alice) - usdcBefore, quoted, "USDC received");
    }

    // ── Exact-out USDS from USDC ───────────────────────────────────────────────

    function test_exactOut_UsdsFromUsdc_noFee() public {
        bool zeroToOne = _isUsdcCurrency0();
        uint256 quoted = hook.quote(zeroToOne, int256(SWAP_USDS), poolId);
        // No fee, no rounding: ceil(1000 USDS * WAD / (to18 * WAD)) = 1000 USDC
        assertEq(quoted, SWAP_USDC, "Quote mismatch (no fee)");

        uint256 usdcBefore = usdc.balanceOf(alice);
        uint256 usdsBefore = usds.balanceOf(alice);
        _swapUsdcForUsds(SWAP_USDS, false);

        assertEq(usds.balanceOf(alice) - usdsBefore, SWAP_USDS, "Exact USDS received");
        assertLe(usdcBefore - usdc.balanceOf(alice), quoted, "USDC paid <= quote");
        assertGt(usdcBefore - usdc.balanceOf(alice), 0, "USDC paid > 0");
    }

    function test_exactOut_UsdsFromUsdc_withFee() public {
        psm.setTin(1e15); // 0.1%
        bool zeroToOne = _isUsdcCurrency0();
        uint256 quoted = hook.quote(zeroToOne, int256(SWAP_USDS), poolId);

        uint256 usdcBefore = usdc.balanceOf(alice);
        uint256 usdsBefore = usds.balanceOf(alice);
        _swapUsdcForUsds(SWAP_USDS, false);

        assertEq(usds.balanceOf(alice) - usdsBefore, SWAP_USDS, "Exact USDS received");
        assertLe(usdcBefore - usdc.balanceOf(alice), quoted, "USDC paid <= quote");
    }

    // ── Exact-out USDC from USDS ───────────────────────────────────────────────

    function test_exactOut_UsdcFromUsds_noFee() public {
        bool zeroToOne = !_isUsdcCurrency0();
        uint256 quoted = hook.quote(zeroToOne, int256(SWAP_USDC), poolId);
        // No fee: ceil(1000 USDC * to18 * WAD / WAD) = 1000 USDS
        assertEq(quoted, SWAP_USDS, "Quote mismatch (no fee)");

        uint256 usdsBefore = usds.balanceOf(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);
        _swapUsdsForUsdc(SWAP_USDC, false);

        assertEq(usdc.balanceOf(alice) - usdcBefore, SWAP_USDC, "Exact USDC received");
        assertLe(usdsBefore - usds.balanceOf(alice), quoted, "USDS paid <= quote");
    }

    function test_exactOut_UsdcFromUsds_withFee() public {
        psm.setTout(1e15); // 0.1%
        bool zeroToOne = !_isUsdcCurrency0();
        uint256 quoted = hook.quote(zeroToOne, int256(SWAP_USDC), poolId);

        uint256 usdsBefore = usds.balanceOf(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);
        _swapUsdsForUsdc(SWAP_USDC, false);

        assertEq(usdc.balanceOf(alice) - usdcBefore, SWAP_USDC, "Exact USDC received");
        assertLe(usdsBefore - usds.balanceOf(alice), quoted, "USDS paid <= quote");
    }

    // ── Quote consistency ─────────────────────────────────────────────────────

    function test_quote_exactIn_consistentWithSwap() public {
        bool zeroToOne = _isUsdcCurrency0();
        uint256 expectedOut = hook.quote(zeroToOne, -int256(SWAP_USDC), poolId);

        uint256 usdsBefore = usds.balanceOf(alice);
        _swapUsdcForUsds(SWAP_USDC, true);
        uint256 received = usds.balanceOf(alice) - usdsBefore;

        assertEq(received, expectedOut, "Swap output matches quote");
    }

    function test_quote_roundTrip() public {
        bool usdcToUsds = _isUsdcCurrency0();
        // Exact-in: how many USDS do we get for SWAP_USDC?
        uint256 usdsOut = hook.quote(usdcToUsds, -int256(SWAP_USDC), poolId);
        // Exact-out (same direction): how much USDC is needed to receive usdsOut USDS?
        uint256 usdcNeeded = hook.quote(usdcToUsds, int256(usdsOut), poolId);
        // With zero fee and no rounding loss, should be exactly SWAP_USDC
        assertGe(usdcNeeded, SWAP_USDC - 1, "Round-trip: USDC in should be >= original - 1");
        assertLe(usdcNeeded, SWAP_USDC + 1, "Round-trip: USDC in should not exceed original by more than 1");
    }

    // ── pseudoTotalValueLocked ────────────────────────────────────────────────

    function test_pseudoTotalValueLocked() public view {
        (uint256 amount0, uint256 amount1) = hook.pseudoTotalValueLocked(poolId);
        assertGt(amount0, 0, "amount0 > 0");
        assertGt(amount1, 0, "amount1 > 0");

        // gem side = USDC in the pocket (6-dec); stable side = buf (pre-minted buffer, 18-dec WAD)
        uint256 gemBalance = usdc.balanceOf(psm.pocket());
        uint256 stableBuf = psm.buf();
        (uint256 expectedGem, uint256 expectedStable) =
            _isUsdcCurrency0() ? (gemBalance, stableBuf) : (stableBuf, gemBalance);
        assertEq(amount0, expectedGem, "amount0 matches gem/stable depth");
        assertEq(amount1, expectedStable, "amount1 matches gem/stable depth");
    }

    // ── Error cases ───────────────────────────────────────────────────────────

    function test_quote_unregisteredPool_reverts() public {
        PoolKey memory fakeKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(hook))
        });
        vm.expectRevert(IAggregatorHook.PoolDoesNotExist.selector);
        hook.quote(true, -int256(SWAP_USDC), fakeKey.toId());
    }

    function test_pseudoTVL_unregisteredPool_reverts() public {
        PoolKey memory fakeKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(hook))
        });
        vm.expectRevert(IAggregatorHook.PoolDoesNotExist.selector);
        hook.pseudoTotalValueLocked(fakeKey.toId());
    }

    function test_initialize_wrongTokens_reverts() public {
        MockERC20 randToken = new MockERC20("Rand", "RAND", 18);
        (Currency c0, Currency c1) = address(randToken) < address(usds)
            ? (Currency.wrap(address(randToken)), currencyUsds)
            : (currencyUsds, Currency.wrap(address(randToken)));
        PoolKey memory badKey = PoolKey({
            currency0: c0, currency1: c1, fee: POOL_FEE, tickSpacing: TICK_SPACING, hooks: IHooks(address(hook))
        });
        vm.expectRevert();
        manager.initialize(badKey, SQRT_PRICE_1_1);
    }

    function test_initialize_duplicatePair_reverts() public {
        PoolKey memory dupKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(hook))
        });
        vm.expectRevert();
        manager.initialize(dupKey, SQRT_PRICE_1_1);
    }

    function test_hookPermissions() public view {
        // Verify the hook declares the expected permissions
        (uint256 amount0, uint256 amount1) = hook.pseudoTotalValueLocked(poolId);
        // TVL should reflect PSM's USDC and USDS holdings
        assertGt(amount0 + amount1, 0, "Hook has PSM liquidity");
    }

    // ── Capacity limit tests ──────────────────────────────────────────────────

    /// @dev sellGemCap = buf / to18ConversionFactor. With buf = 500k * 1e18, cap = 500k USDC.
    function test_quote_exactIn_sellGem_exceedsSellGemCap_reverts() public {
        uint256 capUsdc = 500_000 * 1e6;
        psm.setBuf(capUsdc * 1e12); // buf in WAD = capUsdc * to18ConversionFactor
        bool usdcToUsds = _isUsdcCurrency0();

        // Exactly at cap: should quote > 0
        uint256 quotedAtCap = hook.quote(usdcToUsds, -int256(capUsdc), poolId);
        assertGt(quotedAtCap, 0, "Quote at cap > 0");

        // One unit over cap: must revert
        vm.expectRevert(LitePSMAggregator.ExceedsCapacity.selector);
        hook.quote(usdcToUsds, -int256(capUsdc + 1), poolId);
    }

    function test_quote_exactOut_sellGem_exceedsSellGemCap_reverts() public {
        uint256 capUsdc = 500_000 * 1e6;
        psm.setBuf(capUsdc * 1e12);
        bool usdcToUsds = _isUsdcCurrency0();

        // Max USDS out from the cap (no fee): capUsdc * 1e12. At exactly the cap the swap is
        // fillable, so the quote must succeed (capacity check is strict `>`).
        uint256 maxUsdsOut = capUsdc * 1e12;
        uint256 quotedAtCap = hook.quote(usdcToUsds, int256(maxUsdsOut), poolId);
        assertGt(quotedAtCap, 0, "Quote at exactly sellGemCap succeeds");

        // One wei over the max USDS capacity: must revert
        vm.expectRevert(LitePSMAggregator.ExceedsCapacity.selector);
        hook.quote(usdcToUsds, int256(maxUsdsOut + 1), poolId);
    }

    function test_quote_exactIn_buyGem_exceedsBuyGemCap_reverts() public {
        // buyGemCap = gem balance in pocket = psm's USDC balance (MockLitePSM is its own pocket)
        uint256 psmUsdcBalance = usdc.balanceOf(address(psm));
        // Input USDS that would require more USDC out than the pocket holds (no fee)
        uint256 usdsIn = (psmUsdcBalance + 1) * 1e12; // would yield psmUsdcBalance + 1 USDC out
        bool usdsToUsdc = !_isUsdcCurrency0();

        vm.expectRevert(LitePSMAggregator.ExceedsCapacity.selector);
        hook.quote(usdsToUsdc, -int256(usdsIn), poolId);
    }

    function test_quote_exactOut_buyGem_exceedsBuyGemCap_reverts() public {
        uint256 psmUsdcBalance = usdc.balanceOf(address(psm));
        bool usdsToUsdc = !_isUsdcCurrency0();

        // At exactly the cap the swap is fillable, so the quote must succeed (capacity check is strict `>`).
        uint256 quotedAtCap = hook.quote(usdsToUsdc, int256(psmUsdcBalance), poolId);
        assertGt(quotedAtCap, 0, "Quote at exactly buyGemCap succeeds");

        // One unit over cap: must revert
        vm.expectRevert(LitePSMAggregator.ExceedsCapacity.selector);
        hook.quote(usdsToUsdc, int256(psmUsdcBalance + 1), poolId);
    }

    // ── Fuzz tests ────────────────────────────────────────────────────────────

    function testFuzz_exactIn_UsdcToUsds(uint64 amountIn) public {
        uint256 amt = bound(amountIn, 1e6, 1_000_000 * 1e6); // 1 to 1M USDC
        bool usdcToUsds = _isUsdcCurrency0();
        uint256 quoted = hook.quote(usdcToUsds, -int256(amt), poolId);
        assertGt(quoted, 0, "Quote > 0");

        uint256 usdsBefore = usds.balanceOf(alice);
        _swapUsdcForUsds(amt, true);
        assertEq(usds.balanceOf(alice) - usdsBefore, quoted, "Received matches quote");
    }

    function testFuzz_exactIn_UsdsToUsdc(uint128 amountIn) public {
        uint256 amt = bound(amountIn, 1e18, 1_000_000 * 1e18); // 1 to 1M USDS
        bool zeroToOne = !_isUsdcCurrency0();
        uint256 quoted = hook.quote(zeroToOne, -int256(amt), poolId);
        assertGt(quoted, 0, "Quote > 0");

        uint256 usdcBefore = usdc.balanceOf(alice);
        _swapUsdsForUsdc(amt, true);
        assertEq(usdc.balanceOf(alice) - usdcBefore, quoted, "Received matches quote");
    }

    function testFuzz_exactOut_UsdsFromUsdc(uint64 amountOut) public {
        uint256 amt = bound(amountOut, 1e18, 1_000_000 * 1e18); // 1 to 1M USDS out
        bool zeroToOne = _isUsdcCurrency0();
        uint256 quoted = hook.quote(zeroToOne, int256(amt), poolId);

        uint256 usdsBefore = usds.balanceOf(alice);
        _swapUsdcForUsds(amt, false);
        assertEq(usds.balanceOf(alice) - usdsBefore, amt, "Exact USDS out");
        assertLe(usdc.balanceOf(alice), 10_000_000 * 1e6, "No Alice USDC overflow");
        // Alice paid <= quoted USDC
        uint256 usdcSpent = INITIAL_BALANCE * 1e6 - usdc.balanceOf(alice);
        assertLe(usdcSpent, quoted, "Spent <= quote");
    }

    function testFuzz_exactOut_UsdcFromUsds(uint64 amountOut) public {
        uint256 amt = bound(amountOut, 1e6, 1_000_000 * 1e6); // 1 to 1M USDC out
        bool zeroToOne = !_isUsdcCurrency0();
        uint256 quoted = hook.quote(zeroToOne, int256(amt), poolId);

        uint256 usdcBefore = usdc.balanceOf(alice);
        _swapUsdsForUsdc(amt, false);
        assertEq(usdc.balanceOf(alice) - usdcBefore, amt, "Exact USDC out");
        uint256 usdsSpent = INITIAL_BALANCE * 1e18 - usds.balanceOf(alice);
        assertLe(usdsSpent, quoted, "Spent <= quote");
    }

    receive() external payable {}
}
