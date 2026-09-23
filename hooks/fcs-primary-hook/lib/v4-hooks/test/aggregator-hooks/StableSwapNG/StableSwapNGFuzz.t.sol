// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";
import {MockV4FeeAdapter} from "../mocks/MockV4FeeAdapter.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SafePoolSwapTest} from "../shared/SafePoolSwapTest.sol";
import {
    ICurveStableSwapFactoryNG
} from "../../../src/aggregator-hooks/implementations/StableSwapNG/interfaces/ICurveStableSwapFactoryNG.sol";
import {
    ICurveStableSwapNG
} from "../../../src/aggregator-hooks/implementations/StableSwapNG/interfaces/ICurveStableSwapNG.sol";
import {
    StableSwapNGAggregator
} from "../../../src/aggregator-hooks/implementations/StableSwapNG/StableSwapNGAggregator.sol";
import {
    StableSwapNGAggregatorFactory
} from "../../../src/aggregator-hooks/implementations/StableSwapNG/StableSwapNGAggregatorFactory.sol";

/// @title StableSwapNGFuzz
/// @notice Fuzz tests for StableSwapNG through Uniswap V4 hooks
/// @dev Deploys Curve pools and V4 hooks locally for comprehensive testing
/// @dev Heavy external-integration suite; pinned low to keep CI fast (global default is raised in foundry.toml).
/// forge-config: default.fuzz.runs = 10
contract StableSwapNGFuzz is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // V4 Pool configuration
    uint24 constant POOL_FEE = 500; // 0.05%
    int24 constant TICK_SPACING = 10;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 1:1 price

    // Price limits for swaps
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    // Curve pool parameters
    uint256 constant DEFAULT_A = 200;
    uint256 constant DEFAULT_FEE = 4000000;
    uint256 constant DEFAULT_OFFPEG_FEE_MULTIPLIER = 20000000000;
    uint256 constant DEFAULT_MA_EXP_TIME = 866;

    // Storage slots for Curve factory
    uint256 constant SLOT_ADMIN = 0;
    uint256 constant SLOT_MATH_IMPL = 0x20000000a;
    uint256 constant SLOT_VIEWS_IMPL = 0x20000000c;
    uint256 constant SLOT_FEE_RECEIVER = 0x20000000d;
    uint256 constant SLOT_POOL_IMPL_BASE = 0x200000008;

    // Precompiled bytecode paths
    string constant FACTORY_BYTECODE_PATH = "test/aggregator-hooks/StableSwapNG/precompiled/StableSwapNGFactory.bin";
    string constant POOL_BYTECODE_PATH = "test/aggregator-hooks/StableSwapNG/precompiled/StableSwapNGPool.bin";
    string constant MATH_BYTECODE_PATH = "test/aggregator-hooks/StableSwapNG/precompiled/StableSwapNGMath.bin";
    string constant VIEWS_BYTECODE_PATH = "test/aggregator-hooks/StableSwapNG/precompiled/StableSwapNGViews.bin";

    // Contracts
    IPoolManager public manager;
    MockV4FeeAdapter public feeAdapter;
    SafePoolSwapTest public swapRouter;
    ICurveStableSwapFactoryNG public curveFactory;
    StableSwapNGAggregatorFactory public hookFactory;

    address public mathImpl;
    address public viewsImpl;
    address public poolImpl;
    address public curveOwner;
    address public curveFeeReceiver;

    address public alice = makeAddr("alice");

    function setUp() public {
        curveOwner = makeAddr("curveOwner");
        curveFeeReceiver = makeAddr("curveFeeReceiver");

        // Deploy Uniswap V4 PoolManager
        manager = IPoolManager(vm.deployCode("foundry-out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));

        // Deploy swap router
        swapRouter = new SafePoolSwapTest(manager);
        feeAdapter = new MockV4FeeAdapter(manager, address(this));

        // Set this contract as the protocol fee controller
        manager.setProtocolFeeController(address(feeAdapter));

        // Deploy Curve factory from precompiled bytecode
        curveFactory = ICurveStableSwapFactoryNG(_deployFromBytecode(FACTORY_BYTECODE_PATH));
        mathImpl = _deployFromBytecode(MATH_BYTECODE_PATH);
        viewsImpl = _deployFromBytecode(VIEWS_BYTECODE_PATH);
        poolImpl = _deployFromBytecode(POOL_BYTECODE_PATH);

        // Initialize Curve factory storage
        vm.store(address(curveFactory), bytes32(SLOT_ADMIN), bytes32(uint256(uint160(curveOwner))));
        vm.store(address(curveFactory), bytes32(SLOT_FEE_RECEIVER), bytes32(uint256(uint160(curveFeeReceiver))));
        vm.store(address(curveFactory), bytes32(SLOT_MATH_IMPL), bytes32(uint256(uint160(mathImpl))));
        vm.store(address(curveFactory), bytes32(SLOT_VIEWS_IMPL), bytes32(uint256(uint160(viewsImpl))));

        bytes32 poolImplSlot = keccak256(abi.encode(SLOT_POOL_IMPL_BASE, uint256(0)));
        vm.store(address(curveFactory), poolImplSlot, bytes32(uint256(uint160(poolImpl))));

        // Deploy hook factory (uses curveFactory for is_meta check)
        hookFactory = new StableSwapNGAggregatorFactory(manager, curveFactory);
    }

    /// @notice Deploy contract from hex bytecode file
    function _deployFromBytecode(string memory path) internal returns (address deployed) {
        bytes memory bytecode = vm.parseBytes(vm.readFile(path));
        require(bytecode.length > 0, "Empty bytecode");
        deployed = address(uint160(uint256(keccak256(abi.encodePacked(path, "v1")))));
        vm.etch(deployed, bytecode);
        require(deployed.code.length > 0, "Deployment failed");
    }

    /// @notice Deploy a Curve pool with two tokens and custom amplification
    function _deployCurvePool(MockERC20 token0, MockERC20 token1, uint256 amplification)
        internal
        returns (address pool)
    {
        address[] memory coins = new address[](2);
        coins[0] = address(token0);
        coins[1] = address(token1);

        uint8[] memory assetTypes = new uint8[](2);
        bytes4[] memory methodIds = new bytes4[](2);
        address[] memory oracles = new address[](2);

        pool = curveFactory.deploy_plain_pool(
            "Test Pool",
            "TP",
            coins,
            amplification,
            DEFAULT_FEE,
            DEFAULT_OFFPEG_FEE_MULTIPLIER,
            DEFAULT_MA_EXP_TIME,
            0,
            assetTypes,
            methodIds,
            oracles
        );
    }

    /// @notice Add liquidity to a Curve pool
    function _addCurveLiquidity(address pool, MockERC20 token0, MockERC20 token1, uint256 amount0, uint256 amount1)
        internal
    {
        token0.mint(address(this), amount0);
        token1.mint(address(this), amount1);
        token0.approve(pool, amount0);
        token1.approve(pool, amount1);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount0;
        amounts[1] = amount1;

        (bool success,) =
            pool.call(abi.encodeWithSignature("add_liquidity(uint256[],uint256,address)", amounts, 0, address(this)));
        require(success, "Add liquidity failed");
    }

    /// @notice Deploy a Curve pool with N tokens and custom amplification
    function _deployCurvePoolMulti(MockERC20[] memory tokens, uint256 amplification) internal returns (address pool) {
        uint256 numTokens = tokens.length;
        address[] memory coins = new address[](numTokens);
        for (uint256 i = 0; i < numTokens; i++) {
            coins[i] = address(tokens[i]);
        }

        uint8[] memory assetTypes = new uint8[](numTokens);
        bytes4[] memory methodIds = new bytes4[](numTokens);
        address[] memory oracles = new address[](numTokens);

        pool = curveFactory.deploy_plain_pool(
            "Test Multi Pool",
            "TMP",
            coins,
            amplification,
            DEFAULT_FEE,
            DEFAULT_OFFPEG_FEE_MULTIPLIER,
            DEFAULT_MA_EXP_TIME,
            0,
            assetTypes,
            methodIds,
            oracles
        );
    }

    /// @notice Add liquidity to a Curve pool with N tokens
    function _addCurveLiquidityMulti(address pool, MockERC20[] memory tokens, uint256[] memory amounts) internal {
        require(tokens.length == amounts.length, "Array length mismatch");

        for (uint256 i = 0; i < tokens.length; i++) {
            tokens[i].mint(address(this), amounts[i]);
            tokens[i].approve(pool, amounts[i]);
        }

        (bool success,) =
            pool.call(abi.encodeWithSignature("add_liquidity(uint256[],uint256,address)", amounts, 0, address(this)));
        require(success, "Add liquidity failed");
    }

    /// @notice Create and sort N mock tokens by address
    /// @dev Uses seed to create deterministic token addresses
    function _createSortedTokens(uint256 seed, uint256 numTokens) internal returns (MockERC20[] memory tokens) {
        tokens = new MockERC20[](numTokens);

        // Create tokens with unique names
        for (uint256 i = 0; i < numTokens; i++) {
            // Use seed + index to get unique salt for each token
            bytes32 tokenSalt = keccak256(abi.encode(seed, "token", i));
            string memory name = string(abi.encodePacked("Token", vm.toString(i)));
            string memory symbol = string(abi.encodePacked("TK", vm.toString(i)));
            tokens[i] = new MockERC20{salt: tokenSalt}(name, symbol, 18);
        }

        // Sort tokens by address (bubble sort - fine for small arrays)
        for (uint256 i = 0; i < numTokens; i++) {
            for (uint256 j = i + 1; j < numTokens; j++) {
                if (address(tokens[i]) > address(tokens[j])) {
                    (tokens[i], tokens[j]) = (tokens[j], tokens[i]);
                }
            }
        }
    }

    /// @notice Convert MockERC20 array to Currency array
    function _toCurrencies(MockERC20[] memory tokens) internal pure returns (Currency[] memory currencies) {
        currencies = new Currency[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            currencies[i] = Currency.wrap(address(tokens[i]));
        }
    }

    /// @notice Deploy V4 hook for a Curve pool
    function _deployHook(ICurveStableSwapNG curvePool, Currency currency0, Currency currency1)
        internal
        returns (StableSwapNGAggregator hook, PoolKey memory poolKey)
    {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );

        bytes memory constructorArgs = abi.encode(address(manager), address(curvePool), address(curveFactory));
        (address expectedHookAddress, bytes32 salt) =
            HookMiner.find(address(hookFactory), flags, type(StableSwapNGAggregator).creationCode, constructorArgs);

        // Deploy hook via factory
        Currency[] memory tokens = new Currency[](2);
        tokens[0] = currency0;
        tokens[1] = currency1;

        address hookAddress = hookFactory.createPool(salt, curvePool, tokens, POOL_FEE, TICK_SPACING, SQRT_PRICE_1_1);

        require(hookAddress == expectedHookAddress, "Hook address mismatch");
        hook = StableSwapNGAggregator(payable(hookAddress));

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    /// @notice Deploy V4 hook for a multi-token Curve pool
    /// @dev Creates V4 pools for all token pairs (N*(N-1)/2 pools)
    function _deployHookMulti(ICurveStableSwapNG curvePool, Currency[] memory currencies)
        internal
        returns (StableSwapNGAggregator hook)
    {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );

        bytes memory constructorArgs = abi.encode(address(manager), address(curvePool), address(curveFactory));
        (address expectedHookAddress, bytes32 salt) =
            HookMiner.find(address(hookFactory), flags, type(StableSwapNGAggregator).creationCode, constructorArgs);

        // Deploy hook via factory (creates V4 pools for all pairs)
        address hookAddress =
            hookFactory.createPool(salt, curvePool, currencies, POOL_FEE, TICK_SPACING, SQRT_PRICE_1_1);

        require(hookAddress == expectedHookAddress, "Hook address mismatch");
        hook = StableSwapNGAggregator(payable(hookAddress));
    }

    /// @notice Build a PoolKey for a specific token pair
    /// @dev Ensures currency0 < currency1 as required by V4
    function _buildPoolKey(Currency currencyA, Currency currencyB, IHooks hook)
        internal
        pure
        returns (PoolKey memory poolKey)
    {
        (Currency currency0, Currency currency1) = Currency.unwrap(currencyA) < Currency.unwrap(currencyB)
            ? (currencyA, currencyB)
            : (currencyB, currencyA);

        poolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: POOL_FEE, tickSpacing: TICK_SPACING, hooks: hook
        });
    }

    /// @notice Setup alice with multiple tokens
    function _setupAliceMulti(MockERC20[] memory tokens, uint256[] memory amounts) internal {
        require(tokens.length == amounts.length, "Array length mismatch");

        for (uint256 i = 0; i < tokens.length; i++) {
            tokens[i].mint(alice, amounts[i]);
            // Seed PoolManager with tokens for swaps
            tokens[i].mint(address(manager), amounts[i]);
        }

        vm.startPrank(alice);
        for (uint256 i = 0; i < tokens.length; i++) {
            tokens[i].approve(address(swapRouter), type(uint256).max);
        }
        vm.stopPrank();
    }

    /// @notice Setup alice with tokens
    function _setupAlice(MockERC20 token0, MockERC20 token1, uint256 amount0, uint256 amount1) internal {
        token0.mint(alice, amount0);
        token1.mint(alice, amount1);

        vm.startPrank(alice);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        // Seed PoolManager with MORE tokens for swaps (must cover max swap amounts)
        token0.mint(address(manager), amount0);
        token1.mint(address(manager), amount1);
    }

    // ========== FUZZ TESTS ==========

    /// @notice Fuzz test: Exact input swaps, zeroForOne direction
    function testFuzz_exactIn_zeroForOne(uint256 numTokensRaw, uint256 amplificationRaw, uint256 seed) public {
        (
            MockERC20[] memory tokens,
            uint256[] memory balances,
            StableSwapNGAggregator hook,
            Currency[] memory currencies
        ) = _setupPoolAndHook(numTokensRaw, amplificationRaw, seed);

        // Execute 3 exact input swaps (zeroForOne)
        for (uint256 i = 0; i < 3; i++) {
            _executeExactInSwap(hook, tokens, currencies, balances, seed, i, true);
        }
    }

    /// @notice Fuzz test: Exact input swaps, oneForZero direction
    function testFuzz_exactIn_oneForZero(uint256 numTokensRaw, uint256 amplificationRaw, uint256 seed) public {
        (
            MockERC20[] memory tokens,
            uint256[] memory balances,
            StableSwapNGAggregator hook,
            Currency[] memory currencies
        ) = _setupPoolAndHook(numTokensRaw, amplificationRaw, seed);

        // Execute 3 exact input swaps (oneForZero)
        for (uint256 i = 0; i < 3; i++) {
            _executeExactInSwap(hook, tokens, currencies, balances, seed, i, false);
        }
    }

    /// @notice Fuzz test: Exact output swaps, zeroForOne direction
    function testFuzz_exactOut_zeroForOne(uint256 numTokensRaw, uint256 amplificationRaw, uint256 seed) public {
        (
            MockERC20[] memory tokens,
            uint256[] memory balances,
            StableSwapNGAggregator hook,
            Currency[] memory currencies
        ) = _setupPoolAndHook(numTokensRaw, amplificationRaw, seed);

        // Execute 3 exact output swaps (zeroForOne)
        for (uint256 i = 0; i < 3; i++) {
            _executeExactOutSwap(hook, tokens, currencies, balances, seed, i, true);
        }
    }

    /// @notice Fuzz test: Exact output swaps, oneForZero direction
    function testFuzz_exactOut_oneForZero(uint256 numTokensRaw, uint256 amplificationRaw, uint256 seed) public {
        (
            MockERC20[] memory tokens,
            uint256[] memory balances,
            StableSwapNGAggregator hook,
            Currency[] memory currencies
        ) = _setupPoolAndHook(numTokensRaw, amplificationRaw, seed);

        // Execute 3 exact output swaps (oneForZero)
        for (uint256 i = 0; i < 3; i++) {
            _executeExactOutSwap(hook, tokens, currencies, balances, seed, i, false);
        }
    }

    // ========== HELPERS ==========

    /// @notice Helper to setup pool and hook (reduces code duplication)
    function _setupPoolAndHook(uint256 numTokensRaw, uint256 amplificationRaw, uint256 seed)
        internal
        returns (
            MockERC20[] memory tokens,
            uint256[] memory balances,
            StableSwapNGAggregator hook,
            Currency[] memory currencies
        )
    {
        uint256 numTokens = bound(numTokensRaw, 2, 8);
        uint256 amplification = bound(amplificationRaw, 10, 500);

        tokens = _createSortedTokens(seed, numTokens);
        balances = _deriveBalances(seed, numTokens);

        address curvePoolAddr = _deployCurvePoolMulti(tokens, amplification);
        _addCurveLiquidityMulti(curvePoolAddr, tokens, balances);

        currencies = _toCurrencies(tokens);
        hook = _deployHookMulti(ICurveStableSwapNG(curvePoolAddr), currencies);

        _setupAliceMulti(tokens, balances);
    }

    /// @notice Execute an exact input swap and verify the output matches the quote
    function _executeExactInSwap(
        StableSwapNGAggregator hook,
        MockERC20[] memory tokens,
        Currency[] memory currencies,
        uint256[] memory balances,
        uint256 seed,
        uint256 swapIdx,
        bool zeroForOne
    ) internal {
        // Use block scoping to reduce stack depth
        uint256 tokenInIdx;
        uint256 tokenOutIdx;
        uint256 amountIn;
        {
            uint256 swapSeed = uint256(keccak256(abi.encode(seed, "swap", swapIdx)));
            (tokenInIdx, tokenOutIdx) = _deriveSwapPairForDirection(swapSeed, tokens.length, zeroForOne);

            uint256 minPairBalance =
                balances[tokenInIdx] < balances[tokenOutIdx] ? balances[tokenInIdx] : balances[tokenOutIdx];
            amountIn = bound(uint256(keccak256(abi.encode(swapSeed, "amount"))), 1000 ether, minPairBalance / 20);
        }

        PoolKey memory poolKey = _buildPoolKey(currencies[tokenInIdx], currencies[tokenOutIdx], IHooks(address(hook)));

        // Get quote (negative = exact input)
        uint256 expectedOut = hook.quote(zeroForOne, -int256(amountIn), poolKey.toId());
        assertGt(expectedOut, 0, "Quote should be non-zero");

        // Use block scope for balance tracking and swap execution
        {
            MockERC20 tokenIn = tokens[tokenInIdx];
            MockERC20 tokenOut = tokens[tokenOutIdx];
            uint256 tokenInBefore = tokenIn.balanceOf(alice);
            uint256 tokenOutBefore = tokenOut.balanceOf(alice);

            vm.prank(alice);
            swapRouter.swap(
                poolKey,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(amountIn),
                    sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
                }),
                SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );

            assertEq(tokenInBefore - tokenIn.balanceOf(alice), amountIn, "Should spend exact input amount");
            assertEq(tokenOut.balanceOf(alice) - tokenOutBefore, expectedOut, "Received amount should match quote");
        }
    }

    /// @notice Execute an exact output swap and verify the input matches the quote
    function _executeExactOutSwap(
        StableSwapNGAggregator hook,
        MockERC20[] memory tokens,
        Currency[] memory currencies,
        uint256[] memory balances,
        uint256 seed,
        uint256 swapIdx,
        bool zeroForOne
    ) internal {
        // Use block scoping to reduce stack depth
        uint256 tokenInIdx;
        uint256 tokenOutIdx;
        uint256 amountOut;
        {
            uint256 swapSeed = uint256(keccak256(abi.encode(seed, "swap", swapIdx)));
            (tokenInIdx, tokenOutIdx) = _deriveSwapPairForDirection(swapSeed, tokens.length, zeroForOne);

            uint256 minPairBalance =
                balances[tokenInIdx] < balances[tokenOutIdx] ? balances[tokenInIdx] : balances[tokenOutIdx];
            // Use smaller amounts for exact output
            amountOut = bound(uint256(keccak256(abi.encode(swapSeed, "amount"))), 100 ether, minPairBalance / 200);
        }

        PoolKey memory poolKey = _buildPoolKey(currencies[tokenInIdx], currencies[tokenOutIdx], IHooks(address(hook)));

        // Get quote (positive = exact output)
        uint256 expectedIn = hook.quote(zeroForOne, int256(amountOut), poolKey.toId());
        assertGt(expectedIn, 0, "Quote should be non-zero");

        // Use block scope for balance tracking and swap execution
        {
            MockERC20 tokenIn = tokens[tokenInIdx];
            MockERC20 tokenOut = tokens[tokenOutIdx];
            uint256 tokenInBefore = tokenIn.balanceOf(alice);
            uint256 tokenOutBefore = tokenOut.balanceOf(alice);

            vm.prank(alice);
            swapRouter.swap(
                poolKey,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: int256(amountOut),
                    sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
                }),
                SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );

            assertEq(tokenOut.balanceOf(alice) - tokenOutBefore, amountOut, "Should receive exact output amount");
            assertEq(tokenInBefore - tokenIn.balanceOf(alice), expectedIn, "Input amount should match quote");
        }
    }

    /// @notice Derive swap pair indices for a given direction
    function _deriveSwapPairForDirection(uint256 seed, uint256 numTokens, bool zeroForOne)
        internal
        pure
        returns (uint256 tokenInIdx, uint256 tokenOutIdx)
    {
        // Pick two different tokens
        uint256 idx1 = bound(uint256(keccak256(abi.encode(seed, "idx1"))), 0, numTokens - 1);
        uint256 idx2 = bound(uint256(keccak256(abi.encode(seed, "idx2"))), 0, numTokens - 2);
        if (idx2 >= idx1) idx2++;

        // Assign based on direction (lower address = token0)
        if (zeroForOne) {
            tokenInIdx = idx1 < idx2 ? idx1 : idx2;
            tokenOutIdx = idx1 < idx2 ? idx2 : idx1;
        } else {
            tokenInIdx = idx1 < idx2 ? idx2 : idx1;
            tokenOutIdx = idx1 < idx2 ? idx1 : idx2;
        }
    }

    /// @notice Derive initial balances for each token from seed
    /// @dev Minimum balance must be >= 20_000 ether so that minPairBalance / 20 >= 1000 ether (swap min)
    function _deriveBalances(uint256 seed, uint256 numTokens) internal pure returns (uint256[] memory) {
        uint256[] memory balances = new uint256[](numTokens);
        for (uint256 i = 0; i < numTokens; i++) {
            balances[i] = bound(uint256(keccak256(abi.encode(seed, "balance", i))), 20_000 ether, 10_000_000 ether);
        }
        return balances;
    }

    receive() external payable {}
}
