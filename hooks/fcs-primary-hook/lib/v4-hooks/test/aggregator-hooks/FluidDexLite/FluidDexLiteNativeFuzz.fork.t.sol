// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {FluidDexLiteAdminModule} from "lib/fluid-contracts-public/contracts/protocols/dexLite/adminModule/main.sol";
import {DexKey} from "lib/fluid-contracts-public/contracts/protocols/dexLite/other/structs.sol";
import {InitializeParams} from "lib/fluid-contracts-public/contracts/protocols/dexLite/adminModule/structs.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {SafePoolSwapTest} from "../shared/SafePoolSwapTest.sol";
import {MockV4FeeAdapter} from "../mocks/MockV4FeeAdapter.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";
import {
    FluidDexLiteAggregator
} from "../../../src/aggregator-hooks/implementations/FluidDexLite/FluidDexLiteAggregator.sol";
import {
    IFluidDexLiteResolver
} from "../../../src/aggregator-hooks/implementations/FluidDexLite/interfaces/IFluidDexLiteResolver.sol";
import {IFluidDexLite} from "../../../src/aggregator-hooks/implementations/FluidDexLite/interfaces/IFluidDexLite.sol";
import {
    FluidDexLiteAggregatorFactory
} from "../../../src/aggregator-hooks/implementations/FluidDexLite/FluidDexLiteAggregatorFactory.sol";

