// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
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
import {IFluidDexFactory} from "./interfaces/IFluidDexFactory.sol";
import {IFluidDexT1DeploymentLogic} from "./interfaces/IFluidDexT1DeploymentLogic.sol";
import {IFluidLiquidityAdmin} from "./interfaces/IFluidLiquidityAdmin.sol";
import {IFluidDexT1Admin} from "./interfaces/IFluidDexT1Admin.sol";
import {AdminModuleStructs} from "./libraries/AdminModuleStructs.sol";
import {DexAdminStructs} from "./libraries/DexAdminStructs.sol";
import {MockLiquiditySupplier} from "./mocks/MockLiquiditySupplier.sol";
import {SafePoolSwapTest} from "../shared/SafePoolSwapTest.sol";
import {MockV4FeeAdapter} from "../mocks/MockV4FeeAdapter.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";
import {
    FluidDexT1AggregatorFactory
} from "../../../src/aggregator-hooks/implementations/FluidDexT1/FluidDexT1AggregatorFactory.sol";
import {
    IFluidDexReservesResolver
} from "../../../src/aggregator-hooks/implementations/FluidDexT1/interfaces/IFluidDexReservesResolver.sol";
import {
    IFluidDexResolver
} from "../../../src/aggregator-hooks/implementations/FluidDexT1/interfaces/IFluidDexResolver.sol";
import {IFluidDexT1} from "../../../src/aggregator-hooks/implementations/FluidDexT1/interfaces/IFluidDexT1.sol";
import {FluidDexT1Aggregator} from "../../../src/aggregator-hooks/implementations/FluidDexT1/FluidDexT1Aggregator.sol";

