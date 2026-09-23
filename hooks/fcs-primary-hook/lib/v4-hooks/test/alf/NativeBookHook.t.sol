// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {NativeBookHook} from "../../src/alf/NativeBookHook.sol";
import {IALFHook} from "../../src/alf/interfaces/IALFHook.sol";
import {OwnedALFHook} from "../../src/alf/base/OwnedALFHook.sol";
import {BinMath} from "../../src/alf/libraries/BinMath.sol";
import {BookConfig, PoolConfig, InvalidPoolConfig} from "../../src/alf/types/BookConfig.sol";
import {InsufficientInventory} from "../../src/alf/types/MakerInventory.sol";
import {PositionInfo, Side} from "../../src/alf/types/BookPositions.sol";
import {BinCapacity, InvalidBinOffset, DuplicateBinOffset} from "../../src/alf/types/Ladder.sol";
import {PoolNotLive, PoolLivenessUpdated} from "../../src/alf/types/Liveness.sol";

contract NativeBookHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    NativeBookHook public hook;
    MockERC20 token0;
    MockERC20 token1;

    address owner = makeAddr("owner");
    address maker;
    address maker2;
    address relayer = makeAddr("relayer");
    uint256 makerPk;
    uint256 maker2Pk;

    PoolKey testPoolKey;
    PoolId testPoolId;

    uint24 constant FEE_PIPS = 1_000;
    int24 constant TICK_SPACING = 10;
    int24 constant BIN_SPACING = 60;

    event InventoryDeposited(
        address indexed maker,
        address indexed currency,
        address indexed depositor,
        uint256 requestedAmount,
        uint256 amount
    );
    event InventoryWithdrawn(
        address indexed maker, address indexed currency, address indexed recipient, uint256 amount
    );
    event LadderReplaced(
        PoolId indexed poolId,
        address indexed maker,
        address indexed submitter,
        uint256 bidCount,
        uint256 askCount,
        uint40 expiry,
        uint256 nonce,
        uint256 deadline,
        bool viaSignature
    );
    event LadderCanceled(
        PoolId indexed poolId,
        address indexed maker,
        address indexed submitter,
        uint256 binsRemoved,
        uint256 amount0,
        uint256 amount1,
        uint256 nonce,
        uint256 deadline,
        bool viaSignature
    );
    event BinPosted(
        PoolId indexed poolId,
        address indexed maker,
        bytes32 indexed positionId,
        Side side,
        int24 tickLower,
        int24 tickUpper,
        int8 offset,
        uint128 capacity,
        uint128 liquidity,
        uint40 expiry
    );
    event FeesClaimed(
        PoolId indexed poolId,
        address indexed maker,
        bytes32 indexed positionId,
        address caller,
        uint256 amount0,
        uint256 amount1
    );
    event PositionsRetired(
        PoolId indexed poolId, address indexed caller, uint256 candidateCount, uint256 maxRetire, uint256 retired
    );

    function setUp() public {
        (maker, makerPk) = makeAddrAndKey("maker");
        (maker2, maker2Pk) = makeAddrAndKey("maker2");

        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG
        );
        hook = NativeBookHook(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags)));
        deployCodeTo("NativeBookHook", abi.encode(manager, uint32(5_000_000), owner), address(hook));

        testPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: FEE_PIPS,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        testPoolId = testPoolKey.toId();

        vm.prank(owner);
        hook.initializePool(testPoolKey, TickMath.getSqrtPriceAtTick(0), _defaultConfig());

        _seedPassiveLiquidity();
        _fundAndApproveMaker(maker);
        _fundAndApproveMaker(maker2);
    }

    function test_implementsIALFHookIndicativeQuoteSurface() public view {
        IALFHook alfHook = IALFHook(address(hook));

        assertTrue(alfHook.isLive());
        assertEq(alfHook.maxGas(), uint32(5_000_000));
        assertGt(alfHook.getIndicativeQuote(testPoolKey, true, -1 ether, ""), 0);

        (uint256 reserves0, uint256 reserves1) = alfHook.getReserves(testPoolKey);
        assertEq(reserves0, 0);
        assertEq(reserves1, 0);

        (uint256 effective0, uint256 effective1) = alfHook.getEffectiveLiquidity(testPoolKey);
        assertEq(effective0, 0);
        assertEq(effective1, 0);

        (uint256 amountIn, uint256 amountOut) =
            alfHook.swapToPrice(testPoolKey, true, -1 ether, TickMath.MIN_SQRT_PRICE + 1, "");
        assertGt(amountIn, 0);
        assertGt(amountOut, 0);
    }

    function test_getIndicativeQuote_matchesSwapExactInput() public {
        _assertQuoteMatchesSwap(true, -1 ether);
    }

    function test_getIndicativeQuote_matchesSwapExactOutput() public {
        _assertQuoteMatchesSwap(true, 1 ether);
    }

    function test_swapToPrice_matchesLimitedSwapExecution() public {
        uint160 sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(-BIN_SPACING);

        (uint256 quotedIn, uint256 quotedOut) = hook.swapToPrice(testPoolKey, true, -10 ether, sqrtPriceLimitX96, "");
        BalanceDelta delta = swapRouter.swap(
            testPoolKey,
            SwapParams({zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: sqrtPriceLimitX96}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertApproxEqAbs(quotedIn, uint256(-int256(delta.amount0())), 1);
        assertApproxEqAbs(quotedOut, uint256(int256(delta.amount1())), 1);
    }

    function test_getIndicativeQuote_accountsForSwapTimeRetirement() public {
        BinCapacity[] memory bids = new BinCapacity[](0);
        BinCapacity[] memory asks = new BinCapacity[](1);
        asks[0] = BinCapacity({offset: 1, amount: 100 ether});

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1, 0, 0);
        vm.warp(block.timestamp + 2);

        uint256 quoted = hook.getIndicativeQuote(testPoolKey, false, -110 ether, "");
        assertEq(hook.makerPositionCount(testPoolId, maker), 1);

        BalanceDelta delta = swap(testPoolKey, false, -110 ether, "");
        uint256 actual = uint256(int256(delta.amount0()));

        assertApproxEqAbs(quoted, actual, 1);
        assertEq(hook.makerPositionCount(testPoolId, maker), 0);
    }

    function test_replaceLadder_postsCanonicalBidAndAskBins() public {
        BinCapacity[] memory bids = new BinCapacity[](1);
        bids[0] = BinCapacity({offset: -1, amount: 100 ether});
        BinCapacity[] memory asks = new BinCapacity[](1);
        asks[0] = BinCapacity({offset: 1, amount: 100 ether});

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);

        assertEq(hook.makerPositionCount(testPoolId, maker), 2);

        bytes32 bidId = hook.makerPositionAt(testPoolId, maker, 0);
        bytes32 askId = hook.makerPositionAt(testPoolId, maker, 1);
        PositionInfo memory bid = hook.positions(bidId);
        PositionInfo memory ask = hook.positions(askId);

        assertEq(PoolId.unwrap(bid.poolId), PoolId.unwrap(testPoolId));
        assertEq(PoolId.unwrap(ask.poolId), PoolId.unwrap(testPoolId));
        assertEq(uint8(bid.side), uint8(Side.Bid));
        assertEq(uint8(ask.side), uint8(Side.Ask));
        assertEq(bid.tickLower, -BIN_SPACING);
        assertEq(bid.tickUpper, 0);
        assertEq(ask.tickLower, BIN_SPACING);
        assertEq(ask.tickUpper, 2 * BIN_SPACING);
        assertGt(bid.liquidity, 0);
        assertGt(ask.liquidity, 0);
        assertTrue(bid.active);
        assertTrue(ask.active);
    }

    function test_replaceLadder_replacesPreviousBins() public {
        BinCapacity[] memory bids = new BinCapacity[](1);
        BinCapacity[] memory asks = new BinCapacity[](1);
        bids[0] = BinCapacity({offset: -1, amount: 100 ether});
        asks[0] = BinCapacity({offset: 1, amount: 100 ether});

        vm.startPrank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
        bids[0] = BinCapacity({offset: -2, amount: 75 ether});
        asks = new BinCapacity[](0);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
        vm.stopPrank();

        assertEq(hook.makerPositionCount(testPoolId, maker), 1);
        bytes32 positionId = hook.makerPositionAt(testPoolId, maker, 0);
        (,,, int24 tickLower, int24 tickUpper,,,,) = _readPosition(positionId);
        assertEq(tickLower, -2 * BIN_SPACING);
        assertEq(tickUpper, -BIN_SPACING);
    }

    function test_replaceLadder_sameBinDoesNotDuplicatePosition() public {
        BinCapacity[] memory bids = new BinCapacity[](1);
        BinCapacity[] memory asks = new BinCapacity[](0);
        bids[0] = BinCapacity({offset: -1, amount: 100 ether});

        vm.startPrank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
        bytes32 firstId = hook.makerPositionAt(testPoolId, maker, 0);
        bids[0] = BinCapacity({offset: -1, amount: 75 ether});
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
        vm.stopPrank();

        assertEq(hook.makerPositionCount(testPoolId, maker), 1);
        assertEq(hook.activePositionCount(testPoolId), 1);
        assertEq(hook.makerPositionAt(testPoolId, maker, 0), firstId);
        (,,,,, uint128 liquidity,,,) = _readPosition(firstId);
        assertGt(liquidity, 0);
    }

    function testFuzz_replaceLadder_tracksCanonicalBins(uint8 bidCountRaw, uint8 askCountRaw, uint40 ttlRaw) public {
        uint256 bidCount = bound(bidCountRaw, 0, 4);
        uint256 askCount = bound(askCountRaw, 0, 4);
        uint40 ttl = uint40(bound(ttlRaw, 1, 1 days));

        BinCapacity[] memory bids = new BinCapacity[](bidCount);
        for (uint256 i; i < bidCount; ++i) {
            bids[i] = BinCapacity({offset: -int8(uint8(i + 1)), amount: 100 ether});
        }
        BinCapacity[] memory asks = new BinCapacity[](askCount);
        for (uint256 i; i < askCount; ++i) {
            asks[i] = BinCapacity({offset: int8(uint8(i + 1)), amount: 100 ether});
        }

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, ttl, 0, 0);

        uint256 totalCount = bidCount + askCount;
        assertEq(hook.makerPositionCount(testPoolId, maker), totalCount);
        assertEq(hook.activePositionCount(testPoolId), totalCount);
        for (uint256 i; i < totalCount; ++i) {
            bytes32 positionId = hook.makerPositionAt(testPoolId, maker, i);
            (address maker_, PoolId poolId,, int24 tickLower, int24 tickUpper, uint128 liquidity,, bool active,) =
                _readPosition(positionId);
            assertEq(maker_, maker);
            assertEq(PoolId.unwrap(poolId), PoolId.unwrap(testPoolId));
            assertEq(tickUpper - tickLower, BIN_SPACING);
            assertGt(liquidity, 0);
            assertTrue(active);
        }
    }

    function test_multipleMakersCanQuoteSameCanonicalBin() public {
        BinCapacity[] memory bids = new BinCapacity[](1);
        BinCapacity[] memory asks = new BinCapacity[](0);
        bids[0] = BinCapacity({offset: -1, amount: 100 ether});

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
        vm.prank(maker2);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);

        bytes32 maker1Id = hook.makerPositionAt(testPoolId, maker, 0);
        bytes32 maker2Id = hook.makerPositionAt(testPoolId, maker2, 0);
        assertNotEq(maker1Id, maker2Id);
        assertEq(hook.makerPositionCount(testPoolId, maker), 1);
        assertEq(hook.makerPositionCount(testPoolId, maker2), 1);
        assertEq(hook.activePositionCount(testPoolId), 2);

        (,,, int24 maker1Lower, int24 maker1Upper,,,,) = _readPosition(maker1Id);
        (,,, int24 maker2Lower, int24 maker2Upper,,,,) = _readPosition(maker2Id);
        assertEq(maker1Lower, maker2Lower);
        assertEq(maker1Upper, maker2Upper);
    }

    function test_depositCreditsMakerInventory() public {
        address depositor = makeAddr("depositor");
        token0.transfer(depositor, 100 ether);

        vm.startPrank(depositor);
        token0.approve(address(hook), 100 ether);
        vm.expectEmit(true, true, true, true, address(hook));
        emit InventoryDeposited(maker, Currency.unwrap(currency0), depositor, 100 ether, 100 ether);
        hook.depositFor(maker, currency0, 100 ether);
        vm.stopPrank();

        assertEq(hook.inventoryBalance(maker, currency0), 500_100 ether);
    }

    function test_withdrawDebitsMakerInventoryAndTransfersToRecipient() public {
        address recipient = makeAddr("recipient");
        uint256 hookBalanceBefore = hook.inventoryBalance(maker, currency0);
        uint256 recipientBalanceBefore = token0.balanceOf(recipient);

        vm.expectEmit(true, true, true, true, address(hook));
        emit InventoryWithdrawn(maker, Currency.unwrap(currency0), recipient, 10 ether);
        vm.prank(maker);
        hook.withdraw(currency0, 10 ether, recipient);

        assertEq(hook.inventoryBalance(maker, currency0), hookBalanceBefore - 10 ether);
        assertEq(token0.balanceOf(recipient), recipientBalanceBefore + 10 ether);
    }

    function test_replaceLadder_revertsWhenCustodiedInventoryIsInsufficient() public {
        address emptyMaker = makeAddr("emptyMaker");
        BinCapacity[] memory bids = new BinCapacity[](1);
        bids[0] = BinCapacity({offset: -1, amount: 100 ether});
        BinCapacity[] memory asks = new BinCapacity[](0);

        vm.expectRevert(
            abi.encodeWithSelector(InsufficientInventory.selector, emptyMaker, Currency.unwrap(currency1), 0, 100 ether)
        );
        vm.prank(emptyMaker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
    }

    function test_replaceLadder_revertsForDuplicateBidOffset() public {
        BinCapacity[] memory bids = new BinCapacity[](2);
        bids[0] = BinCapacity({offset: -1, amount: 100 ether});
        bids[1] = BinCapacity({offset: -1, amount: 50 ether});
        BinCapacity[] memory asks = new BinCapacity[](0);

        vm.expectRevert(DuplicateBinOffset.selector);
        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
    }

    function test_replaceLadder_revertsForDuplicateAskOffset() public {
        BinCapacity[] memory bids = new BinCapacity[](0);
        BinCapacity[] memory asks = new BinCapacity[](2);
        asks[0] = BinCapacity({offset: 1, amount: 100 ether});
        asks[1] = BinCapacity({offset: 1, amount: 50 ether});

        vm.expectRevert(DuplicateBinOffset.selector);
        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
    }

    function test_replaceLadderWithSig_allowsRelayerToPostMakerLadder() public {
        BinCapacity[] memory bids = new BinCapacity[](1);
        bids[0] = BinCapacity({offset: -1, amount: 100 ether});
        BinCapacity[] memory asks = new BinCapacity[](1);
        asks[0] = BinCapacity({offset: 1, amount: 100 ether});
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _signReplaceLadder(makerPk, maker, bids, asks, 1 hours, deadline);

        vm.prank(relayer);
        hook.replaceLadderWithSig(testPoolKey, maker, bids, asks, 1 hours, 0, 0, deadline, signature);

        assertEq(hook.nonces(maker), 1);
        assertEq(hook.makerPositionCount(testPoolId, maker), 2);
    }

    function test_replaceLadderWithSig_emitsRelayerAndNonceContext() public {
        BinCapacity[] memory bids = new BinCapacity[](1);
        bids[0] = BinCapacity({offset: -1, amount: 100 ether});
        BinCapacity[] memory asks = new BinCapacity[](0);
        uint40 ttl = 1 hours;
        uint40 expiry = uint40(block.timestamp) + ttl;
        uint256 deadline = block.timestamp + 2 hours;
        uint256 nonce = hook.nonces(maker);
        bytes memory signature = _signReplaceLadder(makerPk, maker, bids, asks, ttl, deadline);

        vm.expectEmit(true, true, true, true, address(hook));
        emit LadderReplaced(testPoolId, maker, relayer, 1, 0, expiry, nonce, deadline, true);
        vm.prank(relayer);
        hook.replaceLadderWithSig(testPoolKey, maker, bids, asks, ttl, 0, 0, deadline, signature);
    }

    function test_replaceLadderWithSig_replacesExistingLadder() public {
        BinCapacity[] memory bids = new BinCapacity[](1);
        bids[0] = BinCapacity({offset: -1, amount: 100 ether});
        BinCapacity[] memory asks = new BinCapacity[](0);

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
        assertEq(hook.makerPositionCount(testPoolId, maker), 1);

        bids[0] = BinCapacity({offset: -2, amount: 75 ether});
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _signReplaceLadder(makerPk, maker, bids, asks, 1 hours, deadline);

        vm.prank(relayer);
        hook.replaceLadderWithSig(testPoolKey, maker, bids, asks, 1 hours, 0, 0, deadline, signature);

        bytes32 positionId = hook.makerPositionAt(testPoolId, maker, 0);
        (,,, int24 tickLower, int24 tickUpper,,,,) = _readPosition(positionId);
        assertEq(hook.makerPositionCount(testPoolId, maker), 1);
        assertEq(tickLower, -2 * BIN_SPACING);
        assertEq(tickUpper, -BIN_SPACING);
    }

    function test_replaceLadderWithSig_revertsOnReplay() public {
        BinCapacity[] memory bids = new BinCapacity[](1);
        bids[0] = BinCapacity({offset: -1, amount: 100 ether});
        BinCapacity[] memory asks = new BinCapacity[](0);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _signReplaceLadder(makerPk, maker, bids, asks, 1 hours, deadline);

        vm.prank(relayer);
        hook.replaceLadderWithSig(testPoolKey, maker, bids, asks, 1 hours, 0, 0, deadline, signature);

        vm.expectRevert(NativeBookHook.InvalidSignature.selector);
        vm.prank(relayer);
        hook.replaceLadderWithSig(testPoolKey, maker, bids, asks, 1 hours, 0, 0, deadline, signature);
        assertEq(hook.nonces(maker), 1);
    }

    function test_replaceLadderWithSig_revertsWhenExpired() public {
        BinCapacity[] memory bids = new BinCapacity[](1);
        bids[0] = BinCapacity({offset: -1, amount: 100 ether});
        BinCapacity[] memory asks = new BinCapacity[](0);
        uint256 deadline = 1 days;
        bytes memory signature = _signReplaceLadder(makerPk, maker, bids, asks, 1 hours, deadline);

        vm.warp(deadline + 1);
        vm.expectRevert(NativeBookHook.SignatureExpired.selector);
        vm.prank(relayer);
        hook.replaceLadderWithSig(testPoolKey, maker, bids, asks, 1 hours, 0, 0, deadline, signature);
        assertEq(hook.nonces(maker), 0);
    }

    function test_replaceLadderWithSig_revertsForWrongSigner() public {
        BinCapacity[] memory bids = new BinCapacity[](1);
        bids[0] = BinCapacity({offset: -1, amount: 100 ether});
        BinCapacity[] memory asks = new BinCapacity[](0);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _signReplaceLadder(maker2Pk, maker, bids, asks, 1 hours, deadline);

        vm.expectRevert(NativeBookHook.InvalidSignature.selector);
        vm.prank(relayer);
        hook.replaceLadderWithSig(testPoolKey, maker, bids, asks, 1 hours, 0, 0, deadline, signature);
        assertEq(hook.nonces(maker), 0);
    }

    function test_replaceLadderWithSig_revertsWhenRefTickMovesOutsideBound() public {
        BinCapacity[] memory bids = new BinCapacity[](1);
        bids[0] = BinCapacity({offset: -1, amount: 100 ether});
        BinCapacity[] memory asks = new BinCapacity[](0);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _signReplaceLadder(makerPk, maker, bids, asks, 1 hours, 60, 0, deadline);

        vm.expectRevert(abi.encodeWithSelector(BinMath.RefTickSlippage.selector, 60, 0, 0));
        vm.prank(relayer);
        hook.replaceLadderWithSig(testPoolKey, maker, bids, asks, 1 hours, 60, 0, deadline, signature);
    }

    function test_replaceLadderWithSig_revertsWhenExpiryWouldExceedDeadline() public {
        BinCapacity[] memory bids = new BinCapacity[](1);
        bids[0] = BinCapacity({offset: -1, amount: 100 ether});
        BinCapacity[] memory asks = new BinCapacity[](0);
        uint40 ttl = 1 hours;
        uint256 deadline = block.timestamp + ttl;
        bytes memory signature = _signReplaceLadder(makerPk, maker, bids, asks, ttl, deadline);

        vm.warp(block.timestamp + 1);
        vm.expectRevert(NativeBookHook.InvalidQuoteTtl.selector);
        vm.prank(relayer);
        hook.replaceLadderWithSig(testPoolKey, maker, bids, asks, ttl, 0, 0, deadline, signature);
    }

    function test_directReplaceInvalidatesOlderSignedReplace() public {
        BinCapacity[] memory bids = new BinCapacity[](1);
        bids[0] = BinCapacity({offset: -1, amount: 100 ether});
        BinCapacity[] memory asks = new BinCapacity[](0);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory staleSignature = _signReplaceLadder(makerPk, maker, bids, asks, 1 hours, deadline);

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);

        vm.expectRevert(NativeBookHook.InvalidSignature.selector);
        vm.prank(relayer);
        hook.replaceLadderWithSig(testPoolKey, maker, bids, asks, 1 hours, 0, 0, deadline, staleSignature);
        assertEq(hook.nonces(maker), 1);
    }

    function test_expiredBinRetiresOnGenericSwapWithoutHookData() public {
        BinCapacity[] memory bids = new BinCapacity[](1);
        BinCapacity[] memory asks = new BinCapacity[](0);
        bids[0] = BinCapacity({offset: -1, amount: 100 ether});

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1, 0, 0);
        assertEq(hook.makerPositionCount(testPoolId, maker), 1);

        vm.warp(block.timestamp + 2);
        BalanceDelta delta = swap(testPoolKey, true, -1 ether, "");

        assertLt(delta.amount0(), 0);
        assertGt(delta.amount1(), 0);
        assertEq(hook.makerPositionCount(testPoolId, maker), 0);
    }

    function test_expiredBinCanBeRetiredByKeeper() public {
        BinCapacity[] memory bids = new BinCapacity[](1);
        BinCapacity[] memory asks = new BinCapacity[](0);
        bids[0] = BinCapacity({offset: -1, amount: 100 ether});

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1, 0, 0);
        bytes32 positionId = hook.makerPositionAt(testPoolId, maker, 0);

        vm.warp(block.timestamp + 2);
        hook.retirePosition(testPoolKey, positionId);

        assertEq(hook.makerPositionCount(testPoolId, maker), 0);
        assertEq(hook.activePositionCount(testPoolId), 0);
    }

    function test_retirePosition_revertsBeforeExpiryWhenNotCrossed() public {
        BinCapacity[] memory bids = new BinCapacity[](1);
        BinCapacity[] memory asks = new BinCapacity[](0);
        bids[0] = BinCapacity({offset: -1, amount: 100 ether});

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
        bytes32 positionId = hook.makerPositionAt(testPoolId, maker, 0);

        vm.expectRevert(NativeBookHook.PositionNotRetirable.selector);
        hook.retirePosition(testPoolKey, positionId);
    }

    function test_retirePositions_retiresBoundedExpiredBatchAndSkipsFreshIds() public {
        BinCapacity[] memory bids = new BinCapacity[](3);
        bids[0] = BinCapacity({offset: -1, amount: 100 ether});
        bids[1] = BinCapacity({offset: -2, amount: 100 ether});
        bids[2] = BinCapacity({offset: -3, amount: 100 ether});
        BinCapacity[] memory asks = new BinCapacity[](0);

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1, 0, 0);
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = hook.makerPositionAt(testPoolId, maker, 0);
        ids[1] = hook.makerPositionAt(testPoolId, maker, 1);

        vm.warp(block.timestamp + 2);
        uint256 retired = hook.retirePositions(testPoolKey, ids, 2);

        assertEq(retired, 2);
        assertEq(hook.makerPositionCount(testPoolId, maker), 1);

        ids = new bytes32[](1);
        ids[0] = hook.makerPositionAt(testPoolId, maker, 0);
        retired = hook.retirePositions(testPoolKey, ids, 1);
        assertEq(retired, 1);
        assertEq(hook.makerPositionCount(testPoolId, maker), 0);
    }

    function test_retirePositions_emitsBatchSummary() public {
        BinCapacity[] memory bids = new BinCapacity[](2);
        bids[0] = BinCapacity({offset: -1, amount: 100 ether});
        bids[1] = BinCapacity({offset: -2, amount: 100 ether});
        BinCapacity[] memory asks = new BinCapacity[](0);

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1, 0, 0);
        bytes32[] memory ids = new bytes32[](3);
        ids[0] = bytes32(uint256(123));
        ids[1] = hook.makerPositionAt(testPoolId, maker, 0);
        ids[2] = hook.makerPositionAt(testPoolId, maker, 1);

        vm.warp(block.timestamp + 2);
        vm.expectEmit(true, true, false, true, address(hook));
        emit PositionsRetired(testPoolId, address(this), 3, 3, 2);
        hook.retirePositions(testPoolKey, ids, 3);
    }

    function test_retirePositions_revertsWhenCandidatesExceedScanCap() public {
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = bytes32(uint256(1));
        ids[1] = bytes32(uint256(2));

        vm.expectRevert(abi.encodeWithSelector(NativeBookHook.TooManyRetireCandidates.selector, 2, 1));
        hook.retirePositions(testPoolKey, ids, 1);
    }

    function test_genericSwapExactInputAcceptsArbitraryHookData() public {
        BalanceDelta delta = swap(testPoolKey, true, 1 ether, abi.encode("ignored-by-native-book"));

        assertLt(delta.amount0(), 0);
        assertGt(delta.amount1(), 0);
    }

    function test_genericSwapExactOutputOneForZeroAcceptsEmptyHookData() public {
        BalanceDelta delta = swap(testPoolKey, false, -1 ether, "");

        assertGt(delta.amount0(), 0);
        assertLt(delta.amount1(), 0);
    }

    function test_swapRevertsWhenPoolNotLive() public {
        vm.prank(owner);
        hook.setPoolLive(testPoolKey, false);

        _expectHookWrappedError(IHooks.beforeSwap.selector, abi.encodeWithSelector(PoolNotLive.selector, testPoolId));
        swap(testPoolKey, true, 1 ether, "");
    }

    function test_setPoolLive_emitsOldAndNewValues() public {
        vm.expectEmit(true, true, false, true, address(hook));
        emit PoolLivenessUpdated(testPoolId, false);
        vm.prank(owner);
        hook.setPoolLive(testPoolKey, false);
    }

    function test_crossedAskCanBeRetiredAfterGenericSwap() public {
        BinCapacity[] memory bids = new BinCapacity[](0);
        BinCapacity[] memory asks = new BinCapacity[](1);
        asks[0] = BinCapacity({offset: 1, amount: 100 ether});

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
        uint256 makerToken1BeforeRetire = hook.inventoryBalance(maker, currency1);

        swap(testPoolKey, false, 110 ether, "");
        (, int24 currentTick,,) = manager.getSlot0(testPoolId);

        assertGe(currentTick, 2 * BIN_SPACING);
        assertEq(hook.makerPositionCount(testPoolId, maker), 1);
        hook.retirePosition(testPoolKey, hook.makerPositionAt(testPoolId, maker, 0));
        assertEq(hook.makerPositionCount(testPoolId, maker), 0);
        assertGt(hook.inventoryBalance(maker, currency1), makerToken1BeforeRetire);
    }

    function test_claimFeesCollectsAccruedFeesWithoutRemovingPosition() public {
        BinCapacity[] memory bids = new BinCapacity[](0);
        BinCapacity[] memory asks = new BinCapacity[](1);
        asks[0] = BinCapacity({offset: 1, amount: 100 ether});

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
        bytes32 positionId = hook.makerPositionAt(testPoolId, maker, 0);

        swap(testPoolKey, false, 110 ether, "");
        uint256 makerToken1BeforeClaim = hook.inventoryBalance(maker, currency1);

        hook.claimFees(testPoolKey, positionId);

        assertEq(hook.makerPositionCount(testPoolId, maker), 1);
        assertGt(hook.inventoryBalance(maker, currency1), makerToken1BeforeClaim);
    }

    function test_claimFees_emitsCallerAndClaimedAmounts() public {
        BinCapacity[] memory bids = new BinCapacity[](0);
        BinCapacity[] memory asks = new BinCapacity[](1);
        asks[0] = BinCapacity({offset: 1, amount: 100 ether});

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
        bytes32 positionId = hook.makerPositionAt(testPoolId, maker, 0);
        swap(testPoolKey, false, 110 ether, "");

        vm.recordLogs();
        vm.prank(relayer);
        hook.claimFees(testPoolKey, positionId);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bytes32 signature = keccak256("FeesClaimed(bytes32,address,bytes32,address,uint256,uint256)");
        bool found;
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].topics[0] == signature) {
                assertEq(entries[i].topics[1], PoolId.unwrap(testPoolId));
                assertEq(address(uint160(uint256(entries[i].topics[2]))), maker);
                assertEq(entries[i].topics[3], positionId);
                (address caller, uint256 amount0, uint256 amount1) =
                    abi.decode(entries[i].data, (address, uint256, uint256));
                assertEq(caller, relayer);
                assertEq(amount0, 0);
                assertGt(amount1, 0);
                found = true;
            }
        }
        assertTrue(found);
    }

    function test_claimFees_revertsForInvalidPosition() public {
        vm.expectRevert(NativeBookHook.InvalidPosition.selector);
        hook.claimFees(testPoolKey, bytes32(uint256(123)));
    }

    function test_directOneBinLiquidityIsReservedForBook() public {
        _expectHookWrappedError(IHooks.beforeAddLiquidity.selector, NativeBookHook.ReservedBookRange.selector);
        modifyLiquidityRouter.modifyLiquidity(
            testPoolKey,
            ModifyLiquidityParams({
                tickLower: BIN_SPACING, tickUpper: 2 * BIN_SPACING, liquidityDelta: 1 ether, salt: bytes32(uint256(1))
            }),
            ""
        );
    }

    function test_replaceLadder_emitsPositionIdOnBinPosted() public {
        BinCapacity[] memory bids = new BinCapacity[](1);
        bids[0] = BinCapacity({offset: -1, amount: 100 ether});
        BinCapacity[] memory asks = new BinCapacity[](0);
        bytes32 positionId = keccak256(abi.encode(testPoolId, maker, Side.Bid, -BIN_SPACING));

        vm.expectEmit(true, true, true, false, address(hook));
        emit BinPosted(testPoolId, maker, positionId, Side.Bid, 0, 0, 0, 0, 0, 0);
        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
    }

    function test_broadPassiveLiquidityCanBeAddedAndRemoved() public {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -2 * BIN_SPACING, tickUpper: 2 * BIN_SPACING, liquidityDelta: 1 ether, salt: bytes32(uint256(77))
        });

        modifyLiquidityRouter.modifyLiquidity(testPoolKey, params, "");
        params.liquidityDelta = -1 ether;
        modifyLiquidityRouter.modifyLiquidity(testPoolKey, params, "");
    }

    function test_getIndicativeQuote_returnsZeroForUnfillableExactOutput() public view {
        uint256 quoted = hook.getIndicativeQuote(testPoolKey, true, 1_000_000_000 ether, "");
        assertEq(quoted, 0);
    }

    function test_swapToPrice_returnsZeroForInvalidPriceLimit() public view {
        (uint256 amountIn, uint256 amountOut) =
            hook.swapToPrice(testPoolKey, true, -1 ether, TickMath.MAX_SQRT_PRICE - 1, "");
        assertEq(amountIn, 0);
        assertEq(amountOut, 0);
    }

    function test_getIndicativeQuote_matchesSwapForDynamicFeePool() public {
        PoolKey memory dynamicPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        vm.prank(owner);
        hook.initializePool(dynamicPoolKey, TickMath.getSqrtPriceAtTick(0), _defaultConfig());
        modifyLiquidityRouter.modifyLiquidity(
            dynamicPoolKey,
            ModifyLiquidityParams({
                tickLower: -10 * BIN_SPACING,
                tickUpper: 10 * BIN_SPACING,
                liquidityDelta: 100 ether,
                salt: bytes32(uint256(888))
            }),
            ""
        );

        uint256 quoted = hook.getIndicativeQuote(dynamicPoolKey, true, -1 ether, "");
        BalanceDelta delta = swap(dynamicPoolKey, true, -1 ether, "");
        uint256 actual = uint256(int256(delta.amount1()));

        assertApproxEqAbs(quoted, actual, 1);
    }

    function test_cancelLadder_removesAllMakerBins() public {
        BinCapacity[] memory bids = new BinCapacity[](1);
        bids[0] = BinCapacity({offset: -1, amount: 100 ether});
        BinCapacity[] memory asks = new BinCapacity[](1);
        asks[0] = BinCapacity({offset: 1, amount: 100 ether});

        vm.startPrank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
        hook.cancelLadder(testPoolKey);
        vm.stopPrank();

        assertEq(hook.makerPositionCount(testPoolId, maker), 0);
        assertEq(hook.activePositionCount(testPoolId), 0);
    }

    function test_cancelLadderWithSig_allowsRelayerToCancelMakerLadder() public {
        BinCapacity[] memory bids = new BinCapacity[](1);
        bids[0] = BinCapacity({offset: -1, amount: 100 ether});
        BinCapacity[] memory asks = new BinCapacity[](1);
        asks[0] = BinCapacity({offset: 1, amount: 100 ether});

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
        assertEq(hook.makerPositionCount(testPoolId, maker), 2);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _signCancelLadder(makerPk, maker, deadline);

        vm.prank(relayer);
        hook.cancelLadderWithSig(testPoolKey, maker, deadline, signature);

        assertEq(hook.nonces(maker), 2);
        assertEq(hook.makerPositionCount(testPoolId, maker), 0);
        assertEq(hook.activePositionCount(testPoolId), 0);
    }

    function test_cancelLadderWithSig_emitsRelayerAndNonceContext() public {
        BinCapacity[] memory bids = new BinCapacity[](1);
        bids[0] = BinCapacity({offset: -1, amount: 100 ether});
        BinCapacity[] memory asks = new BinCapacity[](0);

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = hook.nonces(maker);
        bytes memory signature = _signCancelLadder(makerPk, maker, deadline);

        vm.expectEmit(true, true, true, false, address(hook));
        emit LadderCanceled(testPoolId, maker, relayer, 1, 0, 0, nonce, deadline, true);
        vm.prank(relayer);
        hook.cancelLadderWithSig(testPoolKey, maker, deadline, signature);
    }

    function test_cancelLadderWithSig_revertsOnReplay() public {
        BinCapacity[] memory bids = new BinCapacity[](1);
        bids[0] = BinCapacity({offset: -1, amount: 100 ether});
        BinCapacity[] memory asks = new BinCapacity[](0);

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _signCancelLadder(makerPk, maker, deadline);

        vm.prank(relayer);
        hook.cancelLadderWithSig(testPoolKey, maker, deadline, signature);

        vm.expectRevert(NativeBookHook.InvalidSignature.selector);
        vm.prank(relayer);
        hook.cancelLadderWithSig(testPoolKey, maker, deadline, signature);
        assertEq(hook.nonces(maker), 2);
    }

    function test_directCancelInvalidatesOlderSignedCancel() public {
        BinCapacity[] memory bids = new BinCapacity[](1);
        bids[0] = BinCapacity({offset: -1, amount: 100 ether});
        BinCapacity[] memory asks = new BinCapacity[](0);

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory staleSignature = _signCancelLadder(makerPk, maker, deadline);

        vm.prank(maker);
        hook.cancelLadder(testPoolKey);

        vm.expectRevert(NativeBookHook.InvalidSignature.selector);
        vm.prank(relayer);
        hook.cancelLadderWithSig(testPoolKey, maker, deadline, staleSignature);
        assertEq(hook.nonces(maker), 2);
    }

    function test_cancelLadderWithSig_revertsWhenExpired() public {
        uint256 deadline = 1 days;
        bytes memory signature = _signCancelLadder(makerPk, maker, deadline);

        vm.warp(deadline + 1);
        vm.expectRevert(NativeBookHook.SignatureExpired.selector);
        vm.prank(relayer);
        hook.cancelLadderWithSig(testPoolKey, maker, deadline, signature);
        assertEq(hook.nonces(maker), 0);
    }

    function test_cancelLadderWithSig_revertsForWrongSigner() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _signCancelLadder(maker2Pk, maker, deadline);

        vm.expectRevert(NativeBookHook.InvalidSignature.selector);
        vm.prank(relayer);
        hook.cancelLadderWithSig(testPoolKey, maker, deadline, signature);
        assertEq(hook.nonces(maker), 0);
    }

    function test_cancelLadderReturnsUnfilledInventory() public {
        uint256 token0Before = hook.inventoryBalance(maker, currency0);
        uint256 token1Before = hook.inventoryBalance(maker, currency1);

        BinCapacity[] memory bids = new BinCapacity[](1);
        bids[0] = BinCapacity({offset: -1, amount: 100 ether});
        BinCapacity[] memory asks = new BinCapacity[](1);
        asks[0] = BinCapacity({offset: 1, amount: 100 ether});

        vm.startPrank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
        assertLt(hook.inventoryBalance(maker, currency0), token0Before);
        assertLt(hook.inventoryBalance(maker, currency1), token1Before);
        hook.cancelLadder(testPoolKey);
        vm.stopPrank();

        assertApproxEqAbs(hook.inventoryBalance(maker, currency0), token0Before, 1);
        assertApproxEqAbs(hook.inventoryBalance(maker, currency1), token1Before, 1);
    }

    function test_initializePool_validatesConfig() public {
        PoolConfig memory config = _defaultConfig();
        config.binSpacingTicks = 55;

        vm.expectRevert(InvalidPoolConfig.selector);
        vm.prank(owner);
        hook.initializePool(testPoolKey, TickMath.getSqrtPriceAtTick(0), config);
    }

    function test_initializePool_revertsForZeroMinBinLiquidity() public {
        PoolConfig memory config = _defaultConfig();
        config.minBinLiquidity = 0;

        vm.expectRevert(InvalidPoolConfig.selector);
        vm.prank(owner);
        hook.initializePool(testPoolKey, TickMath.getSqrtPriceAtTick(0), config);
    }

    function test_directPoolManagerInitializeIsBlocked() public {
        _expectHookWrappedError(IHooks.beforeInitialize.selector, OwnedALFHook.DirectInitializeBlocked.selector);
        manager.initialize(testPoolKey, TickMath.getSqrtPriceAtTick(0));
    }

    function test_replaceLadder_revertsForTooLongTtl() public {
        BinCapacity[] memory bids = new BinCapacity[](0);
        BinCapacity[] memory asks = new BinCapacity[](0);

        vm.expectRevert(NativeBookHook.InvalidQuoteTtl.selector);
        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 days + 1, 0, 0);
    }

    function test_replaceLadder_revertsForTooManyBins() public {
        BinCapacity[] memory bids = new BinCapacity[](9);
        BinCapacity[] memory asks = new BinCapacity[](0);

        vm.expectRevert(NativeBookHook.TooManyBins.selector);
        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
    }

    function test_replaceLadder_revertsForWrongSideOffset() public {
        BinCapacity[] memory bids = new BinCapacity[](1);
        BinCapacity[] memory asks = new BinCapacity[](0);
        bids[0] = BinCapacity({offset: 1, amount: 100 ether});

        vm.expectRevert(InvalidBinOffset.selector);
        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
    }

    function test_gas_replaceLadder_twoSided() public {
        BinCapacity[] memory bids = new BinCapacity[](2);
        bids[0] = BinCapacity({offset: -1, amount: 100 ether});
        bids[1] = BinCapacity({offset: -2, amount: 100 ether});
        BinCapacity[] memory asks = new BinCapacity[](2);
        asks[0] = BinCapacity({offset: 1, amount: 100 ether});
        asks[1] = BinCapacity({offset: 2, amount: 100 ether});

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
        vm.snapshotGasLastCall("NativeBookHook_replaceLadder_twoSided");
    }

    function test_gas_replaceLadderWithSig_twoSided() public {
        BinCapacity[] memory bids = new BinCapacity[](2);
        bids[0] = BinCapacity({offset: -1, amount: 100 ether});
        bids[1] = BinCapacity({offset: -2, amount: 100 ether});
        BinCapacity[] memory asks = new BinCapacity[](2);
        asks[0] = BinCapacity({offset: 1, amount: 100 ether});
        asks[1] = BinCapacity({offset: 2, amount: 100 ether});
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _signReplaceLadder(makerPk, maker, bids, asks, 1 hours, deadline);

        vm.prank(relayer);
        hook.replaceLadderWithSig(testPoolKey, maker, bids, asks, 1 hours, 0, 0, deadline, signature);
        vm.snapshotGasLastCall("NativeBookHook_replaceLadderWithSig_twoSided");
    }

    function test_gas_swapWithoutRetire() public {
        BalanceDelta delta = swap(testPoolKey, true, 1 ether, "");
        assertLt(delta.amount0(), 0);
        assertGt(delta.amount1(), 0);
        vm.snapshotGasLastCall("NativeBookHook_swap_noRetire");
    }

    function test_gas_swapRetireExpired() public {
        BinCapacity[] memory bids = new BinCapacity[](1);
        BinCapacity[] memory asks = new BinCapacity[](0);
        bids[0] = BinCapacity({offset: -1, amount: 100 ether});

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1, 0, 0);
        vm.warp(block.timestamp + 2);

        swap(testPoolKey, true, 1 ether, "");
        vm.snapshotGasLastCall("NativeBookHook_swap_retireExpired");
    }

    function test_gas_retirePositions_expiredBatch() public {
        BinCapacity[] memory bids = new BinCapacity[](3);
        bids[0] = BinCapacity({offset: -1, amount: 100 ether});
        bids[1] = BinCapacity({offset: -2, amount: 100 ether});
        bids[2] = BinCapacity({offset: -3, amount: 100 ether});
        BinCapacity[] memory asks = new BinCapacity[](0);

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1, 0, 0);
        bytes32[] memory ids = new bytes32[](3);
        ids[0] = hook.makerPositionAt(testPoolId, maker, 0);
        ids[1] = hook.makerPositionAt(testPoolId, maker, 1);
        ids[2] = hook.makerPositionAt(testPoolId, maker, 2);
        vm.warp(block.timestamp + 2);

        hook.retirePositions(testPoolKey, ids, 3);
        vm.snapshotGasLastCall("NativeBookHook_retirePositions_expiredBatch");
    }

    function test_gas_claimFees_crossedAsk() public {
        BinCapacity[] memory bids = new BinCapacity[](0);
        BinCapacity[] memory asks = new BinCapacity[](1);
        asks[0] = BinCapacity({offset: 1, amount: 100 ether});

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
        bytes32 positionId = hook.makerPositionAt(testPoolId, maker, 0);
        swap(testPoolKey, false, 110 ether, "");

        hook.claimFees(testPoolKey, positionId);
        vm.snapshotGasLastCall("NativeBookHook_claimFees_crossedAsk");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //        COMPLEX SCENARIOS: multi-maker attribution, TTL, retirement
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Five independent makers run a mix of single-sided and two-sided ladders with variably
    ///         sized bins, some sharing canonical bins and others on disjoint offsets, while orders
    ///         cross the whole book in both directions. Proves per-position attribution (fills credit
    ///         only the OWNING maker, and only on retirement) and that both retirement paths (keeper
    ///         batches and the bounded opportunistic `beforeSwap` scan) work across many makers.
    /// @dev Backbone: {_assertCustody} requires the hook's ERC-20 balance of each currency to equal
    ///      the sum of ALL makers' inventory balances at every checkpoint. Posting debits a maker and
    ///      settles the same amount to the PoolManager; retiring takes it back and credits the same
    ///      maker. Any misattribution across the five makers (wrong maker, double count, lost dust)
    ///      breaks this equality.
    function test_scenario_multiMakerBidirectionalAttributionAndRetirement() public {
        address[] memory makers = _fiveMakers();
        address m1 = makers[0]; // two-sided (posted by signature)
        address m2 = makers[1]; // ask-only (posted by signature)
        address m3 = makers[2]; // bid-only
        address m4 = makers[3]; // two-sided
        address m5 = makers[4]; // ask-only
        uint40 ttl = 1 hours;

        // ---- Phase 0: mixed ladders. Overlaps: ask1{m1,m2}, ask2{m1,m4,m5}, ask4{m4,m5},
        //      bid-1{m1,m3}, bid-2{m1,m4}. Disjoint: ask3{m2}, bid-3{m3}, bid-4{m4}. ----
        _postSig(
            m1,
            makerPk,
            _bins2(_cap(-1, 80 ether), _cap(-2, 120 ether)),
            _bins2(_cap(1, 80 ether), _cap(2, 120 ether)),
            ttl
        );
        _postSig(m2, maker2Pk, _bins0(), _bins2(_cap(1, 200 ether), _cap(3, 60 ether)), ttl);
        vm.prank(m3);
        hook.replaceLadder(testPoolKey, _bins2(_cap(-1, 150 ether), _cap(-3, 90 ether)), _bins0(), ttl, 0, 0);
        vm.prank(m4);
        hook.replaceLadder(
            testPoolKey,
            _bins2(_cap(-2, 100 ether), _cap(-4, 40 ether)),
            _bins2(_cap(2, 100 ether), _cap(4, 40 ether)),
            ttl,
            0,
            0
        );
        vm.prank(m5);
        hook.replaceLadder(testPoolKey, _bins0(), _bins2(_cap(2, 70 ether), _cap(4, 110 ether)), ttl, 0, 0);

        assertEq(hook.activePositionCount(testPoolId), 14, "14 positions across five makers");
        _assertOwnedBy(m1, 4);
        _assertOwnedBy(m2, 2);
        _assertOwnedBy(m3, 2);
        _assertOwnedBy(m4, 4);
        _assertOwnedBy(m5, 2);
        _assertCustody(makers);

        // ---- Phase 1: a large one-for-zero order crosses the entire ask side (8 ask positions) ----
        _swapToTick(false, 6 * BIN_SPACING); // above the farthest ask bin (offset 4 -> [240, 300])
        (, int24 tickUp,,) = manager.getSlot0(testPoolId);
        assertGe(tickUp, 5 * BIN_SPACING, "crossed through the whole ask ladder");
        _assertCustody(makers);
        assertEq(hook.activePositionCount(testPoolId), 14, "fills are locked in crossed positions, not retired");

        // Retire ONLY m2's crossed asks: m2 is credited; every other maker is left untouched.
        uint256[] memory pre0 = _snap(makers, currency0);
        uint256[] memory pre1 = _snap(makers, currency1);
        assertEq(_retireCrossed(m2), 2, "m2's two asks were crossed and retired");
        assertGt(hook.inventoryBalance(m2, currency1), pre1[1], "m2 credited token1 from its own fills");
        for (uint256 i; i < makers.length; ++i) {
            if (makers[i] == m2) continue;
            assertEq(hook.inventoryBalance(makers[i], currency0), pre0[i], "other maker token0 untouched");
            assertEq(hook.inventoryBalance(makers[i], currency1), pre1[i], "other maker token1 untouched");
        }
        _assertCustody(makers);

        // Retire the remaining crossed asks (m1, m4, m5); only the bid side is left.
        _retireCrossed(m1);
        _retireCrossed(m4);
        _retireCrossed(m5);
        assertEq(hook.activePositionCount(testPoolId), 6, "only the 6 bid positions remain");
        _assertCustody(makers);

        // ---- Phase 2: reverse direction crosses the entire bid side; opportunistic retirement ----
        _swapToTick(true, -5 * BIN_SPACING); // below the farthest bid bin (offset -4 -> [-240, -180])
        (, int24 tickDown,,) = manager.getSlot0(testPoolId);
        assertLt(tickDown, -4 * BIN_SPACING, "crossed through the whole bid ladder");

        uint256 activeBefore = hook.activePositionCount(testPoolId); // 6 crossed bids
        uint256 token0Before = _sumInv(makers, currency0);
        swap(testPoolKey, false, -1 ether, ""); // tiny trigger; beforeSwap scans the pre-swap tick
        assertEq(
            activeBefore - hook.activePositionCount(testPoolId),
            4,
            "opportunistic retirement bounded by maxRetirePerSwap"
        );
        assertGt(_sumInv(makers, currency0), token0Before, "retired bids paid out in token0");
        _assertCustody(makers);

        // ---- Phase 3: cancel every remaining ladder; custody stays attributed and makers net fees ----
        for (uint256 i; i < makers.length; ++i) {
            vm.prank(makers[i]);
            hook.cancelLadder(testPoolKey);
        }
        assertEq(hook.activePositionCount(testPoolId), 0, "book emptied");
        _assertCustody(makers);
        // Five makers deposited 5,000,000 total; crossing their bins on both sides earned LP fees.
        assertGt(_custody(currency0) + _custody(currency1), 5_000_000 ether, "makers net-earned LP fees over the flow");
    }

    /// @notice Five makers post the mixed book with different per-ladder TTLs (some short, some long)
    ///         and overlapping/disjoint bins. Proves per-ladder expiry (short-TTL makers retire while
    ///         long-TTL makers stay live), that a canonical bin quoted by several makers is a set of
    ///         distinct per-maker positions, and that keeper batches and the opportunistic scan both
    ///         honor retirability.
    function test_scenario_perLadderTtlAndSharedBinAttribution() public {
        address[] memory makers = _fiveMakers();
        address m1 = makers[0];
        address m2 = makers[1];
        address m3 = makers[2];
        address m4 = makers[3];
        address m5 = makers[4];
        uint40 ttlLong = 1 hours;
        uint40 ttlShort = 30;

        // Same mixed book as the bidirectional scenario, but TTLs differ per ladder:
        //   long : m1 (two-sided), m4 (two-sided)
        //   short: m2 (ask-only), m3 (bid-only), m5 (ask-only)
        _postSig(
            m1,
            makerPk,
            _bins2(_cap(-1, 80 ether), _cap(-2, 120 ether)),
            _bins2(_cap(1, 80 ether), _cap(2, 120 ether)),
            ttlLong
        );
        _postSig(m2, maker2Pk, _bins0(), _bins2(_cap(1, 200 ether), _cap(3, 60 ether)), ttlShort);
        vm.prank(m3);
        hook.replaceLadder(testPoolKey, _bins2(_cap(-1, 150 ether), _cap(-3, 90 ether)), _bins0(), ttlShort, 0, 0);
        vm.prank(m4);
        hook.replaceLadder(
            testPoolKey,
            _bins2(_cap(-2, 100 ether), _cap(-4, 40 ether)),
            _bins2(_cap(2, 100 ether), _cap(4, 40 ether)),
            ttlLong,
            0,
            0
        );
        vm.prank(m5);
        hook.replaceLadder(testPoolKey, _bins0(), _bins2(_cap(2, 70 ether), _cap(4, 110 ether)), ttlShort, 0, 0);

        assertEq(hook.activePositionCount(testPoolId), 14, "14 positions across five makers");
        _assertOwnedBy(m1, 4);
        _assertOwnedBy(m2, 2);
        _assertOwnedBy(m3, 2);
        _assertOwnedBy(m4, 4);
        _assertOwnedBy(m5, 2);
        _assertCustody(makers);

        // The ask at offset 2 is quoted by three makers as three distinct positions.
        bytes32 a2m1 = _pid(m1, Side.Ask, 2 * BIN_SPACING);
        bytes32 a2m4 = _pid(m4, Side.Ask, 2 * BIN_SPACING);
        bytes32 a2m5 = _pid(m5, Side.Ask, 2 * BIN_SPACING);
        assertTrue(a2m1 != a2m4 && a2m4 != a2m5 && a2m1 != a2m5, "shared canonical bin -> distinct ids");
        assertEq(hook.positions(a2m1).maker, m1);
        assertEq(hook.positions(a2m4).maker, m4);
        assertEq(hook.positions(a2m5).maker, m5);

        // Warp past the short TTL but within the long one: only m2/m3/m5 bins are retirable.
        vm.warp(block.timestamp + ttlShort + 1);

        // A single-retire on a still-fresh long-TTL bin reverts.
        bytes32 freshId = hook.makerPositionAt(testPoolId, m1, 0);
        vm.expectRevert(NativeBookHook.PositionNotRetirable.selector);
        hook.retirePosition(testPoolKey, freshId);

        // A keeper batch over ALL ids retires only the six expired bins and skips the eight fresh ones.
        bytes32[] memory all = _allActiveIds();
        assertEq(hook.retirePositions(testPoolKey, all, all.length), 6, "only the short-TTL makers' bins retired");
        assertEq(hook.makerPositionCount(testPoolId, m2), 0, "m2 expired out");
        assertEq(hook.makerPositionCount(testPoolId, m3), 0, "m3 expired out");
        assertEq(hook.makerPositionCount(testPoolId, m5), 0, "m5 expired out");
        assertEq(hook.makerPositionCount(testPoolId, m1), 4, "m1 (long TTL) untouched");
        assertEq(hook.makerPositionCount(testPoolId, m4), 4, "m4 (long TTL) untouched");
        _assertCustody(makers);

        // The expired makers were never crossed, so they are refunded their full un-filled inventory.
        assertApproxEqAbs(hook.inventoryBalance(m2, currency0), 500_000 ether, 0.01 ether, "m2 currency0 returned");
        assertApproxEqAbs(hook.inventoryBalance(m3, currency1), 500_000 ether, 0.01 ether, "m3 currency1 returned");
        assertApproxEqAbs(hook.inventoryBalance(m5, currency0), 500_000 ether, 0.01 ether, "m5 currency0 returned");

        // Warp past the long TTL; two swaps opportunistically sweep m1/m4's eight now-expired bins,
        // each sweep bounded to maxRetirePerSwap.
        vm.warp(block.timestamp + ttlLong + 1);
        uint256 beforeSweep = hook.activePositionCount(testPoolId);
        assertEq(beforeSweep, 8, "only the two long-TTL ladders remain");
        swap(testPoolKey, true, -1 ether, "");
        assertLe(beforeSweep - hook.activePositionCount(testPoolId), 4, "first sweep bounded by maxRetirePerSwap");
        swap(testPoolKey, true, -1 ether, "");
        assertEq(hook.activePositionCount(testPoolId), 0, "all expired bins swept over two swaps");
        _assertCustody(makers);
    }

    // ─────────────────────────── scenario helpers ───────────────────────────

    /// @dev A single-bin capacity.
    function _cap(int8 offset, uint128 amount) internal pure returns (BinCapacity memory) {
        return BinCapacity({offset: offset, amount: amount});
    }

    function _bins0() internal pure returns (BinCapacity[] memory arr) {
        arr = new BinCapacity[](0);
    }

    function _bins2(BinCapacity memory a, BinCapacity memory b) internal pure returns (BinCapacity[] memory arr) {
        arr = new BinCapacity[](2);
        arr[0] = a;
        arr[1] = b;
    }

    /// @dev The hook's ERC-20 balance of a currency (its total maker custody).
    function _custody(Currency c) internal view returns (uint256) {
        return MockERC20(Currency.unwrap(c)).balanceOf(address(hook));
    }

    /// @dev Every token the hook custodies must be attributed to exactly one maker's inventory (the
    ///      rest is locked in live positions, outside both sides of this equality). Summed over all
    ///      `makers`, so it catches value credited to the wrong maker anywhere in the set.
    function _assertCustody(address[] memory makers) internal view {
        uint256 inv0;
        uint256 inv1;
        for (uint256 i; i < makers.length; ++i) {
            inv0 += hook.inventoryBalance(makers[i], currency0);
            inv1 += hook.inventoryBalance(makers[i], currency1);
        }
        assertEq(_custody(currency0), inv0, "token0 custody != sum(maker inventory)");
        assertEq(_custody(currency1), inv1, "token1 custody != sum(maker inventory)");
    }

    /// @dev The scenario maker set: `maker` and `maker2` (funded in setUp, and the only two with
    ///      signing keys) plus three fresh makers funded here.
    function _fiveMakers() internal returns (address[] memory makers) {
        address m3 = makeAddr("maker3");
        address m4 = makeAddr("maker4");
        address m5 = makeAddr("maker5");
        _fundAndApproveMaker(m3);
        _fundAndApproveMaker(m4);
        _fundAndApproveMaker(m5);
        makers = new address[](5);
        makers[0] = maker;
        makers[1] = maker2;
        makers[2] = m3;
        makers[3] = m4;
        makers[4] = m5;
    }

    /// @dev Post `who`'s ladder through the relayer with an EIP-712 signature (`pk` is `who`'s key).
    function _postSig(address who, uint256 pk, BinCapacity[] memory bids, BinCapacity[] memory asks, uint40 ttl)
        internal
    {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signReplaceLadder(pk, who, bids, asks, ttl, deadline);
        vm.prank(relayer);
        hook.replaceLadderWithSig(testPoolKey, who, bids, asks, ttl, 0, 0, deadline, sig);
    }

    /// @dev Keeper-retire every currently-retirable position of `who`; returns how many were retired.
    function _retireCrossed(address who) internal returns (uint256 n) {
        bytes32[] memory ids = _crossedOrExpiredIds(who);
        n = ids.length;
        if (n > 0) hook.retirePositions(testPoolKey, ids, n);
    }

    /// @dev Sum of every maker's inventory in `c`.
    function _sumInv(address[] memory makers, Currency c) internal view returns (uint256 total) {
        for (uint256 i; i < makers.length; ++i) {
            total += hook.inventoryBalance(makers[i], c);
        }
    }

    /// @dev Snapshot every maker's inventory in `c`, index-aligned with `makers`.
    function _snap(address[] memory makers, Currency c) internal view returns (uint256[] memory s) {
        s = new uint256[](makers.length);
        for (uint256 i; i < makers.length; ++i) {
            s[i] = hook.inventoryBalance(makers[i], c);
        }
    }

    /// @dev The deterministic position id for `who`'s bin, matching `BookPositions.positionId`.
    function _pid(address who, Side side, int24 tickLower) internal view returns (bytes32) {
        return keccak256(abi.encode(testPoolId, who, side, tickLower));
    }

    /// @dev Assert `who` owns exactly `expectedCount` active positions and each is attributed to it.
    function _assertOwnedBy(address who, uint256 expectedCount) internal view {
        assertEq(hook.makerPositionCount(testPoolId, who), expectedCount, "unexpected maker position count");
        for (uint256 i; i < expectedCount; ++i) {
            PositionInfo memory p = hook.positions(hook.makerPositionAt(testPoolId, who, i));
            assertEq(p.maker, who, "position attributed to wrong maker");
            assertEq(PoolId.unwrap(p.poolId), PoolId.unwrap(testPoolId), "position on wrong pool");
            assertTrue(p.active, "position not active");
        }
    }

    /// @dev Snapshot the ids of `who`'s positions that are currently retirable (expired or crossed),
    ///      mirroring the hook's own `isRetirable` predicate. Snapshotting up front is required
    ///      because retirement swap-pops the maker index and shifts later indices.
    function _crossedOrExpiredIds(address who) internal view returns (bytes32[] memory ids) {
        (, int24 tick,,) = manager.getSlot0(testPoolId);
        uint256 n = hook.makerPositionCount(testPoolId, who);
        bytes32[] memory tmp = new bytes32[](n);
        uint256 c;
        for (uint256 i; i < n; ++i) {
            bytes32 id = hook.makerPositionAt(testPoolId, who, i);
            PositionInfo memory p = hook.positions(id);
            bool expired = block.timestamp >= p.expiry;
            bool crossed = p.side == Side.Ask ? tick >= p.tickUpper : tick < p.tickLower;
            if (expired || crossed) tmp[c++] = id;
        }
        ids = new bytes32[](c);
        for (uint256 i; i < c; ++i) {
            ids[i] = tmp[i];
        }
    }

    /// @dev Snapshot every active position id in the pool.
    function _allActiveIds() internal view returns (bytes32[] memory ids) {
        uint256 n = hook.activePositionCount(testPoolId);
        ids = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = hook.activePositionAt(testPoolId, i);
        }
    }

    /// @dev Drive the price to `targetTick` with a price-limited exact-input swap. The large input
    ///      is a ceiling; the swap consumes only what is needed to reach the limit.
    function _swapToTick(bool zeroForOne, int24 targetTick) internal returns (BalanceDelta) {
        return swapRouter.swap(
            testPoolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -100_000 ether,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(targetTick)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _assertQuoteMatchesSwap(bool zeroForOne, int256 amountSpecified) internal {
        uint256 quoted = hook.getIndicativeQuote(testPoolKey, zeroForOne, amountSpecified, "");
        assertGt(quoted, 0);

        BalanceDelta delta = swap(testPoolKey, zeroForOne, amountSpecified, "");
        uint256 actual;
        if (amountSpecified < 0) {
            actual = zeroForOne ? uint256(int256(delta.amount1())) : uint256(int256(delta.amount0()));
        } else {
            actual = zeroForOne ? uint256(-int256(delta.amount0())) : uint256(-int256(delta.amount1()));
        }

        assertApproxEqAbs(quoted, actual, 1);
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

    function _seedPassiveLiquidity() internal {
        modifyLiquidityRouter.modifyLiquidity(
            testPoolKey,
            ModifyLiquidityParams({
                tickLower: -10 * BIN_SPACING, tickUpper: 10 * BIN_SPACING, liquidityDelta: 100 ether, salt: 0
            }),
            ""
        );
    }

    function _fundAndApproveMaker(address account) internal {
        token0.transfer(account, 1_000_000 ether);
        token1.transfer(account, 1_000_000 ether);
        vm.startPrank(account);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        hook.deposit(currency0, 500_000 ether);
        hook.deposit(currency1, 500_000 ether);
        vm.stopPrank();
    }

    function _expectHookWrappedError(bytes4 hookSelector, bytes4 reasonSelector) internal {
        _expectHookWrappedError(hookSelector, abi.encodeWithSelector(reasonSelector));
    }

    function _signReplaceLadder(
        uint256 privateKey,
        address maker_,
        BinCapacity[] memory bids,
        BinCapacity[] memory asks,
        uint40 ttl,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _signReplaceLadder(privateKey, maker_, bids, asks, ttl, 0, 0, deadline);
    }

    function _signReplaceLadder(
        uint256 privateKey,
        address maker_,
        BinCapacity[] memory bids,
        BinCapacity[] memory asks,
        uint40 ttl,
        int24 expectedRefTick,
        uint24 maxTickDeviation,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 digest = hook.hashReplaceLadder(
            testPoolKey, maker_, bids, asks, ttl, expectedRefTick, maxTickDeviation, hook.nonces(maker_), deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signCancelLadder(uint256 privateKey, address maker_, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = hook.hashCancelLadder(testPoolKey, maker_, hook.nonces(maker_), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _expectHookWrappedError(bytes4 hookSelector, bytes memory reason) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                hookSelector,
                reason,
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function _readPosition(bytes32 positionId)
        internal
        view
        returns (
            address maker_,
            PoolId poolId,
            Side side,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint40 expiry,
            bool active,
            bool dummy
        )
    {
        PositionInfo memory p = hook.positions(positionId);
        (maker_, poolId, side, tickLower, tickUpper, liquidity, expiry, active) =
        (p.maker, p.poolId, p.side, p.tickLower, p.tickUpper, p.liquidity, p.expiry, p.active);
        dummy = false;
    }
}
