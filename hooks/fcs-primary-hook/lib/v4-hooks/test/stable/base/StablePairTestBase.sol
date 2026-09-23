// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StablePairHook} from "../../../src/stable/StablePairHook.sol";
import {BaseDynamicFeeHook} from "../../../src/base/BaseDynamicFeeHook.sol";
import {StableFeeConfig} from "../../../src/stable/interfaces/IStableFeeConfiguration.sol";
import {StableFeeCalculation} from "../../../src/stable/libraries/StableFeeCalculation.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
// Referenced only by name in `deployCodeTo`; imported so forge includes its artifact in the build.
import {ERC1967Proxy as _ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Single shared base for every StablePairHook test suite
abstract contract StablePairTestBase is Test {
    using PoolIdLibrary for PoolKey;

    uint24 internal constant K = 16_609_443; // floor(0.99 * 2^24): ~1% fee decay per block
    uint256 internal constant LOG_K = 599_049_713; // ceil(-ln(K/2^24) / 2^24), what the slow path derives from K
    uint24 internal constant OPTIMAL_FEE_E6 = 90; // 0.9 bps
    uint160 internal constant REFERENCE_SQRT_PRICE_X96 = Constants.SQRT_PRICE_1_1; // 1:1 reference
    int24 internal constant TICK_SPACING = 60;
    uint8 internal constant TARGET_MULTIPLIER = 50; // mid-range target multiplier for the standard test config

    /// @notice The proxy's frozen permission flags: restores the old forwarder's upgrade
    ///         headroom (still no donate/removeLiquidity/returnsDelta flags).
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );

    // -------------------------------------------------------------------------
    // Mocked-manager environment
    // -------------------------------------------------------------------------

    StablePairHook public hook;

    address internal configManager = makeAddr("configManager");
    address internal poolInitializer = makeAddr("poolInitializer");
    address internal owner = makeAddr("owner");
    uint160 internal sqrtAmmPriceX96 = Constants.SQRT_PRICE_1_1;
    PoolKey internal testPoolKey;

    struct ConfigSeed {
        uint24 kSeed;
        uint24 optimalFeeSeed;
        uint8 targetMultSeed;
        uint160 refPriceSeed;
    }

    struct SwapStep {
        bool zeroForOne;
        uint160 priceSeed;
        uint32 blockGap;
    }

    function setUp() public virtual {
        StablePairHook impl = new StablePairHook(IPoolManager(address(this)));
        address proxyAddress = address((uint160(type(uint160).max) & ~Hooks.ALL_HOOK_MASK) | HOOK_FLAGS);
        deployCodeTo(
            "ERC1967Proxy.sol:ERC1967Proxy",
            abi.encode(
                address(impl), abi.encodeCall(BaseDynamicFeeHook.initialize, (owner, poolInitializer, configManager))
            ),
            proxyAddress
        );
        hook = StablePairHook(proxyAddress);

        testPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        // Compute the config BEFORE pranking: _initialConfig() may itself make external calls into
        // `hook` (e.g. reading MAX_OPTIMAL_FEE_E6()), which would otherwise consume the single-use prank
        // intended for initializePool.
        StableFeeConfig memory initialConfig = _initialConfig();
        vm.prank(poolInitializer);
        hook.initializePool(testPoolKey, Constants.SQRT_PRICE_1_1, initialConfig);
    }

    /// @notice Independent mirror of StableFeeCalculation.deriveLogK, kept as a test reference
    function deriveLogK(uint256 k) internal pure returns (uint256) {
        uint256 kWad = (k * 1e18) >> 24;
        int256 lnK = FixedPointMathLib.lnWad(int256(kWad));
        // ceil: the quantized exponent must never understate -ln(k)
        return (uint256(-lnK) + ((uint256(1) << 24) - 1)) >> 24;
    }

    /// @notice Valid reference-price bounds, replicating _validateReferenceSqrtPriceX96: the widest
    /// optimal range around the reference must stay inside v4's [MIN_SQRT_PRICE, MAX_SQRT_PRICE).
    function referenceBounds(uint256 maxOptimalFeeE6) internal pure returns (uint256 minRef, uint256 maxRef) {
        uint256 oneE6 = StableFeeCalculation.ONE_E6;
        uint256 sqrtOneMinusMaxFeeE6 = FixedPointMathLib.sqrt((oneE6 - maxOptimalFeeE6) * oneE6);
        minRef = (uint256(TickMath.MIN_SQRT_PRICE) * oneE6 + sqrtOneMinusMaxFeeE6 - 1) / sqrtOneMinusMaxFeeE6;
        maxRef = uint256(TickMath.MAX_SQRT_PRICE) * sqrtOneMinusMaxFeeE6 / oneE6;
    }

    /// @notice The standard test config, built entirely from the shared constants.
    function _defaultConfig() internal pure returns (StableFeeConfig memory) {
        return StableFeeConfig({
            k: K,
            optimalFeeE6: OPTIMAL_FEE_E6,
            targetMultiplier: TARGET_MULTIPLIER,
            referenceSqrtPriceX96: REFERENCE_SQRT_PRICE_X96
        });
    }

    /// @notice The fee config the pool is initialized with; suites override to customize.
    function _initialConfig() internal virtual returns (StableFeeConfig memory) {
        return _defaultConfig();
    }

    // -------------------------------------------------------------------------
    // Fuzz generators
    // -------------------------------------------------------------------------

    /// @notice Valid reference-price bounds for the hook's own MAX_OPTIMAL_FEE_E6.
    function _referenceBounds() internal view returns (uint256 minRef, uint256 maxRef) {
        return referenceBounds(hook.MAX_OPTIMAL_FEE_E6());
    }

    /// @notice Bound a raw seed into a fully valid StableFeeConfig.
    function _boundFeeConfig(ConfigSeed memory s) internal view returns (StableFeeConfig memory config) {
        (uint256 minRef, uint256 maxRef) = _referenceBounds();
        config = StableFeeConfig({
            k: uint24(bound(uint256(s.kSeed), 1, type(uint24).max)),
            optimalFeeE6: uint24(bound(uint256(s.optimalFeeSeed), 0, hook.MAX_OPTIMAL_FEE_E6())),
            targetMultiplier: uint8(bound(uint256(s.targetMultSeed), 0, hook.MAX_TARGET_MULTIPLIER())),
            referenceSqrtPriceX96: uint160(bound(uint256(s.refPriceSeed), minRef, maxRef - 1))
        });
    }

    /// @notice Any valid v4 price (overflow/edge sweep).
    function _boundSqrtPriceAbsolute(uint160 seed) internal pure returns (uint160) {
        return uint160(bound(uint256(seed), TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
    }

    /// @notice A price near the reference (~0.90x..1.10x in price space) so fuzz samples land near the
    /// band. Works in sqrt space to avoid overflowing ref^2 at large reference prices.
    function _boundSqrtPriceRelative(uint160 seed, uint160 refSqrtPrice) internal pure returns (uint160) {
        uint256 priceBps = bound(uint256(seed), 900_000, 1_100_000); // 0.90x .. 1.10x of reference PRICE
        // factorE6 = sqrt(priceBps/1e6) * 1e6  =>  sqrtAmm = refSqrt * factorE6 / 1e6
        uint256 factorE6 = FixedPointMathLib.sqrt(priceBps * 1e6);
        uint256 sqrtAmm = uint256(refSqrtPrice) * factorE6 / 1e6;
        if (sqrtAmm < uint256(TickMath.MIN_SQRT_PRICE)) sqrtAmm = uint256(TickMath.MIN_SQRT_PRICE);
        if (sqrtAmm >= uint256(TickMath.MAX_SQRT_PRICE)) sqrtAmm = uint256(TickMath.MAX_SQRT_PRICE) - 1;
        return uint160(sqrtAmm);
    }

    function initialize(PoolKey calldata, uint160) external pure returns (int24) {
        return 0;
    }

    /// @dev Returns a packed v4 slot0 with the settable `sqrtAmmPriceX96` in the price bits. The
    /// upper bits encode arbitrary non-price fields the hook never reads, packed per StateLibrary's
    /// slot0 layout (from bit 160 up): tick = 0xffff75 (-139), protocolFee = 0, lpFee = 0xbb8 (3000).
    function extsload(bytes32 slot) external view returns (bytes32) {
        assertEq(slot, StateLibrary._getPoolStateSlot(testPoolKey.toId()));
        return bytes32(uint256(sqrtAmmPriceX96) | ((0x000000_000bb8_000000_ffff75) << 160));
    }

    // --- shared helper ---
    function _setConfig(StableFeeConfig memory config) internal {
        vm.prank(configManager);
        hook.updateFeeConfig(testPoolKey.toId(), config);
    }
}
