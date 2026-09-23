// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StableFeeConfigurationImplementation} from "./base/StableFeeConfigurationImplementation.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {
    StableFeeConfig,
    StableFeeState,
    IStableFeeConfiguration
} from "../../src/stable/interfaces/IStableFeeConfiguration.sol";
import {StableFeeCalculation} from "../../src/stable/libraries/StableFeeCalculation.sol";
import {IDynamicFeeHook} from "../../src/interfaces/IDynamicFeeHook.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {StablePairTestBase} from "./base/StablePairTestBase.sol";

/// forge-config: default.fuzz.runs = 2048
contract StableFeeConfigurationImplementationTest is StablePairTestBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    event FeeConfigUpdated(PoolId indexed poolId, StableFeeConfig feeConfig);

    StableFeeConfigurationImplementation public feeConfigurationImplementation;

    address poolFeeController = makeAddr("poolFeeController");

    PoolId internal secondPoolId = PoolId.wrap(keccak256("second pool"));

    /// @notice The canonical valid params; tests mutate single fields to probe the validator.
    function _validParams() internal pure returns (StableFeeConfig memory) {
        return StableFeeConfig({
            k: K,
            optimalFeeE6: OPTIMAL_FEE_E6,
            targetMultiplier: TARGET_MULTIPLIER,
            referenceSqrtPriceX96: REFERENCE_SQRT_PRICE_X96
        });
    }

    /// @notice The baseline config seeded in setUp; differs from _validParams so updates are observable.
    function _seedParams() internal pure returns (StableFeeConfig memory) {
        StableFeeConfig memory params = _validParams();
        params.optimalFeeE6 = OPTIMAL_FEE_E6 / 2;
        return params;
    }

    function setUp() public override {
        // This suite exercises only config logic.
        feeConfigurationImplementation = new StableFeeConfigurationImplementation(poolFeeController);

        testPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TickMath.MIN_TICK_SPACING,
            hooks: IHooks(address(feeConfigurationImplementation))
        });

        // updateFeeConfig only updates existing config, so seed the pools this suite exercises
        // (mirrors the hook's initializePool seeding path)
        feeConfigurationImplementation.initializeFeeConfig(testPoolKey.toId(), _seedParams());
        feeConfigurationImplementation.initializeFeeConfig(secondPoolId, _seedParams());
    }

    /// @notice updateFeeConfig cannot create first-time config: a pool with no stored config was
    ///         never initialized through the hook (wrong hook, wrong id, or not created yet).
    function test_updateFeeConfig_revertsForUninitializedPool() public {
        PoolId unknown = PoolId.wrap(keccak256("never initialized"));
        vm.prank(poolFeeController);
        vm.expectRevert(abi.encodeWithSelector(IDynamicFeeHook.PoolNotInitialized.selector, unknown));
        feeConfigurationImplementation.updateFeeConfig(unknown, _validParams());
    }

    /// @notice batchUpdateFeeConfig applies the same guard per element and reverts the whole batch.
    function test_batchUpdateFeeConfig_revertsForUninitializedPool() public {
        PoolId unknown = PoolId.wrap(keccak256("never initialized"));
        PoolId[] memory poolIds = new PoolId[](2);
        poolIds[0] = testPoolKey.toId();
        poolIds[1] = unknown;
        StableFeeConfig[] memory feeParams = new StableFeeConfig[](2);
        feeParams[0] = _validParams();
        feeParams[1] = _validParams();

        vm.prank(poolFeeController);
        vm.expectRevert(abi.encodeWithSelector(IDynamicFeeHook.PoolNotInitialized.selector, unknown));
        feeConfigurationImplementation.batchUpdateFeeConfig(poolIds, feeParams);

        // The whole batch reverted: the first (known) pool kept its seeded baseline
        (, uint24 optimalFeeE6,,) = feeConfigurationImplementation.feeConfig(poolIds[0]);
        assertEq(optimalFeeE6, _seedParams().optimalFeeE6);
    }

    function test_updateFeeConfig_revertsWithNotConfigManager() public {
        StableFeeConfig memory newParams = _validParams();
        bytes32 role = feeConfigurationImplementation.CONFIG_MANAGER_ROLE();

        vm.prank(address(this));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), role)
        );
        feeConfigurationImplementation.updateFeeConfig(testPoolKey.toId(), newParams);
    }

    function test_updateFeeConfig_revertsWithInvalidReferenceSqrtPriceX96_belowMin() public {
        StableFeeConfig memory newParams = _validParams();
        newParams.referenceSqrtPriceX96 = TickMath.MIN_SQRT_PRICE - 1;

        vm.prank(poolFeeController);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStableFeeConfiguration.InvalidReferenceSqrtPriceX96.selector, TickMath.MIN_SQRT_PRICE - 1
            )
        );
        feeConfigurationImplementation.updateFeeConfig(testPoolKey.toId(), newParams);
    }

    function test_updateFeeConfig_revertsWithInvalidReferenceSqrtPriceX96_atMin() public {
        // MIN_SQRT_PRICE is now invalid because the optimal range would extend below it
        // minBoundedRef = MIN_SQRT_PRICE * 1e6 / sqrt((1e6 - MAX_OPTIMAL_FEE_E6) * 1e6)
        // = MIN_SQRT_PRICE * 1e6 / sqrt(990000 * 1e6) > MIN_SQRT_PRICE
        StableFeeConfig memory newParams = _validParams();
        newParams.referenceSqrtPriceX96 = TickMath.MIN_SQRT_PRICE;

        vm.prank(poolFeeController);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStableFeeConfiguration.InvalidReferenceSqrtPriceX96.selector, TickMath.MIN_SQRT_PRICE
            )
        );
        feeConfigurationImplementation.updateFeeConfig(testPoolKey.toId(), newParams);
    }

    function test_updateFeeConfig_revertsWithInvalidReferenceSqrtPriceX96_atMax() public {
        // MAX_SQRT_PRICE - 1 is now invalid because the optimal range would extend above MAX_SQRT_PRICE
        // maxBoundedRef = MAX_SQRT_PRICE * sqrt((1e6 - MAX_OPTIMAL_FEE_E6) * 1e6) / 1e6
        // = MAX_SQRT_PRICE * sqrt(990000 * 1e6) / 1e6 < MAX_SQRT_PRICE
        StableFeeConfig memory newParams = _validParams();
        newParams.referenceSqrtPriceX96 = TickMath.MAX_SQRT_PRICE - 1;

        vm.prank(poolFeeController);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStableFeeConfiguration.InvalidReferenceSqrtPriceX96.selector, TickMath.MAX_SQRT_PRICE - 1
            )
        );
        feeConfigurationImplementation.updateFeeConfig(testPoolKey.toId(), newParams);
    }

    function test_updateFeeConfig_succeedsWithBoundedReferencePrices() public {
        // Shared derivation (same formula as the validator); see referenceBounds in
        (uint256 minBoundedRef, uint256 maxBoundedRef) =
            referenceBounds(feeConfigurationImplementation.MAX_OPTIMAL_FEE_E6());

        // Test minimum bounded reference price (inclusive - MIN_SQRT_PRICE is valid in v4)
        StableFeeConfig memory minParams = _validParams();
        minParams.referenceSqrtPriceX96 = uint160(minBoundedRef);
        vm.prank(poolFeeController);
        feeConfigurationImplementation.updateFeeConfig(testPoolKey.toId(), minParams);

        // Test maximum bounded reference price - 1 (exclusive - MAX_SQRT_PRICE is invalid in v4)
        // maxBoundedRef itself is invalid, so we use maxBoundedRef - 1
        StableFeeConfig memory maxParams = _validParams();
        maxParams.referenceSqrtPriceX96 = uint160(maxBoundedRef - 1);
        vm.prank(poolFeeController);
        feeConfigurationImplementation.updateFeeConfig(testPoolKey.toId(), maxParams);

        // The semantic property behind the bounds: at either extreme, the widest optimal range
        // (at MAX_OPTIMAL_FEE_E6) must still fit inside v4's sqrt-price limits.
        uint256 oneMinusMaxFee = StableFeeCalculation.ONE_E6 - feeConfigurationImplementation.MAX_OPTIMAL_FEE_E6();
        uint256 sqrtOneMinusMaxFeeE6 = FixedPointMathLib.sqrt(oneMinusMaxFee * StableFeeCalculation.ONE_E6);

        // At minBoundedRef: lowerOptimal = minBoundedRef * sqrt(1 - maxOptimalFee) >= MIN_SQRT_PRICE
        uint256 lowerOptimalAtMin = minBoundedRef * sqrtOneMinusMaxFeeE6 / StableFeeCalculation.ONE_E6;
        assertGe(lowerOptimalAtMin, TickMath.MIN_SQRT_PRICE);

        // At maxBoundedRef - 1: upperOptimal = (maxBoundedRef - 1) / sqrt(1 - maxOptimalFee) < MAX_SQRT_PRICE
        uint256 upperOptimalAtMax = (maxBoundedRef - 1) * StableFeeCalculation.ONE_E6 / sqrtOneMinusMaxFeeE6;
        assertLt(upperOptimalAtMax, TickMath.MAX_SQRT_PRICE);
    }

    function test_updateFeeConfig_revertsWithInvalidReferenceSqrtPriceX96_atMaxBounded() public {
        // maxBoundedRef is exactly at the exclusive boundary, so it should fail
        (, uint256 maxBoundedRef) = referenceBounds(feeConfigurationImplementation.MAX_OPTIMAL_FEE_E6());

        StableFeeConfig memory newParams = _validParams();
        newParams.referenceSqrtPriceX96 = uint160(maxBoundedRef);

        vm.prank(poolFeeController);
        vm.expectRevert(
            abi.encodeWithSelector(IStableFeeConfiguration.InvalidReferenceSqrtPriceX96.selector, maxBoundedRef)
        );
        feeConfigurationImplementation.updateFeeConfig(testPoolKey.toId(), newParams);
    }

    function test_updateFeeConfig_revertsWithInvalidTargetMultiplier_above100() public {
        StableFeeConfig memory newParams = _validParams();
        newParams.targetMultiplier = 101;

        vm.prank(poolFeeController);
        vm.expectRevert(abi.encodeWithSelector(IStableFeeConfiguration.InvalidTargetMultiplier.selector, 101));
        feeConfigurationImplementation.updateFeeConfig(testPoolKey.toId(), newParams);
    }

    /// @notice Fuzz the targetMultiplier validator over the full uint8 domain: values up to
    /// MAX_TARGET_MULTIPLIER (100) are stored verbatim, anything above reverts.
    function test_fuzz_updateFeeConfig_targetMultiplier(uint8 targetMultiplier) public {
        StableFeeConfig memory newParams = _validParams();
        newParams.targetMultiplier = targetMultiplier;
        uint256 maxTargetMultiplier = feeConfigurationImplementation.MAX_TARGET_MULTIPLIER();

        vm.prank(poolFeeController);
        if (targetMultiplier > maxTargetMultiplier) {
            vm.expectRevert(
                abi.encodeWithSelector(IStableFeeConfiguration.InvalidTargetMultiplier.selector, targetMultiplier)
            );
            feeConfigurationImplementation.updateFeeConfig(testPoolKey.toId(), newParams);
        } else {
            feeConfigurationImplementation.updateFeeConfig(testPoolKey.toId(), newParams);
            (,, uint8 storedTargetMultiplier,) = feeConfigurationImplementation.feeConfig(testPoolKey.toId());
            assertEq(storedTargetMultiplier, targetMultiplier);
        }
    }

    function test_updateFeeConfig_revertsWithInvalidOptimalFeeE6() public {
        uint24 justAboveMax = uint24(feeConfigurationImplementation.MAX_OPTIMAL_FEE_E6() + 1);
        StableFeeConfig memory newParams = _validParams();
        newParams.optimalFeeE6 = justAboveMax;

        vm.prank(poolFeeController);
        vm.expectRevert(abi.encodeWithSelector(IStableFeeConfiguration.InvalidOptimalFeeE6.selector, justAboveMax));
        feeConfigurationImplementation.updateFeeConfig(testPoolKey.toId(), newParams);
    }

    function test_updateFeeConfig_revertsWithInvalidK_zero() public {
        StableFeeConfig memory newParams = _validParams();
        newParams.k = 0;

        vm.prank(poolFeeController);
        vm.expectRevert(abi.encodeWithSelector(IStableFeeConfiguration.InvalidK.selector, 0));
        feeConfigurationImplementation.updateFeeConfig(testPoolKey.toId(), newParams);
    }

    function test_updateFeeConfig_acceptsKMaxUint24() public {
        // uint24 max = 2^24 - 1 = 16_777_215, just below Q24 (1.0 in Q24 format), the slowest
        // representable decay. Stored verbatim; the slow path derives logK from k on the fly —
        // see StableFeeCalculation.t.sol for the derivation's worst-bucket quantization coverage.
        uint24 maxK = type(uint24).max;
        StableFeeConfig memory newParams = _validParams();
        newParams.k = maxK;

        vm.prank(poolFeeController);
        feeConfigurationImplementation.updateFeeConfig(testPoolKey.toId(), newParams);

        (uint256 k,,,) = feeConfigurationImplementation.feeConfig(testPoolKey.toId());
        assertEq(k, maxK);
    }

    function test_updateFeeConfig_succeeds() public {
        // Baseline from setUp seeding, distinguishable from the update applied below
        (uint256 k, uint24 optimalFeeE6, uint8 targetMultiplier, uint160 referenceSqrtPriceX96) =
            feeConfigurationImplementation.feeConfig(testPoolKey.toId());
        assertEq(optimalFeeE6, _seedParams().optimalFeeE6);

        StableFeeConfig memory newParams = _validParams();

        // Roll forward so the fee-state reset below is observable against setUp's block number
        vm.roll(vm.getBlockNumber() + 1);
        vm.expectEmit(true, false, false, true);
        emit FeeConfigUpdated(testPoolKey.toId(), newParams);
        vm.prank(poolFeeController);
        feeConfigurationImplementation.updateFeeConfig(testPoolKey.toId(), newParams);

        // Verify StableFeeConfig was updated
        (k, optimalFeeE6, targetMultiplier, referenceSqrtPriceX96) =
            feeConfigurationImplementation.feeConfig(testPoolKey.toId());
        assertEq(k, K);
        assertEq(optimalFeeE6, OPTIMAL_FEE_E6);
        assertEq(targetMultiplier, TARGET_MULTIPLIER);
        assertEq(referenceSqrtPriceX96, REFERENCE_SQRT_PRICE_X96);

        // Verify StableFeeState was reset
        (uint256 decayingFeeE12, uint160 sqrtAmmPriceX96, uint256 blockNumber) =
            feeConfigurationImplementation.feeState(testPoolKey.toId());
        assertEq(decayingFeeE12, StableFeeCalculation.UNDEFINED_DECAYING_FEE_E12);
        assertEq(sqrtAmmPriceX96, 0);
        assertEq(blockNumber, block.number);
    }

    function test_updateFeeConfig_resetsFeeStateWithExistingSwapHistory() public {
        // Set up valid fee config
        StableFeeConfig memory newParams = _validParams();
        vm.prank(poolFeeController);
        feeConfigurationImplementation.updateFeeConfig(testPoolKey.toId(), newParams);

        // Simulate existing swap history with non-default feeState
        feeConfigurationImplementation.setFeeState(
            testPoolKey.toId(),
            StableFeeState({
                decayingFeeE12: 500_000, sqrtAmmPriceX96: uint160(2 ** 96 + 1000), blockNumber: uint40(block.number)
            })
        );

        // Verify non-default state is set
        (uint256 decayingFeeE12, uint160 sqrtAmmPriceX96, uint256 blockNumber) =
            feeConfigurationImplementation.feeState(testPoolKey.toId());
        assertEq(decayingFeeE12, 500_000);
        assertEq(sqrtAmmPriceX96, uint160(2 ** 96 + 1000));

        // Update fee config again - should reset fee state
        vm.roll(vm.getBlockNumber() + 100);
        vm.prank(poolFeeController);
        feeConfigurationImplementation.updateFeeConfig(testPoolKey.toId(), newParams);

        // Verify feeState was reset
        (decayingFeeE12, sqrtAmmPriceX96, blockNumber) = feeConfigurationImplementation.feeState(testPoolKey.toId());
        assertEq(decayingFeeE12, StableFeeCalculation.UNDEFINED_DECAYING_FEE_E12);
        assertEq(sqrtAmmPriceX96, 0);
        assertEq(blockNumber, block.number);
    }

    function test_updateFeeConfig_gas() public {
        StableFeeConfig memory newParams = _validParams();

        vm.prank(poolFeeController);
        feeConfigurationImplementation.updateFeeConfig(testPoolKey.toId(), newParams);
        vm.snapshotGasLastCall("updateFeeConfig");
    }

    function test_batchUpdateFeeConfig_revertsWithNotConfigManager() public {
        (PoolId[] memory poolIds, StableFeeConfig[] memory feeParams) = _batchOfTwo();
        bytes32 role = feeConfigurationImplementation.CONFIG_MANAGER_ROLE();

        vm.prank(address(this));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), role)
        );
        feeConfigurationImplementation.batchUpdateFeeConfig(poolIds, feeParams);
    }

    function test_batchUpdateFeeConfig_revertsWithLengthMismatch() public {
        (PoolId[] memory poolIds, StableFeeConfig[] memory feeParams) = _batchOfTwo();
        PoolId[] memory shortPoolIds = new PoolId[](1);
        shortPoolIds[0] = poolIds[0];

        vm.prank(poolFeeController);
        vm.expectRevert(IStableFeeConfiguration.LengthMismatch.selector);
        feeConfigurationImplementation.batchUpdateFeeConfig(shortPoolIds, feeParams);
    }

    function test_batchUpdateFeeConfig_succeeds() public {
        (PoolId[] memory poolIds, StableFeeConfig[] memory feeParams) = _batchOfTwo();

        vm.expectEmit(true, false, false, true);
        emit FeeConfigUpdated(poolIds[0], feeParams[0]);
        vm.expectEmit(true, false, false, true);
        emit FeeConfigUpdated(poolIds[1], feeParams[1]);
        vm.prank(poolFeeController);
        feeConfigurationImplementation.batchUpdateFeeConfig(poolIds, feeParams);

        for (uint256 i = 0; i < poolIds.length; i++) {
            (uint256 k, uint24 optimalFeeE6, uint8 targetMultiplier, uint160 referenceSqrtPriceX96) =
                feeConfigurationImplementation.feeConfig(poolIds[i]);
            assertEq(k, feeParams[i].k);
            assertEq(optimalFeeE6, feeParams[i].optimalFeeE6);
            assertEq(targetMultiplier, feeParams[i].targetMultiplier);
            assertEq(referenceSqrtPriceX96, feeParams[i].referenceSqrtPriceX96);

            (uint256 decayingFeeE12, uint160 sqrtAmmPriceX96, uint256 blockNumber) =
                feeConfigurationImplementation.feeState(poolIds[i]);
            assertEq(decayingFeeE12, StableFeeCalculation.UNDEFINED_DECAYING_FEE_E12);
            assertEq(sqrtAmmPriceX96, 0);
            assertEq(blockNumber, block.number);
        }
    }

    function test_batchUpdateFeeConfig_revertsWhenOneConfigInvalid() public {
        (PoolId[] memory poolIds, StableFeeConfig[] memory feeParams) = _batchOfTwo();
        feeParams[1].targetMultiplier = 101;

        vm.prank(poolFeeController);
        vm.expectRevert(abi.encodeWithSelector(IStableFeeConfiguration.InvalidTargetMultiplier.selector, 101));
        feeConfigurationImplementation.batchUpdateFeeConfig(poolIds, feeParams);

        // The whole batch reverted: the first (valid) config kept its seeded baseline
        (, uint24 optimalFeeE6,,) = feeConfigurationImplementation.feeConfig(poolIds[0]);
        assertEq(optimalFeeE6, _seedParams().optimalFeeE6);
    }

    function test_batchUpdateFeeConfig_gas() public {
        (PoolId[] memory poolIds, StableFeeConfig[] memory feeParams) = _batchOfTwo();

        vm.prank(poolFeeController);
        feeConfigurationImplementation.batchUpdateFeeConfig(poolIds, feeParams);
        vm.snapshotGasLastCall("batchUpdateFeeConfig");
    }

    function test_batchUpdateFeeConfig_emptyArraysSucceeds() public {
        vm.prank(poolFeeController);
        feeConfigurationImplementation.batchUpdateFeeConfig(new PoolId[](0), new StableFeeConfig[](0));
    }

    /// @notice Builds a two-pool batch with distinct valid params
    function _batchOfTwo() internal view returns (PoolId[] memory poolIds, StableFeeConfig[] memory feeParams) {
        poolIds = new PoolId[](2);
        poolIds[0] = testPoolKey.toId();
        poolIds[1] = secondPoolId;

        feeParams = new StableFeeConfig[](2);
        feeParams[0] = _validParams();
        feeParams[1] = _validParams();
        feeParams[1].optimalFeeE6 = OPTIMAL_FEE_E6 / 2;
        feeParams[1].targetMultiplier = 75;
    }

    /// @notice Roles are no longer self-rotating: the config manager can renounce its own role
    ///         (standard OZ AccessControl), which disables further updates. There is no admin
    ///         wired into this harness (it only grants CONFIG_MANAGER_ROLE at construction), so
    ///         re-granting/rotation is covered by the hook-level suites, not this harness.
    function test_configManager_renounceRole_disablesFurtherUpdates() public {
        bytes32 configManagerRole = feeConfigurationImplementation.CONFIG_MANAGER_ROLE();
        assertTrue(feeConfigurationImplementation.hasRole(configManagerRole, poolFeeController));

        vm.prank(poolFeeController);
        feeConfigurationImplementation.renounceRole(configManagerRole, poolFeeController);
        assertFalse(feeConfigurationImplementation.hasRole(configManagerRole, poolFeeController));

        StableFeeConfig memory newParams = _validParams();
        vm.prank(poolFeeController);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, poolFeeController, configManagerRole
            )
        );
        feeConfigurationImplementation.updateFeeConfig(testPoolKey.toId(), newParams);
    }
}
