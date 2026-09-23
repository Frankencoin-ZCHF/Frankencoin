// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ALFMultiplexer} from "../../src/alf/ALFMultiplexer.sol";
import {NativeBookHook} from "../../src/alf/NativeBookHook.sol";
import {MultiplexerHookData, TargetedQuoter} from "../../src/alf/types/MultiplexerTypes.sol";
import {PoolConfig} from "../../src/alf/types/BookConfig.sol";
import {BinCapacity} from "../../src/alf/types/Ladder.sol";

/// @notice Integration coverage for NativeBook hooks behind the ALFMultiplexer: Tier-1
///         discovery via IALFHook, autonomous and pre-planned execution parity against the
///         quoter's virtual-retirement simulation, dynamic-fee resolution, and the
///         fill-completely-or-revert bound when a swap exceeds the book's deployable capacity.
contract ALFMultiplexerNativeBookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    ALFMultiplexer public multiplexer;
    NativeBookHook public nativeBookA;
    NativeBookHook public nativeBookB;

    MockERC20 token0;
    MockERC20 token1;

    address makerB = makeAddr("makerB");

    PoolKey multiplexerPoolKey;
    PoolKey nativeBookAPoolKey;
    PoolKey nativeBookBPoolKey;
    PoolId nativeBookBPoolId;

    uint24 constant FEE_A = 3_000;
    uint24 constant FEE_B = 1_000;
    int24 constant TICK_SPACING = 10;
    int24 constant BIN_SPACING = 60;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        uint160 multiplexerFlags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_DONATE_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        multiplexer = ALFMultiplexer(
            address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | multiplexerFlags))
        );
        deployCodeTo("ALFMultiplexer", abi.encode(manager), address(multiplexer));

        uint160 nativeBookFlags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG
        );
        nativeBookA = NativeBookHook(
            address(uint160((uint256(type(uint160).max) - (1 << 15)) & clearAllHookPermissionsMask | nativeBookFlags))
        );
        deployCodeTo("NativeBookHook", abi.encode(manager, uint32(5_000_000), address(this)), address(nativeBookA));

        nativeBookB = NativeBookHook(
            address(uint160((uint256(type(uint160).max) - (2 << 15)) & clearAllHookPermissionsMask | nativeBookFlags))
        );
        deployCodeTo("NativeBookHook", abi.encode(manager, uint32(5_000_000), address(this)), address(nativeBookB));

        nativeBookAPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: FEE_A,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(nativeBookA))
        });
        nativeBookBPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: FEE_B,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(nativeBookB))
        });
        nativeBookBPoolId = nativeBookBPoolKey.toId();

        multiplexerPoolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 1, hooks: IHooks(address(multiplexer))
        });

        nativeBookA.initializePool(nativeBookAPoolKey, TickMath.getSqrtPriceAtTick(0), _defaultConfig());
        nativeBookB.initializePool(nativeBookBPoolKey, TickMath.getSqrtPriceAtTick(0), _defaultConfig());
        manager.initialize(multiplexerPoolKey, Constants.SQRT_PRICE_1_1);

        _seedPassiveLiquidity(nativeBookAPoolKey, bytes32(uint256(1)));
        _seedPassiveLiquidity(nativeBookBPoolKey, bytes32(uint256(2)));
        _fundAndApproveMaker(nativeBookB, makerB);
    }

    function test_autonomousNativeBookQuoteMatchesExecutionAcrossDirectionsAndModes() public {
        bytes memory hookData = _buildTargets(nativeBookAPoolKey, nativeBookBPoolKey, 0);

        _assertMultiplexerQuoteMatchesExecution(hookData, true, -1 ether, address(nativeBookB));
        _assertMultiplexerQuoteMatchesExecution(hookData, false, -1 ether, address(nativeBookB));
        _assertMultiplexerQuoteMatchesExecution(hookData, true, 1 ether, address(nativeBookB));
        _assertMultiplexerQuoteMatchesExecution(hookData, false, 1 ether, address(nativeBookB));
    }

    function test_prePlannedNativeBookExactInputAndExactOutputExecute() public {
        _assertPreplannedMatchesNativeBook(nativeBookBPoolKey, true, -1 ether);
        _assertPreplannedMatchesNativeBook(nativeBookBPoolKey, false, -1 ether);
        _assertPreplannedMatchesNativeBook(nativeBookBPoolKey, true, 1 ether);
        _assertPreplannedMatchesNativeBook(nativeBookBPoolKey, false, 1 ether);
    }

    function test_strictTolerancePassesForNativeBookAutonomousAndPreplanned() public {
        _assertMultiplexerQuoteMatchesExecution(
            _buildTargets(nativeBookAPoolKey, nativeBookBPoolKey, 1), true, -1 ether, address(nativeBookB)
        );
        _assertPreplannedMatchesNativeBook(nativeBookBPoolKey, true, -1 ether, 1);
    }

    function test_uninitializedNativeBookPoolIsSkippedByMultiplexer() public {
        PoolKey memory uninitializedPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 500,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(nativeBookB))
        });

        bytes memory hookData = _buildTargets(nativeBookAPoolKey, uninitializedPoolKey, 0);
        (, address winner,,) = multiplexer.quote(true, -1 ether, hookData);
        assertEq(winner, address(nativeBookA));

        BalanceDelta delta = swap(multiplexerPoolKey, true, -1 ether, hookData);
        assertEq(delta.amount0(), -1 ether);
        assertGt(delta.amount1(), 0);
    }

    /// @dev The expired ask holds nearly all ask-side depth. Both the quote's virtual
    ///      retirement and execution's `beforeSwap` scan must drop it, so the quote prices
    ///      against passive liquidity only and matches execution exactly, and the swap leaves
    ///      the maker's book empty.
    function test_staleNativeBookRetirementMatchesMultiplexerExecution() public {
        _postExpiredAsk();

        uint256 quote = nativeBookB.getIndicativeQuote(nativeBookBPoolKey, false, -1 ether, "");
        assertGt(quote, 0);
        assertEq(nativeBookB.makerPositionCount(nativeBookBPoolId, makerB), 1);

        BalanceDelta delta = swap(multiplexerPoolKey, false, -1 ether, _buildTarget(nativeBookBPoolKey, 0, 0));
        assertApproxEqAbs(uint256(int256(delta.amount0())), quote, 1);
        assertEq(nativeBookB.makerPositionCount(nativeBookBPoolId, makerB), 0);
    }

    /// @dev Fill-completely-or-revert: once the expired ask is retired, a swap larger than the
    ///      remaining passive depth cannot be fully consumed by the target set, and the
    ///      multiplexer must revert rather than leak the residual onto its zero-liquidity
    ///      virtual pool. The hook's indicative for the oversized amount is a partial-capacity
    ///      figure, which is valid input for waterfall sorting but not a full-fill promise.
    function test_swapExceedingBookCapacityRevertsInsufficientLiquidity() public {
        _postExpiredAsk();

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(multiplexer),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(ALFMultiplexer.InsufficientLiquidity.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(multiplexerPoolKey, false, -110 ether, _buildTarget(nativeBookBPoolKey, 0, 0));
    }

    function test_dynamicFeeNativeBookQuoteMatchesMultiplexerExecution() public {
        PoolKey memory dynamicPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(nativeBookB))
        });

        nativeBookB.initializePool(dynamicPoolKey, TickMath.getSqrtPriceAtTick(0), _defaultConfig());
        _seedPassiveLiquidity(dynamicPoolKey, bytes32(uint256(33)));

        _assertMultiplexerQuoteMatchesExecution(
            _buildTarget(dynamicPoolKey, 0, 0), true, -1 ether, address(nativeBookB)
        );
        _assertMultiplexerQuoteMatchesExecution(
            _buildTarget(dynamicPoolKey, 0, 0), false, 1 ether, address(nativeBookB)
        );
    }

    function _postExpiredAsk() internal {
        BinCapacity[] memory bids = new BinCapacity[](0);
        BinCapacity[] memory asks = new BinCapacity[](1);
        asks[0] = BinCapacity({offset: 1, amount: 100 ether});

        vm.prank(makerB);
        nativeBookB.replaceLadder(nativeBookBPoolKey, bids, asks, 1, 0, 0);
        vm.warp(block.timestamp + 2);
    }

    function _assertMultiplexerQuoteMatchesExecution(
        bytes memory hookData,
        bool zeroForOne,
        int256 amountSpecified,
        address expectedWinner
    ) internal {
        uint256 snapshot = vm.snapshotState();

        (, address winner, uint256 bestQuote,) = multiplexer.quote(zeroForOne, amountSpecified, hookData);
        assertEq(winner, expectedWinner);
        assertGt(bestQuote, 0);

        BalanceDelta delta = swap(multiplexerPoolKey, zeroForOne, amountSpecified, hookData);
        assertApproxEqAbs(_comparisonAmount(delta, zeroForOne, amountSpecified), bestQuote, 2);

        vm.revertToState(snapshot);
    }

    function _assertPreplannedMatchesNativeBook(PoolKey memory key, bool zeroForOne, int256 amountSpecified) internal {
        _assertPreplannedMatchesNativeBook(key, zeroForOne, amountSpecified, 0);
    }

    function _assertPreplannedMatchesNativeBook(
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified,
        uint24 strictTolerancePips
    ) internal {
        uint256 snapshot = vm.snapshotState();

        uint256 nativeBookQuote =
            NativeBookHook(address(key.hooks)).getIndicativeQuote(key, zeroForOne, amountSpecified, "");
        assertGt(nativeBookQuote, 0);

        BalanceDelta delta = swap(
            multiplexerPoolKey, zeroForOne, amountSpecified, _buildTarget(key, amountSpecified, strictTolerancePips)
        );
        assertApproxEqAbs(_comparisonAmount(delta, zeroForOne, amountSpecified), nativeBookQuote, 2);

        vm.revertToState(snapshot);
    }

    function _comparisonAmount(BalanceDelta delta, bool zeroForOne, int256 amountSpecified)
        internal
        pure
        returns (uint256)
    {
        if (amountSpecified < 0) {
            return zeroForOne ? uint256(int256(delta.amount1())) : uint256(int256(delta.amount0()));
        }
        return zeroForOne ? uint256(-int256(delta.amount0())) : uint256(-int256(delta.amount1()));
    }

    function _buildTargets(PoolKey memory a, PoolKey memory b, uint24 strictTolerancePips)
        internal
        pure
        returns (bytes memory)
    {
        TargetedQuoter[] memory targets = new TargetedQuoter[](2);
        targets[0] = TargetedQuoter({poolKey: a, amountSpecified: 0});
        targets[1] = TargetedQuoter({poolKey: b, amountSpecified: 0});
        return abi.encode(
            MultiplexerHookData({attestationData: "", targets: targets, strictTolerancePips: strictTolerancePips})
        );
    }

    function _buildTarget(PoolKey memory key, int256 amountSpecified, uint24 strictTolerancePips)
        internal
        pure
        returns (bytes memory)
    {
        TargetedQuoter[] memory targets = new TargetedQuoter[](1);
        targets[0] = TargetedQuoter({poolKey: key, amountSpecified: amountSpecified});
        return abi.encode(
            MultiplexerHookData({attestationData: "", targets: targets, strictTolerancePips: strictTolerancePips})
        );
    }

    function _seedPassiveLiquidity(PoolKey memory key, bytes32 salt) internal {
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -10 * BIN_SPACING, tickUpper: 10 * BIN_SPACING, liquidityDelta: 100 ether, salt: salt
            }),
            ""
        );
    }

    function _fundAndApproveMaker(NativeBookHook hook, address account) internal {
        token0.transfer(account, 1_000_000 ether);
        token1.transfer(account, 1_000_000 ether);
        vm.startPrank(account);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        hook.deposit(currency0, 500_000 ether);
        hook.deposit(currency1, 500_000 ether);
        vm.stopPrank();
    }

    function _defaultConfig() internal pure returns (PoolConfig memory) {
        return PoolConfig({
            binSpacingTicks: BIN_SPACING,
            binsPerSide: 4,
            maxMakerBins: 8,
            maxRetirePerSwap: 4,
            maxQuoteTtl: 1 days,
            minBinLiquidity: 1
        });
    }
}
