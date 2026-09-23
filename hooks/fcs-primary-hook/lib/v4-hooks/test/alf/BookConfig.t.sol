// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {
    BookConfig,
    PoolConfig,
    InvalidPoolConfig,
    MIN_BINS_PER_SIDE,
    MAX_BINS_PER_SIDE,
    MAX_MAKER_BINS,
    MAX_RETIRE_PER_SWAP
} from "../../src/alf/types/BookConfig.sol";

/// @notice Isolated coverage for the `BookConfig` capability type: bounds validation on `set`
///         and storage roundtrip through `get`. Revert paths route through external self-calls
///         so `vm.expectRevert` sees a call frame (and `set` takes calldata).
contract BookConfigTest is Test {
    BookConfig internal config;

    PoolId internal poolId = PoolId.wrap(keccak256("pool"));
    int24 internal constant TICK_SPACING = 10;

    function extSet(PoolId id, int24 tickSpacing, PoolConfig calldata c) external {
        config.set(id, tickSpacing, c);
    }

    function _validConfig() internal pure returns (PoolConfig memory) {
        return PoolConfig({
            binSpacingTicks: 60,
            binsPerSide: 8,
            maxMakerBins: 16,
            maxRetirePerSwap: 4,
            maxQuoteTtl: 300,
            minBinLiquidity: 1e6
        });
    }

    function test_set_roundtrip() public {
        PoolConfig memory c = _validConfig();
        this.extSet(poolId, TICK_SPACING, c);

        PoolConfig memory stored = config.get(poolId);
        assertEq(stored.binSpacingTicks, c.binSpacingTicks);
        assertEq(stored.binsPerSide, c.binsPerSide);
        assertEq(stored.maxMakerBins, c.maxMakerBins);
        assertEq(stored.maxRetirePerSwap, c.maxRetirePerSwap);
        assertEq(stored.maxQuoteTtl, c.maxQuoteTtl);
        assertEq(stored.minBinLiquidity, c.minBinLiquidity);
    }

    function test_get_unsetPool_returnsZeroConfig() public view {
        PoolConfig memory stored = config.get(PoolId.wrap(keccak256("never-set")));
        assertEq(stored.binSpacingTicks, 0);
    }

    function test_set_zeroBinSpacing_reverts() public {
        PoolConfig memory c = _validConfig();
        c.binSpacingTicks = 0;
        vm.expectRevert(InvalidPoolConfig.selector);
        this.extSet(poolId, TICK_SPACING, c);
    }

    function test_set_negativeBinSpacing_reverts() public {
        PoolConfig memory c = _validConfig();
        c.binSpacingTicks = -60;
        vm.expectRevert(InvalidPoolConfig.selector);
        this.extSet(poolId, TICK_SPACING, c);
    }

    function test_set_misalignedBinSpacing_reverts() public {
        PoolConfig memory c = _validConfig();
        c.binSpacingTicks = 65; // not a multiple of TICK_SPACING (10)
        vm.expectRevert(InvalidPoolConfig.selector);
        this.extSet(poolId, TICK_SPACING, c);
    }

    function test_set_binsPerSideBounds_revert() public {
        PoolConfig memory c = _validConfig();
        c.binsPerSide = MIN_BINS_PER_SIDE - 1;
        vm.expectRevert(InvalidPoolConfig.selector);
        this.extSet(poolId, TICK_SPACING, c);

        c = _validConfig();
        c.binsPerSide = MAX_BINS_PER_SIDE + 1;
        vm.expectRevert(InvalidPoolConfig.selector);
        this.extSet(poolId, TICK_SPACING, c);
    }

    function test_set_makerBinsBounds_revert() public {
        PoolConfig memory c = _validConfig();
        c.maxMakerBins = 0;
        vm.expectRevert(InvalidPoolConfig.selector);
        this.extSet(poolId, TICK_SPACING, c);

        c = _validConfig();
        c.maxMakerBins = MAX_MAKER_BINS + 1;
        vm.expectRevert(InvalidPoolConfig.selector);
        this.extSet(poolId, TICK_SPACING, c);
    }

    function test_set_retirePerSwapAboveMax_reverts() public {
        PoolConfig memory c = _validConfig();
        c.maxRetirePerSwap = MAX_RETIRE_PER_SWAP + 1;
        vm.expectRevert(InvalidPoolConfig.selector);
        this.extSet(poolId, TICK_SPACING, c);
    }

    function test_set_zeroTtl_reverts() public {
        PoolConfig memory c = _validConfig();
        c.maxQuoteTtl = 0;
        vm.expectRevert(InvalidPoolConfig.selector);
        this.extSet(poolId, TICK_SPACING, c);
    }

    function test_set_zeroMinLiquidity_reverts() public {
        PoolConfig memory c = _validConfig();
        c.minBinLiquidity = 0;
        vm.expectRevert(InvalidPoolConfig.selector);
        this.extSet(poolId, TICK_SPACING, c);
    }

    function testFuzz_set_validConfigRoundtrips(
        uint8 spacingMultiple,
        uint8 binsPerSide,
        uint8 maxMakerBins,
        uint8 maxRetirePerSwap,
        uint40 maxQuoteTtl,
        uint128 minBinLiquidity
    ) public {
        spacingMultiple = uint8(bound(spacingMultiple, 1, 200));
        binsPerSide = uint8(bound(binsPerSide, MIN_BINS_PER_SIDE, MAX_BINS_PER_SIDE));
        maxMakerBins = uint8(bound(maxMakerBins, 1, MAX_MAKER_BINS));
        maxRetirePerSwap = uint8(bound(maxRetirePerSwap, 0, MAX_RETIRE_PER_SWAP));
        maxQuoteTtl = uint40(bound(maxQuoteTtl, 1, type(uint40).max));
        minBinLiquidity = uint128(bound(minBinLiquidity, 1, type(uint128).max));

        PoolConfig memory c = PoolConfig({
            binSpacingTicks: int24(uint24(spacingMultiple)) * TICK_SPACING,
            binsPerSide: binsPerSide,
            maxMakerBins: maxMakerBins,
            maxRetirePerSwap: maxRetirePerSwap,
            maxQuoteTtl: maxQuoteTtl,
            minBinLiquidity: minBinLiquidity
        });
        this.extSet(poolId, TICK_SPACING, c);
        assertEq(config.get(poolId).binSpacingTicks, c.binSpacingTicks);
    }
}
