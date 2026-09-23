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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";
import {SafePoolSwapTest} from "../shared/SafePoolSwapTest.sol";
import {LitePSMAggregator} from "../../../src/aggregator-hooks/implementations/LitePSM/LitePSMAggregator.sol";
import {ILitePSM} from "../../../src/aggregator-hooks/implementations/LitePSM/interfaces/ILitePSM.sol";

/// @title LitePSMAggregatorForkTest
/// @notice Fork tests against an Ethereum mainnet LitePSM (or LitePSMWrapper).
/// @dev Skipped when FORK_RPC_URL_1 is not set. The gem token is resolved dynamically
///      from the PSM, so the same test file works for any compliant LitePSM pair.
contract LitePSMAggregatorForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // ── Runtime-resolved addresses ────────────────────────────────────────────
    address LITE_PSM_WRAPPER;
    address GEM;
    address USDS;
    address POOL_MANAGER;

    uint24 constant POOL_FEE = 500;
    int24 constant TICK_SPACING = 10;
    uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    // Swap/fund amounts derived dynamically from gem decimals in setUp
    uint256 SWAP_GEM;
    uint256 SWAP_USDS;
    uint256 FUND_GEM;
    uint256 FUND_USDS;

    IPoolManager public manager;
    SafePoolSwapTest public swapRouter;
    LitePSMAggregator public hook;

    Currency public currency0;
    Currency public currency1;
    PoolKey public poolKey;
    PoolId public poolId;

    address public alice = makeAddr("alice");

    function setUp() public {
        string memory rpcUrl = vm.envOr("FORK_RPC_URL_1", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }
        LITE_PSM_WRAPPER = vm.envOr("LITE_PSM_WRAPPER", address(0));
        if (LITE_PSM_WRAPPER == address(0)) {
            vm.skip(true);
            return;
        }

        vm.createSelectFork(rpcUrl);

        GEM = ILitePSM(LITE_PSM_WRAPPER).gem();
        USDS = vm.envAddress("USDS");
        POOL_MANAGER = vm.envAddress("POOL_MANAGER_1");

        uint8 gemDecimals = IERC20Metadata(GEM).decimals();
        SWAP_GEM = 1_000 * (10 ** gemDecimals);
        SWAP_USDS = 1_000 * 1e18;
        FUND_GEM = 10_000_000 * (10 ** gemDecimals);
        FUND_USDS = 10_000_000 * 1e18;

        manager = IPoolManager(POOL_MANAGER);
        swapRouter = new SafePoolSwapTest(manager);

        currency0 = Currency.wrap(GEM);
        currency1 = Currency.wrap(USDS);
        if (currency0 > currency1) {
            (currency0, currency1) = (currency1, currency0);
        }

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

        // Fund alice and PoolManager using deal
        deal(GEM, alice, FUND_GEM);
        deal(USDS, alice, FUND_USDS);
        deal(GEM, address(manager), FUND_GEM);
        deal(USDS, address(manager), FUND_USDS);

        vm.startPrank(alice);
        IERC20(GEM).approve(address(swapRouter), type(uint256).max);
        IERC20(USDS).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _deployHook() internal {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );
        bytes memory constructorArgs = abi.encode(address(manager), LITE_PSM_WRAPPER, USDS);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(LitePSMAggregator).creationCode, constructorArgs);

        hook = new LitePSMAggregator{salt: salt}(manager, ILitePSM(LITE_PSM_WRAPPER), USDS);
        require(address(hook) == hookAddress, "Hook address mismatch");
    }

    modifier onlyFork() {
        if (bytes(vm.envOr("FORK_RPC_URL_1", string(""))).length == 0) return;
        _;
    }

    // ── Helper: direction flags ───────────────────────────────────────────────

    /// @dev Returns true when GEM is currency0 (sorted lower address).
    function _isGemCurrency0() internal view returns (bool) {
        return Currency.unwrap(currency0) == GEM;
    }

    // ── Fork tests ────────────────────────────────────────────────────────────

    function test_fork_psmInterfaceValid() public view onlyFork {
        ILitePSM psm = ILitePSM(LITE_PSM_WRAPPER);
        assertEq(psm.gem(), GEM, "gem() matches resolved GEM address");
        // to18ConversionFactor must be consistent with gem decimals
        uint8 gemDecimals = IERC20Metadata(GEM).decimals();
        uint256 expectedFactor = 10 ** (18 - gemDecimals);
        assertEq(psm.to18ConversionFactor(), expectedFactor, "to18 factor matches gem decimals");
        // tin/tout may be 0 or non-zero; just check they're readable
        psm.tin();
        psm.tout();
        psm.pocket();
    }

    function test_fork_exactIn_GemToUsds() public onlyFork {
        bool gemToUsds = _isGemCurrency0();
        uint256 quoted = hook.quote(gemToUsds, -int256(SWAP_GEM), poolId);
        assertGt(quoted, 0, "Quote > 0");
        // Current PSM has tin = 0, so ~1:1 decimal conversion
        assertGe(quoted, SWAP_USDS * 99 / 100, "Output >= 99% of 1:1");

        uint256 gemBefore = IERC20(GEM).balanceOf(alice);
        uint256 usdsBefore = IERC20(USDS).balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: gemToUsds,
                amountSpecified: -int256(SWAP_GEM),
                sqrtPriceLimitX96: gemToUsds ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(gemBefore - IERC20(GEM).balanceOf(alice), SWAP_GEM, "GEM spent");
        assertEq(IERC20(USDS).balanceOf(alice) - usdsBefore, quoted, "USDS received matches quote");
    }

    function test_fork_exactIn_UsdsToGem() public onlyFork {
        bool usdsToGem = !_isGemCurrency0();
        uint256 quoted = hook.quote(usdsToGem, -int256(SWAP_USDS), poolId);
        assertGt(quoted, 0, "Quote > 0");
        assertGe(quoted, SWAP_GEM * 99 / 100, "Output >= 99% of 1:1");

        uint256 usdsBefore = IERC20(USDS).balanceOf(alice);
        uint256 gemBefore = IERC20(GEM).balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: usdsToGem,
                amountSpecified: -int256(SWAP_USDS),
                sqrtPriceLimitX96: usdsToGem ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(usdsBefore - IERC20(USDS).balanceOf(alice), SWAP_USDS, "USDS spent");
        assertEq(IERC20(GEM).balanceOf(alice) - gemBefore, quoted, "GEM received matches quote");
    }

    function test_fork_exactOut_UsdsFromGem() public onlyFork {
        bool gemToUsds = _isGemCurrency0();
        uint256 quoted = hook.quote(gemToUsds, int256(SWAP_USDS), poolId);
        assertGt(quoted, 0, "Quote > 0");

        uint256 gemBefore = IERC20(GEM).balanceOf(alice);
        uint256 usdsBefore = IERC20(USDS).balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: gemToUsds,
                amountSpecified: int256(SWAP_USDS),
                sqrtPriceLimitX96: gemToUsds ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(IERC20(USDS).balanceOf(alice) - usdsBefore, SWAP_USDS, "Exact USDS received");
        assertLe(gemBefore - IERC20(GEM).balanceOf(alice), quoted, "GEM paid <= quote");
    }

    function test_fork_exactOut_GemFromUsds() public onlyFork {
        bool usdsToGem = !_isGemCurrency0();
        uint256 quoted = hook.quote(usdsToGem, int256(SWAP_GEM), poolId);
        assertGt(quoted, 0, "Quote > 0");

        uint256 usdsBefore = IERC20(USDS).balanceOf(alice);
        uint256 gemBefore = IERC20(GEM).balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: usdsToGem,
                amountSpecified: int256(SWAP_GEM),
                sqrtPriceLimitX96: usdsToGem ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(IERC20(GEM).balanceOf(alice) - gemBefore, SWAP_GEM, "Exact GEM received");
        assertLe(usdsBefore - IERC20(USDS).balanceOf(alice), quoted, "USDS paid <= quote");
    }

    function test_fork_pseudoTVL() public view onlyFork {
        (uint256 amount0, uint256 amount1) = hook.pseudoTotalValueLocked(poolId);
        // PSM should have significant liquidity on mainnet
        assertGt(amount0, 0, "TVL amount0 > 0");
        assertGt(amount1, 0, "TVL amount1 > 0");
    }

    receive() external payable {}
}