/// @title FluidDexT1ERC20Fuzz
/// @notice Fuzz tests for FluidDexT1 through Uniswap V4 hooks (ERC20 tokens only)
/// @dev Creates random pools with MockERC20 tokens and executes multiple swaps to verify quote accuracy
/// @dev Fork-bound; pinned low to keep CI fast (global default is raised in foundry.toml).
/// forge-config: default.fuzz.runs = 10
contract FluidDexT1ERC20Fuzz is Test {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    // Mainnet addresses (loaded from env vars)
    address liquidity;
    address dexFactoryAddress;
    address dexReservesResolver;
    address dexResolver;
    address dexT1DeploymentLogic;
    address timelock;

    // Fluid contracts (loaded from mainnet fork)
    IFluidDexFactory public dexFactory;
    IFluidLiquidityAdmin public liquidityAdmin;
    IFluidDexT1DeploymentLogic public deploymentLogic;
    IFluidDexReservesResolver public resolver;
    MockLiquiditySupplier public liquiditySupplier;

    // V4 contracts
    FluidDexT1AggregatorFactory public hookFactory;
    IPoolManager public poolManager;
    SafePoolSwapTest public swapRouter;

    // V4 Pool configuration
    uint24 constant POOL_FEE = 5; // 0.0005%
    int24 constant TICK_SPACING = 1;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 1:1 price

    // Price limits for swaps
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    // Pool parameter bounds
    uint256 constant MIN_FEE = 0; // 0% in basis points (1e4 = 1%)
    uint256 constant MAX_FEE = 1000; // 0.1% in basis points
    uint256 constant MIN_RANGE_PERCENT = 1 * 1e4; // 1% (1e4 = 1%)
    uint256 constant MAX_RANGE_PERCENT = 20 * 1e4; // 20%

    // Liquidity bounds
    // Note: Fluid has a rate limit check where new supply can't exceed 2^80 (~1.2e24) when no existing supply
    // Since we prefund with 2x liquidity, MAX_LIQUIDITY * 2 must be < 2^80
    uint256 constant MIN_LIQUIDITY = 1_000 ether;
    uint256 constant MAX_LIQUIDITY = 500_000 ether; // 5e23, so 2x = 1e24 < 2^80

    // Swap bounds (relative to pool liquidity)
    uint256 constant MIN_SWAP_DIVISOR = 10000; // min swap = liquidity / 10000
    uint256 constant MAX_SWAP_DIVISOR = 100; // max swap = liquidity / 100

    address public alice = makeAddr("alice");
    address public tokenJar = makeAddr("tokenJar");
    MockV4FeeAdapter public feeAdapter;

    /// @dev Struct to hold pool setup parameters (to reduce stack depth)
    struct PoolSetup {
        MockERC20 token0;
        MockERC20 token1;
        address fluidPool;
        uint256 liquidity0;
        uint256 liquidity1;
        uint256 fee;
        uint256 rangePercent;
    }

    /// @dev Struct for hook deployment result
    struct HookDeployment {
        FluidDexT1Aggregator hook;
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
        liquidity = vm.envAddress("FLUID_LIQUIDITY");
        dexFactoryAddress = vm.envAddress("FLUID_DEX_T1_FACTORY");
        dexReservesResolver = vm.envOr("FLUID_DEX_T1_RESERVES_RESOLVER", vm.envAddress("FLUID_DEX_T1_RESOLVER"));
        dexResolver = vm.envAddress("FLUID_DEX_T1_RESOLVER");
        dexT1DeploymentLogic = vm.envAddress("FLUID_DEX_T1_DEPLOYMENT_LOGIC");
        timelock = vm.envAddress("FLUID_DEX_T1_TIMELOCK");

        if (forkBlockNumber > 0) {
            vm.createSelectFork(rpcUrl, forkBlockNumber);
        } else {
            vm.createSelectFork(rpcUrl);
        }

        // Load mainnet contracts
        dexFactory = IFluidDexFactory(dexFactoryAddress);
        liquidityAdmin = IFluidLiquidityAdmin(liquidity);
        deploymentLogic = IFluidDexT1DeploymentLogic(dexT1DeploymentLogic);
        resolver = IFluidDexReservesResolver(dexReservesResolver);

        // Deploy liquidity supplier for prefunding
        liquiditySupplier = new MockLiquiditySupplier(liquidity);

        // Add this test contract as a deployer and global auth
        vm.startPrank(timelock);
        dexFactory.setDeployer(address(this), true);
        dexFactory.setGlobalAuth(address(this), true);
        vm.stopPrank();

        // Deploy V4 infrastructure
        poolManager =
            IPoolManager(vm.deployCode("foundry-out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        swapRouter = new SafePoolSwapTest(poolManager);
        feeAdapter = new MockV4FeeAdapter(poolManager, tokenJar);
        hookFactory = new FluidDexT1AggregatorFactory(
            poolManager, IFluidDexReservesResolver(dexReservesResolver), IFluidDexResolver(dexResolver), liquidity
        );

        // Set this contract as the protocol fee controller
        poolManager.setProtocolFeeController(address(feeAdapter));
    }

    // ========== FUZZ TESTS ==========

    /// @notice Fuzz test: Exact input swaps, zeroForOne direction
    /// @param seed Used to derive all random parameters deterministically
    function testFuzz_exactIn_zeroForOne(uint256 seed) public {
        (PoolSetup memory setup, HookDeployment memory deployment) = _setupPoolAndHook(seed);

        // Execute 3 exact input swaps (zeroForOne)
        for (uint256 i = 0; i < 3; i++) {
            _executeExactInSwap(deployment, setup, seed, i, true);
        }
    }

    /// @notice Fuzz test: Exact input swaps, oneForZero direction
    /// @param seed Used to derive all random parameters deterministically
    function testFuzz_exactIn_oneForZero(uint256 seed) public {
        (PoolSetup memory setup, HookDeployment memory deployment) = _setupPoolAndHook(seed);

        // Execute 3 exact input swaps (oneForZero)
        for (uint256 i = 0; i < 3; i++) {
            _executeExactInSwap(deployment, setup, seed, i, false);
        }
    }

    /// @notice Fuzz test: Exact output swaps, zeroForOne direction
    /// @param seed Used to derive all random parameters deterministically
    function testFuzz_exactOut_zeroForOne(uint256 seed) public {
        (PoolSetup memory setup, HookDeployment memory deployment) = _setupPoolAndHook(seed);

        // Execute 3 exact output swaps (zeroForOne)
        for (uint256 i = 0; i < 3; i++) {
            _executeExactOutSwap(deployment, setup, seed, i, true);
        }
    }

    /// @notice Fuzz test: Exact output swaps, oneForZero direction
    /// @param seed Used to derive all random parameters deterministically
    function testFuzz_exactOut_oneForZero(uint256 seed) public {
        (PoolSetup memory setup, HookDeployment memory deployment) = _setupPoolAndHook(seed);

        // Execute 3 exact output swaps (oneForZero)
        for (uint256 i = 0; i < 3; i++) {
            _executeExactOutSwap(deployment, setup, seed, i, false);
        }
    }

    // ========== POOL SETUP HELPERS ==========

    /// @notice Helper to setup pool and hook (reduces code duplication)
    function _setupPoolAndHook(uint256 seed)
        internal
        returns (PoolSetup memory setup, HookDeployment memory deployment)
    {
        setup = _derivePoolSetup(seed);
        _configureTokensInLiquidity(setup);
        _deployAndInitializeFluidPool(setup);
        deployment = _deployHook(setup);

        // Derive and set protocol fee from seed
        uint24 protocolFee = _deriveProtocolFee(seed);
        if (protocolFee > 0) {
            uint24 packed = (protocolFee << 12) | protocolFee;
            vm.prank(address(feeAdapter));
            poolManager.setProtocolFee(deployment.poolKey, packed);
        }

        _setupAlice(setup.token0, setup.token1, setup.liquidity0, setup.liquidity1);
    }

    // ========== HELPERS ==========

    /// @notice Derive all pool parameters from a single seed
    function _derivePoolSetup(uint256 seed) internal returns (PoolSetup memory setup) {
        // Create sorted tokens
        (setup.token0, setup.token1) = _createSortedTokens(seed);

        // Derive pool parameters
        setup.liquidity0 = _deriveLiquidity(seed, 0);
        setup.liquidity1 = _deriveLiquidity(seed, 1);
        setup.fee = _deriveFee(seed);
        setup.rangePercent = _deriveRangePercent(seed);
    }

    /// @notice Create two mock tokens and sort by address
    function _createSortedTokens(uint256 seed) internal returns (MockERC20 token0, MockERC20 token1) {
        bytes32 salt0 = keccak256(abi.encode(seed, "token0"));
        bytes32 salt1 = keccak256(abi.encode(seed, "token1"));

        token0 = new MockERC20{salt: salt0}("Token0", "TK0", 18);
        token1 = new MockERC20{salt: salt1}("Token1", "TK1", 18);

        // Ensure token0 < token1
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }
    }

    /// @notice Configure tokens in the Liquidity layer (rate data + token config)
    function _configureTokensInLiquidity(PoolSetup memory setup) internal {
        vm.startPrank(timelock);

        // Configure rate data for both tokens
        AdminModuleStructs.RateDataV1Params[] memory rateParams = new AdminModuleStructs.RateDataV1Params[](2);
        rateParams[0] = AdminModuleStructs.RateDataV1Params({
            token: address(setup.token0),
            kink: 8000, // 80%
            rateAtUtilizationZero: 0,
            rateAtUtilizationKink: 1000, // 10%
            rateAtUtilizationMax: 2000 // 20%
        });
        rateParams[1] = AdminModuleStructs.RateDataV1Params({
            token: address(setup.token1),
            kink: 8000,
            rateAtUtilizationZero: 0,
            rateAtUtilizationKink: 1000,
            rateAtUtilizationMax: 2000
        });
        liquidityAdmin.updateRateDataV1s(rateParams);

        // Configure token settings
        AdminModuleStructs.TokenConfig[] memory tokenConfigs = new AdminModuleStructs.TokenConfig[](2);
        tokenConfigs[0] = AdminModuleStructs.TokenConfig({
            token: address(setup.token0),
            fee: 0,
            threshold: 0,
            maxUtilization: 10000 // 100%
        });
        tokenConfigs[1] =
            AdminModuleStructs.TokenConfig({token: address(setup.token1), fee: 0, threshold: 0, maxUtilization: 10000});
        liquidityAdmin.updateTokenConfigs(tokenConfigs);

        vm.stopPrank();
    }

    /// @notice Deploy and initialize a Fluid DexT1 pool
    function _deployAndInitializeFluidPool(PoolSetup memory setup) internal {
        // Mint tokens BEFORE setting allowances (maxDebtCeiling validated against totalSupply)
        // Mint extra for: liquidity layer supply, pool init, alice, poolManager
        uint256 totalMint0 = setup.liquidity0 * 6;
        uint256 totalMint1 = setup.liquidity1 * 6;
        setup.token0.mint(address(this), totalMint0);
        setup.token1.mint(address(this), totalMint1);

        // Deploy pool via factory
        bytes memory creationCode =
            abi.encodeCall(deploymentLogic.dexT1, (address(setup.token0), address(setup.token1), 1e4));
        setup.fluidPool = dexFactory.deployDex(dexT1DeploymentLogic, creationCode);

        // Configure liquidity allowances for the supplier (to prefund layer)
        _setUserAllowancesDefault(address(setup.token0), address(liquiditySupplier), totalMint0);
        _setUserAllowancesDefault(address(setup.token1), address(liquiditySupplier), totalMint1);

        // Configure liquidity allowances for the pool
        _setUserAllowancesDefault(address(setup.token0), setup.fluidPool, totalMint0);
        _setUserAllowancesDefault(address(setup.token1), setup.fluidPool, totalMint1);

        // Prefund the liquidity layer so DEX can borrow during swaps
        uint256 prefundAmount0 = setup.liquidity0 * 2;
        uint256 prefundAmount1 = setup.liquidity1 * 2;
        setup.token0.approve(address(liquiditySupplier), prefundAmount0);
        setup.token1.approve(address(liquiditySupplier), prefundAmount1);
        // Approve from this contract to liquidity layer (supplier will transferFrom)
        setup.token0.approve(liquidity, prefundAmount0);
        setup.token1.approve(liquidity, prefundAmount1);
        liquiditySupplier.supply(address(setup.token0), prefundAmount0, address(this));
        liquiditySupplier.supply(address(setup.token1), prefundAmount1, address(this));

        // For smart col/debt at 1:1 price, both tokens are needed in equal amounts
        // Use minimum liquidity to ensure we have enough of both
        uint256 initAmount = setup.liquidity0 < setup.liquidity1 ? setup.liquidity0 : setup.liquidity1;

        // Approve tokens to pool for initialization (need enough for both col and debt)
        setup.token0.approve(setup.fluidPool, initAmount * 2);
        setup.token1.approve(setup.fluidPool, initAmount * 2);

        // Initialize the pool
        uint256 centerPrice = 1e27; // 1:1 center price
        DexAdminStructs.InitializeVariables memory initParams = DexAdminStructs.InitializeVariables({
            smartCol: true,
            token0ColAmt: initAmount,
            smartDebt: true,
            token0DebtAmt: initAmount,
            centerPrice: centerPrice,
            fee: setup.fee,
            revenueCut: 0,
            upperPercent: setup.rangePercent,
            lowerPercent: setup.rangePercent,
            upperShiftThreshold: 5 * 1e4, // 5%
            lowerShiftThreshold: 5 * 1e4,
            thresholdShiftTime: 1 days,
            centerPriceAddress: 0,
            hookAddress: 0,
            maxCenterPrice: (centerPrice * 110) / 100,
            minCenterPrice: (centerPrice * 90) / 100
        });

        IFluidDexT1Admin(setup.fluidPool).initialize(initParams);
        IFluidDexT1Admin(setup.fluidPool).toggleOracleActivation(true);
    }

    /// @notice Set user supply and borrow allowances for a token/pool pair
    /// @dev Token must have totalSupply > 0 before calling this (maxDebtCeiling validated against 10x totalSupply)
    function _setUserAllowancesDefault(address token, address pool, uint256 tokenTotalSupply) internal {
        vm.startPrank(timelock);

        // Supply config
        AdminModuleStructs.UserSupplyConfig[] memory supplyConfigs = new AdminModuleStructs.UserSupplyConfig[](1);
        supplyConfigs[0] = AdminModuleStructs.UserSupplyConfig({
            user: pool,
            token: token,
            mode: 1, // with interest
            expandPercent: 2500, // 25%
            expandDuration: 12 hours,
            baseWithdrawalLimit: tokenTotalSupply // Use total supply as limit
        });
        liquidityAdmin.updateUserSupplyConfigs(supplyConfigs);

        // Borrow config - maxDebtCeiling must be <= 10 * totalSupply
        uint256 maxDebt = tokenTotalSupply * 9; // Stay under 10x limit
        AdminModuleStructs.UserBorrowConfig[] memory borrowConfigs = new AdminModuleStructs.UserBorrowConfig[](1);
        borrowConfigs[0] = AdminModuleStructs.UserBorrowConfig({
            user: pool,
            token: token,
            mode: 1, // with interest
            expandPercent: 2500,
            expandDuration: 12 hours,
            baseDebtCeiling: maxDebt,
            maxDebtCeiling: maxDebt
        });
        liquidityAdmin.updateUserBorrowConfigs(borrowConfigs);

        vm.stopPrank();
    }

    /// @notice Deploy V4 hook for the pool
    function _deployHook(PoolSetup memory setup) internal returns (HookDeployment memory deployment) {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );

        bytes memory constructorArgs = abi.encode(
            address(poolManager), setup.fluidPool, address(dexReservesResolver), address(dexResolver), liquidity
        );

        (, bytes32 hookSalt) =
            HookMiner.find(address(hookFactory), flags, type(FluidDexT1Aggregator).creationCode, constructorArgs);

        address hookAddress = hookFactory.createPool(
            hookSalt,
            IFluidDexT1(setup.fluidPool),
            Currency.wrap(address(setup.token0)),
            Currency.wrap(address(setup.token1)),
            POOL_FEE,
            TICK_SPACING,
            SQRT_PRICE_1_1
        );

        deployment.hook = FluidDexT1Aggregator(payable(hookAddress));

        deployment.poolKey = PoolKey({
            currency0: Currency.wrap(address(setup.token0)),
            currency1: Currency.wrap(address(setup.token1)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddress)
        });

        deployment.poolId = deployment.poolKey.toId();
    }

    /// @notice Setup alice with tokens and approvals
    /// @dev Transfers tokens from test contract (already minted in _deployAndInitializeFluidPool)
    function _setupAlice(MockERC20 token0, MockERC20 token1, uint256 amount0, uint256 amount1) internal {
        // Transfer tokens to alice (we minted 4x in deploy, used 1x for init, have 3x remaining)
        token0.transfer(alice, amount0);
        token1.transfer(alice, amount1);

        vm.startPrank(alice);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        // Seed PoolManager with tokens for swap settlements
        token0.transfer(address(poolManager), amount0);
        token1.transfer(address(poolManager), amount1);
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

    /// @notice Derive exact-in swap parameters including protocol fee
    function _deriveExactInParams(
        HookDeployment memory deployment,
        PoolSetup memory setup,
        uint256 seed,
        uint256 swapIdx,
        bool zeroForOne
    ) internal returns (ExactInParams memory params) {
        uint256 swapSeed = uint256(keccak256(abi.encode(seed, "swap", swapIdx)));
        uint256 minLiquidity = setup.liquidity0 < setup.liquidity1 ? setup.liquidity0 : setup.liquidity1;
        params.amountIn = _deriveSwapAmount(swapSeed, minLiquidity);
        params.expectedOut = deployment.hook.quote(zeroForOne, -int256(params.amountIn), deployment.poolId);
        uint24 protocolFee = _deriveProtocolFee(seed) * 25;
        params.expectedFee = (params.expectedOut * protocolFee) / (ProtocolFeeLibrary.PIPS_DENOMINATOR - protocolFee);
    }

    /// @notice Derive exact-out swap parameters including protocol fee
    function _deriveExactOutParams(
        HookDeployment memory deployment,
        PoolSetup memory setup,
        uint256 seed,
        uint256 swapIdx,
        bool zeroForOne
    ) internal returns (ExactOutParams memory params) {
        uint256 swapSeed = uint256(keccak256(abi.encode(seed, "swap", swapIdx)));
        uint256 minLiquidity = setup.liquidity0 < setup.liquidity1 ? setup.liquidity0 : setup.liquidity1;
        params.amountOut = _deriveSwapAmount(swapSeed, minLiquidity) / 10;
        if (params.amountOut == 0) params.amountOut = 1 ether;
        params.expectedIn = deployment.hook.quote(zeroForOne, int256(params.amountOut), deployment.poolId);
        uint24 protocolFee = _deriveProtocolFee(seed) * 25;
        params.expectedFee = (params.expectedIn * protocolFee) / ProtocolFeeLibrary.PIPS_DENOMINATOR;
    }

    // ========== SWAP HELPERS ==========

    function _executeExactInSwap(
        HookDeployment memory deployment,
        PoolSetup memory setup,
        uint256 seed,
        uint256 swapIdx,
        bool zeroForOne
    ) internal {
        ExactInParams memory params = _deriveExactInParams(deployment, setup, seed, swapIdx, zeroForOne);
        assertGt(params.expectedOut, 0, "Quote should be non-zero");

        MockERC20 tokenIn = zeroForOne ? setup.token0 : setup.token1;
        MockERC20 tokenOut = zeroForOne ? setup.token1 : setup.token0;

        uint256 tokenInBefore = tokenIn.balanceOf(alice);
        uint256 tokenOutBefore = tokenOut.balanceOf(alice);
        uint256 tokenJarBefore = tokenOut.balanceOf(tokenJar);

        vm.prank(alice);
        swapRouter.swap(
            deployment.poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(params.amountIn),
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(tokenInBefore - tokenIn.balanceOf(alice), params.amountIn, "Should spend exact input amount");
        assertEq(
            tokenOut.balanceOf(alice) - tokenOutBefore, params.expectedOut, "Received amount should match quoted output"
        );
        assertApproxEqAbs(
            tokenOut.balanceOf(tokenJar) - tokenJarBefore,
            params.expectedFee,
            1,
            "Token jar should receive protocol fee"
        );
    }

    function _executeExactOutSwap(
        HookDeployment memory deployment,
        PoolSetup memory setup,
        uint256 seed,
        uint256 swapIdx,
        bool zeroForOne
    ) internal {
        ExactOutParams memory params = _deriveExactOutParams(deployment, setup, seed, swapIdx, zeroForOne);
        assertGt(params.expectedIn, 0, "Quote should be non-zero");

        MockERC20 tokenIn = zeroForOne ? setup.token0 : setup.token1;
        MockERC20 tokenOut = zeroForOne ? setup.token1 : setup.token0;

        uint256 tokenInBefore = tokenIn.balanceOf(alice);
        uint256 tokenOutBefore = tokenOut.balanceOf(alice);
        uint256 tokenJarBefore = tokenIn.balanceOf(tokenJar);

        vm.prank(alice);
        swapRouter.swap(
            deployment.poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(params.amountOut),
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(tokenOut.balanceOf(alice) - tokenOutBefore, params.amountOut, "Should receive exact output amount");
        assertEq(tokenInBefore - tokenIn.balanceOf(alice), params.expectedIn, "Input should match quoted input");
        assertApproxEqAbs(
            tokenIn.balanceOf(tokenJar) - tokenJarBefore, params.expectedFee, 1, "Token jar should receive protocol fee"
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

    /// @notice Derive swap amount based on pool liquidity
    function _deriveSwapAmount(uint256 seed, uint256 _liquidity) internal pure returns (uint256) {
        uint256 minSwap = _liquidity / MIN_SWAP_DIVISOR;
        uint256 maxSwap = _liquidity / MAX_SWAP_DIVISOR;
        return bound(uint256(keccak256(abi.encode(seed, "amount"))), minSwap, maxSwap);
    }

    /// @notice Derive protocol fee from seed (0 to MAX_PROTOCOL_FEE)
    function _deriveProtocolFee(uint256 seed) internal pure returns (uint24) {
        return
            uint24(bound(uint256(keccak256(abi.encode(seed, "protocolFee"))), 0, ProtocolFeeLibrary.MAX_PROTOCOL_FEE));
    }

    receive() external payable {}
}
