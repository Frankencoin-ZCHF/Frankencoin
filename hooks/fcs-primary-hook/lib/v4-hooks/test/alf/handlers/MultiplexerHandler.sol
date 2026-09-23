// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {MultiplexerHookData, TargetedQuoter} from "../../../src/alf/types/MultiplexerTypes.sol";

/// @title MultiplexerHandler
/// @notice Invariant-test handler for `ALFMultiplexer`. Routes swaps through the virtual pool
///         (autonomous split fill across two live candidate quoters) and also swaps the candidate
///         pools directly to drift their prices, so the routing/split-fill logic is exercised over
///         a moving candidate landscape. All calls soft-fail (`fail_on_revert = false`): a swap can
///         legitimately revert with `NoValidQuotes` / `InsufficientLiquidity` as candidates drift.
contract MultiplexerHandler is Test {
    PoolSwapTest public immutable swapRouter;
    PoolKey public muxKey;
    PoolKey public quoterAKey;
    PoolKey public quoterBKey;
    MockERC20 public token0;
    MockERC20 public token1;
    address[] public actors;

    uint256 public ghost_muxSwapCalls;
    uint256 public ghost_candidateSwapCalls;

    constructor(
        PoolSwapTest _swapRouter,
        PoolKey memory _muxKey,
        PoolKey memory _quoterAKey,
        PoolKey memory _quoterBKey,
        MockERC20 _token0,
        MockERC20 _token1,
        address[] memory _actors
    ) {
        swapRouter = _swapRouter;
        muxKey = _muxKey;
        quoterAKey = _quoterAKey;
        quoterBKey = _quoterBKey;
        token0 = _token0;
        token1 = _token1;
        for (uint256 i; i < _actors.length; i++) {
            actors.push(_actors[i]);
        }
    }

    function _pickActor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function _prep(address actor) internal {
        token0.mint(actor, 1e22);
        token1.mint(actor, 1e22);
        vm.startPrank(actor);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _bothTargets() internal view returns (bytes memory) {
        TargetedQuoter[] memory targets = new TargetedQuoter[](2);
        targets[0] = TargetedQuoter({poolKey: quoterAKey, amountSpecified: 0});
        targets[1] = TargetedQuoter({poolKey: quoterBKey, amountSpecified: 0});
        return abi.encode(MultiplexerHookData({attestationData: "", targets: targets, strictTolerancePips: 0}));
    }

    /// @notice Route a swap through the multiplexer's virtual pool (autonomous split fill).
    function swapThroughMultiplexer(uint256 actorSeed, uint256 dirSeed, int256 amountSeed) external {
        ghost_muxSwapCalls++;
        address actor = _pickActor(actorSeed);
        _prep(actor);

        bool zeroForOne = (dirSeed % 2 == 0);
        int256 amount = amountSeed;
        if (amount == 0) amount = -1e17;
        if (amount > 5e18) amount = 5e18;
        if (amount < -5e18) amount = -5e18;

        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        vm.prank(actor);
        try swapRouter.swap(
            muxKey,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amount, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            _bothTargets()
        ) returns (
            BalanceDelta
        ) {}
            catch {}
    }

    /// @notice Swap a candidate quoter pool directly to drift its price, changing the multiplexer's
    ///         subsequent routing decisions and split ratios.
    function swapCandidate(uint256 actorSeed, uint256 whichSeed, uint256 dirSeed, int256 amountSeed) external {
        ghost_candidateSwapCalls++;
        address actor = _pickActor(actorSeed);
        _prep(actor);

        PoolKey memory k = (whichSeed % 2 == 0) ? quoterAKey : quoterBKey;
        bool zeroForOne = (dirSeed % 2 == 0);
        int256 amount = amountSeed;
        if (amount == 0) amount = -1e17;
        if (amount > 2e18) amount = 2e18;
        if (amount < -2e18) amount = -2e18;

        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        vm.prank(actor);
        try swapRouter.swap(
            k,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amount, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) returns (
            BalanceDelta
        ) {}
            catch {}
    }
}