/// @title FluidDexLiteNativeFuzz
/// @notice Fuzz tests for FluidDexLite through Uniswap V4 hooks (Native ETH + ERC20 pairs)
/// @dev Creates random pools with native ETH and executes multiple swaps to verify quote accuracy
/// @dev Native ETH is always currency0 in Uniswap V4 (address(0) is the lowest address)
/// @dev Fork-bound; pinned low to keep CI fast (global default is raised in foundry.toml).
/// forge-config: default.fuzz.runs = 10
contract FluidDexLiteNativeFuzz is Test {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    // Fluid's native currency representation
    address constant FLUID_NATIVE_CURRENCY = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // Fluid Dex Lite contracts (from forked mainnet)
    IFluidDexLite public dexLite;
    address public dexLiteAdminModule;
    IFluidDexLiteResolver public resolver;
    address public fluidDexLiteAuth;

    // V4 contracts
    FluidDexLiteAggregatorFactory public hookFactory;
    IPoolManager public poolManager;
    SafePoolSwapTest public swapRouter;
    MockV4FeeAdapter public feeAdapter;

    // V4 Pool configuration
    uint24 constant POOL_FEE = 5; // 0.0005%
    int24 constant TICK_SPACING = 1;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 1:1 price

    // Price limits for swaps
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    // Fluid Dex Lite pool parameter bounds
    uint256 constant MIN_FEE = 1; // 0.01% in basis points
    uint256 constant MAX_FEE = 100; // 1% in basis points
    uint256 constant MIN_RANGE_PERCENT = 100; // 0.01%
    uint256 constant MAX_RANGE_PERCENT = 10000; // 1%

    // Center price bounds (1e27 = 1:1 price)
    uint256 constant MIN_CENTER_PRICE = 1e26; // 0.1:1
    uint256 constant MAX_CENTER_PRICE = 1e28; // 10:1

    // Liquidity bounds
    uint256 constant MIN_LIQUIDITY = 1_000 ether;
    uint256 constant MAX_LIQUIDITY = 10_000_000 ether;

    // Swap bounds (relative to pool liquidity)
    uint256 constant MIN_SWAP_DIVISOR = 10000; // min swap = liquidity / 10000
    uint256 constant MAX_SWAP_DIVISOR = 100; // max swap = liquidity / 100

    // Create alice address that doesn't have code on the forked chain (deterministic but unlikely to collide)
    address public alice = address(uint160(uint256(keccak256("fluid_dex_lite_test_alice_native_v1"))));
    address public tokenJar = makeAddr("tokenJar");

    /// @dev Struct to hold pool setup parameters (reduces stack depth)
    /// @dev For native pools: token0 is always native ETH (address(0) in V4), token1 is the ERC20
    struct PoolSetup {
        MockERC20 erc20Token; // The ERC20 token (token1 in V4 terms)
        DexKey dexKey;
        uint256 liquidityNative; // ETH liquidity (token0 in V4)
        uint256 liquidityErc20; // ERC20 liquidity (token1 in V4)
        uint256 fee;
        uint256 rangePercent;
        uint256 centerPrice; // Pool center price (1e27 = 1:1)
        bytes32 salt;
        bool ercIsFluidToken0; // True if ERC20 address < FLUID_NATIVE_CURRENCY
    }

    /// @dev Struct for hook deployment result
    struct HookDeployment {
        FluidDexLiteAggregator hook;
        PoolKey poolKey;
        PoolId poolId;
    }

    function setUp() public {
        string memory rpcUrl;
        // Forking requires an RPC URL env var and an optional block number
        try vm.envString("FORK_RPC_URL_1") returns (string memory _rpcUrl) {
            rpcUrl = _rpcUrl;
        } catch {
            console.log("Not forking. Skipping tests");
            vm.skip(true);
            return;
        }
        uint256 forkBlockNumber = vm.envOr("FORK_BLOCK_NUMBER_1", uint256(0));
        // Load Fluid infrastructure addresses from env vars
        dexLite = IFluidDexLite(vm.envAddress("FLUID_DEX_LITE"));
        dexLiteAdminModule = vm.envAddress("FLUID_DEX_LITE_ADMIN_MODULE");
        resolver = IFluidDexLiteResolver(vm.envAddress("FLUID_DEX_LITE_RESOLVER"));
        fluidDexLiteAuth = vm.envAddress("FLUID_DEX_LITE_AUTH");

        if (forkBlockNumber > 0) {
            vm.createSelectFork(rpcUrl, forkBlockNumber);
        } else {
            vm.createSelectFork(rpcUrl);
        }

        // Deploy V4 infrastructure
        poolManager =
            IPoolManager(vm.deployCode("foundry-out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        swapRouter = new SafePoolSwapTest(poolManager);
        feeAdapter = new MockV4FeeAdapter(poolManager, tokenJar);
        hookFactory = new FluidDexLiteAggregatorFactory(poolManager, dexLite, resolver);

        // Set this contract as the protocol fee controller
        poolManager.setProtocolFeeController(address(feeAdapter));
    }

    // ========== FUZZ TESTS ==========

    /// @notice Fuzz test: Exact input swaps, zeroForOne direction (Native ETH -> ERC20)
    /// @param seed Used to derive all random parameters deterministically
    function testFuzz_exactIn_zeroForOne(uint256 seed) public {
        (PoolSetup memory setup, HookDeployment memory deployment) = _setupPoolAndHook(seed);

        // Execute 3 exact input swaps (zeroForOne: Native -> ERC20)
        for (uint256 i = 0; i < 3; i++) {
            _executeExactInSwap_NativeIn(deployment, setup, seed, i);
        }
    }

    /// @notice Fuzz test: Exact input swaps, oneForZero direction (ERC20 -> Native ETH)
    /// @param seed Used to derive all random parameters deterministically
    function testFuzz_exactIn_oneForZero(uint256 seed) public {
        (PoolSetup memory setup, HookDeployment memory deployment) = _setupPoolAndHook(seed);

        // Execute 3 exact input swaps (oneForZero: ERC20 -> Native)
        for (uint256 i = 0; i < 3; i++) {
            _executeExactInSwap_ErcIn(deployment, setup, seed, i);
        }
    }

    /// @notice Fuzz test: Exact output swaps, zeroForOne direction (Native ETH -> ERC20)
    /// @dev This should revert because native exact-out is not supported
    /// @param seed Used to derive all random parameters deterministically
    function testFuzz_exactOut_zeroForOne_reverts(uint256 seed) public {
        (PoolSetup memory setup, HookDeployment memory deployment) = _setupPoolAndHook(seed);

        // Derive swap amount
        uint256 swapSeed = uint256(keccak256(abi.encode(seed, "swap", 0)));
        uint256 minLiquidity =
            setup.liquidityNative < setup.liquidityErc20 ? setup.liquidityNative : setup.liquidityErc20;
        // Use very small amounts for exact output (1/1000 of liquidity) to stay well within internal imaginary reserves
        uint256 amountOut = _deriveSwapAmount(swapSeed, minLiquidity) / 10;
        if (amountOut == 0) amountOut = 1 ether;

        // Expect revert for native exact-out
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(deployment.hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(FluidDexLiteAggregator.NativeCurrencyExactOut.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swapRouter.swap{value: amountOut * 2}(
            deployment.poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: int256(amountOut), // positive = exact output
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @notice Fuzz test: Exact output swaps, oneForZero direction (ERC20 -> Native ETH)
    /// @param seed Used to derive all random parameters deterministically
    function testFuzz_exactOut_oneForZero(uint256 seed) public {
        (PoolSetup memory setup, HookDeployment memory deployment) = _setupPoolAndHook(seed);

        // Execute 3 exact output swaps (oneForZero: ERC20 -> Native)
        for (uint256 i = 0; i < 3; i++) {
            _executeExactOutSwap_NativeOut(deployment, setup, seed, i);
        }
    }

    // ========== HELPERS ==========

    /// @notice Helper to setup pool and hook (reduces code duplication)
    function _setupPoolAndHook(uint256 seed)
        internal
        returns (PoolSetup memory setup, HookDeployment memory deployment)
    {
        setup = _derivePoolSetup(seed);
        bool success = _initializeFluidPool(setup);
        // Skip fuzz runs where pool initialization fails (Fluid has strict requirements for native pools)
        vm.assume(success);
        deployment = _deployHook(setup);

        // Derive and set protocol fee from seed
        uint24 protocolFee = _deriveProtocolFee(seed);
        if (protocolFee > 0) {
            uint24 packed = (protocolFee << 12) | protocolFee;
            vm.prank(address(feeAdapter));
            poolManager.setProtocolFee(deployment.poolKey, packed);
        }

        _setupAlice(setup);
    }

    /// @notice Derive all pool parameters from a single seed
    function _derivePoolSetup(uint256 seed) internal returns (PoolSetup memory setup) {
        // Create ERC20 token (will be token1 in V4 since address > address(0))
        setup.erc20Token = _createErc20Token(seed);

        // Derive pool parameters
        setup.liquidityNative = _deriveLiquidity(seed, 0);
        setup.liquidityErc20 = _deriveLiquidity(seed, 1);
        setup.fee = _deriveFee(seed);
        setup.rangePercent = _deriveRangePercent(seed);
        setup.centerPrice = _deriveCenterPrice(seed);
        setup.salt = keccak256(abi.encode(seed, "salt"));

        // Build dex key for Fluid (sorted: token0 < token1)
        // ERC20 could be either token0 or token1 depending on address comparison with FLUID_NATIVE_CURRENCY
        setup.ercIsFluidToken0 = address(setup.erc20Token) < FLUID_NATIVE_CURRENCY;
        if (setup.ercIsFluidToken0) {
            setup.dexKey = DexKey({token0: address(setup.erc20Token), token1: FLUID_NATIVE_CURRENCY, salt: setup.salt});
        } else {
            setup.dexKey = DexKey({token0: FLUID_NATIVE_CURRENCY, token1: address(setup.erc20Token), salt: setup.salt});
        }
    }

    /// @notice Create a mock ERC20 token
    function _createErc20Token(uint256 seed) internal returns (MockERC20 token) {
        bytes32 tokenSalt = keccak256(abi.encode(seed, "erc20Token"));
        token = new MockERC20{salt: tokenSalt}("Token", "TKN", 18);
    }

    /// @notice Initialize a Fluid Dex Lite pool with native ETH
    /// @return success Whether pool initialization succeeded
    function _initializeFluidPool(PoolSetup memory setup) internal returns (bool success) {
        // Mint ERC20 tokens to the auth address
        setup.erc20Token.mint(fluidDexLiteAuth, setup.liquidityErc20);
        // Deal ETH to the auth address for native liquidity
        vm.deal(fluidDexLiteAuth, setup.liquidityNative);

        // Approve ERC20 token
        vm.startPrank(fluidDexLiteAuth);
        setup.erc20Token.approve(address(dexLite), setup.liquidityErc20);
        vm.stopPrank();

        // Build initialization params
        // dexKey ordering (sorted): token0Amount and token1Amount must match dexKey ordering
        InitializeParams memory initParams = InitializeParams({
            dexKey: setup.dexKey,
            revenueCut: 0,
            fee: setup.fee,
            rebalancingStatus: false,
            centerPrice: setup.centerPrice,
            centerPriceContract: 0,
            upperPercent: setup.rangePercent,
            lowerPercent: setup.rangePercent,
            upperShiftThreshold: 0,
            lowerShiftThreshold: 0,
            shiftTime: 3600,
            minCenterPrice: 1,
            maxCenterPrice: type(uint256).max,
            token0Amount: setup.ercIsFluidToken0 ? setup.liquidityErc20 : setup.liquidityNative,
            token1Amount: setup.ercIsFluidToken0 ? setup.liquidityNative : setup.liquidityErc20
        });

        // Encode and execute initialization
        bytes memory initializeData = abi.encodeWithSelector(FluidDexLiteAdminModule.initialize.selector, initParams);
        bytes memory fallbackData = abi.encode(address(dexLiteAdminModule), initializeData);

        vm.prank(fluidDexLiteAuth);
        (success,) = address(dexLite).call{value: setup.liquidityNative}(fallbackData);
    }

    /// @notice Deploy V4 hook for the pool
    function _deployHook(PoolSetup memory setup) internal returns (HookDeployment memory deployment) {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );

        bytes memory constructorArgs = abi.encode(address(poolManager), address(dexLite), address(resolver), setup.salt);

        (, bytes32 hookSalt) =
            HookMiner.find(address(hookFactory), flags, type(FluidDexLiteAggregator).creationCode, constructorArgs);

        // In V4: currency0 = Native (address(0)), currency1 = ERC20
        address hookAddress = hookFactory.createPool(
            hookSalt,
            setup.salt,
            Currency.wrap(address(0)), // Native ETH is currency0
            Currency.wrap(address(setup.erc20Token)), // ERC20 is currency1
            POOL_FEE,
            TICK_SPACING,
            SQRT_PRICE_1_1
        );

        deployment.hook = FluidDexLiteAggregator(payable(hookAddress));

        deployment.poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(setup.erc20Token)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddress)
        });

        deployment.poolId = deployment.poolKey.toId();
    }

    /// @notice Setup alice with tokens and approvals
    function _setupAlice(PoolSetup memory setup) internal {
        // Deal ETH and mint ERC20 to alice
        vm.deal(alice, setup.liquidityNative);
        setup.erc20Token.mint(alice, setup.liquidityErc20);

        // Approve ERC20 for swap router (ETH doesn't need approval)
        vm.startPrank(alice);
        setup.erc20Token.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        // Seed PoolManager with tokens for swap settlements
        vm.deal(address(poolManager), setup.liquidityNative);
        setup.erc20Token.mint(address(poolManager), setup.liquidityErc20);
    }

    /// @dev Bundles exact-in swap parameters to reduce stack depth
    struct ExactInParams {
        uint256 amountIn;
        uint256 expectedOut;
        uint256 expectedFee;
    }

    /// @dev Bundles exact-out swap parameters to reduce stack depth
    struct ExactOutParams {
        uint256 amountOut;
        uint256 expectedIn;
        uint256 expectedFee;
    }

    /// @notice Derive exact-in swap parameters for Native -> ERC20 (zeroForOne)
    function _deriveExactInParams_NativeIn(
        HookDeployment memory deployment,
        PoolSetup memory setup,
        uint256 seed,
        uint256 swapIdx
    ) internal returns (ExactInParams memory params) {
        uint256 swapSeed = uint256(keccak256(abi.encode(seed, "swap", swapIdx)));
        uint256 minLiquidity =
            setup.liquidityNative < setup.liquidityErc20 ? setup.liquidityNative : setup.liquidityErc20;
        params.amountIn = _deriveSwapAmount(swapSeed, minLiquidity);
        params.expectedOut = deployment.hook.quote(true, -int256(params.amountIn), deployment.poolId);
        uint24 protocolFee = _deriveProtocolFee(seed) * 25;
        params.expectedFee = (params.expectedOut * protocolFee) / (ProtocolFeeLibrary.PIPS_DENOMINATOR - protocolFee);
    }

    /// @notice Derive exact-in swap parameters for ERC20 -> Native (oneForZero)
    function _deriveExactInParams_ErcIn(
        HookDeployment memory deployment,
        PoolSetup memory setup,
        uint256 seed,
        uint256 swapIdx
    ) internal returns (ExactInParams memory params) {
        uint256 swapSeed = uint256(keccak256(abi.encode(seed, "swap", swapIdx)));
        uint256 minLiquidity =
            setup.liquidityNative < setup.liquidityErc20 ? setup.liquidityNative : setup.liquidityErc20;
        params.amountIn = _deriveSwapAmount(swapSeed, minLiquidity);
        params.expectedOut = deployment.hook.quote(false, -int256(params.amountIn), deployment.poolId);
        uint24 protocolFee = _deriveProtocolFee(seed) * 25;
        params.expectedFee = (params.expectedOut * protocolFee) / (ProtocolFeeLibrary.PIPS_DENOMINATOR - protocolFee);
    }

    /// @notice Derive exact-out swap parameters for Native out (oneForZero)
    function _deriveExactOutParams_NativeOut(
        HookDeployment memory deployment,
        PoolSetup memory setup,
        uint256 seed,
        uint256 swapIdx
    ) internal returns (ExactOutParams memory params) {
        uint256 swapSeed = uint256(keccak256(abi.encode(seed, "swap", swapIdx)));
        uint256 minLiquidity =
            setup.liquidityNative < setup.liquidityErc20 ? setup.liquidityNative : setup.liquidityErc20;
        params.amountOut = _deriveSwapAmount(swapSeed, minLiquidity) / 10;
        if (params.amountOut == 0) params.amountOut = 1 ether;
        params.expectedIn = deployment.hook.quote(false, int256(params.amountOut), deployment.poolId);
        uint24 protocolFee = _deriveProtocolFee(seed) * 25;
        params.expectedFee = (params.expectedIn * protocolFee) / ProtocolFeeLibrary.PIPS_DENOMINATOR;
    }

    // ========== SWAP HELPERS ==========

    /// @notice Execute an exact input swap: Native ETH -> ERC20 (zeroForOne)
    function _executeExactInSwap_NativeIn(
        HookDeployment memory deployment,
        PoolSetup memory setup,
        uint256 seed,
        uint256 swapIdx
    ) internal {
        ExactInParams memory params = _deriveExactInParams_NativeIn(deployment, setup, seed, swapIdx);
        assertGt(params.expectedOut, 0, "Quote should be non-zero");

        uint256 ethBefore = alice.balance;
        uint256 ercBefore = setup.erc20Token.balanceOf(alice);
        uint256 tokenJarBefore = setup.erc20Token.balanceOf(tokenJar);

        vm.prank(alice);
        swapRouter.swap{value: params.amountIn}(
            deployment.poolKey,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(params.amountIn), sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 ethSpent = ethBefore - alice.balance;
        assertApproxEqRel(ethSpent, params.amountIn, 0.001e18, "ETH spent should be close to input amount");
        assertEq(
            setup.erc20Token.balanceOf(alice) - ercBefore,
            params.expectedOut,
            "Received amount should match quoted output"
        );
        assertApproxEqAbs(
            setup.erc20Token.balanceOf(tokenJar) - tokenJarBefore,
            params.expectedFee,
            1,
            "Token jar should receive protocol fee"
        );
    }

    /// @notice Execute an exact input swap: ERC20 -> Native ETH (oneForZero)
    function _executeExactInSwap_ErcIn(
        HookDeployment memory deployment,
        PoolSetup memory setup,
        uint256 seed,
        uint256 swapIdx
    ) internal {
        ExactInParams memory params = _deriveExactInParams_ErcIn(deployment, setup, seed, swapIdx);
        assertGt(params.expectedOut, 0, "Quote should be non-zero");

        uint256 ethBefore = alice.balance;
        uint256 ercBefore = setup.erc20Token.balanceOf(alice);
        uint256 tokenJarEthBefore = tokenJar.balance;

        vm.prank(alice);
        swapRouter.swap(
            deployment.poolKey,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(params.amountIn), sqrtPriceLimitX96: MAX_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(ercBefore - setup.erc20Token.balanceOf(alice), params.amountIn, "Should spend exact input amount");
        uint256 ethReceived = alice.balance - ethBefore;
        assertApproxEqRel(ethReceived, params.expectedOut, 0.001e18, "ETH received should be close to quoted output");
        assertApproxEqAbs(
            tokenJar.balance - tokenJarEthBefore, params.expectedFee, 1, "Token jar should receive protocol fee in ETH"
        );
    }

    /// @notice Execute an exact output swap: ERC20 -> Native ETH (oneForZero)
    function _executeExactOutSwap_NativeOut(
        HookDeployment memory deployment,
        PoolSetup memory setup,
        uint256 seed,
        uint256 swapIdx
    ) internal {
        ExactOutParams memory params = _deriveExactOutParams_NativeOut(deployment, setup, seed, swapIdx);
        assertGt(params.expectedIn, 0, "Quote should be non-zero");

        uint256 ethBefore = alice.balance;
        uint256 ercBefore = setup.erc20Token.balanceOf(alice);
        uint256 tokenJarBefore = setup.erc20Token.balanceOf(tokenJar);

        vm.prank(alice);
        swapRouter.swap(
            deployment.poolKey,
            SwapParams({
                zeroForOne: false, amountSpecified: int256(params.amountOut), sqrtPriceLimitX96: MAX_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 ethReceived = alice.balance - ethBefore;
        assertApproxEqRel(ethReceived, params.amountOut, 0.001e18, "ETH received should be close to output amount");
        assertApproxEqRel(
            ercBefore - setup.erc20Token.balanceOf(alice),
            params.expectedIn,
            0.001e18,
            "ERC20 spent should be close to quoted input"
        );
        assertApproxEqAbs(
            setup.erc20Token.balanceOf(tokenJar) - tokenJarBefore,
            params.expectedFee,
            1,
            "Token jar should receive protocol fee in ERC20"
        );
    }

    // ========== SEED-BASED DERIVATION HELPERS ==========

    /// @notice Derive liquidity amount for a token
    function _deriveLiquidity(uint256 seed, uint256 tokenIdx) internal pure returns (uint256) {
        return bound(uint256(keccak256(abi.encode(seed, "liquidity", tokenIdx))), MIN_LIQUIDITY, MAX_LIQUIDITY);
    }

    /// @notice Derive fee for the pool
    function _deriveFee(uint256 seed) internal pure returns (uint256) {
        return bound(uint256(keccak256(abi.encode(seed, "fee"))), MIN_FEE, MAX_FEE);
    }

    /// @notice Derive range percent for the pool
    function _deriveRangePercent(uint256 seed) internal pure returns (uint256) {
        return bound(uint256(keccak256(abi.encode(seed, "range"))), MIN_RANGE_PERCENT, MAX_RANGE_PERCENT);
    }

    /// @notice Derive center price for the pool
    function _deriveCenterPrice(uint256 seed) internal pure returns (uint256) {
        return bound(uint256(keccak256(abi.encode(seed, "centerPrice"))), MIN_CENTER_PRICE, MAX_CENTER_PRICE);
    }

    /// @notice Derive swap amount based on pool liquidity
    function _deriveSwapAmount(uint256 seed, uint256 liquidity) internal pure returns (uint256) {
        uint256 minSwap = liquidity / MIN_SWAP_DIVISOR;
        uint256 maxSwap = liquidity / MAX_SWAP_DIVISOR;
        return bound(uint256(keccak256(abi.encode(seed, "amount"))), minSwap, maxSwap);
    }

    /// @notice Derive protocol fee from seed (0 to MAX_PROTOCOL_FEE)
    function _deriveProtocolFee(uint256 seed) internal pure returns (uint24) {
        return
            uint24(bound(uint256(keccak256(abi.encode(seed, "protocolFee"))), 0, ProtocolFeeLibrary.MAX_PROTOCOL_FEE));
    }

    receive() external payable {}
}
