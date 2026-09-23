// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ICurveFactory} from "../../../src/aggregator-hooks/implementations/StableSwap/interfaces/ICurveFactory.sol";
import {ICurveStableSwap} from "../../../src/aggregator-hooks/implementations/StableSwap/interfaces/IStableSwap.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";
import {SafePoolSwapTest} from "../shared/SafePoolSwapTest.sol";
import {MockV4FeeAdapter} from "../mocks/MockV4FeeAdapter.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {StableSwapAggregator} from "../../../src/aggregator-hooks/implementations/StableSwap/StableSwapAggregator.sol";
import {
    StableSwapAggregatorFactory
} from "../../../src/aggregator-hooks/implementations/StableSwap/StableSwapAggregatorFactory.sol";
import {MockMetaRegistry} from "./mocks/MockMetaRegistry.sol";
import {IMetaRegistry} from "../../../src/aggregator-hooks/implementations/StableSwap/interfaces/IMetaRegistry.sol";

/// @title StableSwapFuzz
/// @notice Fuzz tests for StableSwap through Uniswap V4 hooks
/// @dev Deploys Curve pools and V4 hooks locally for comprehensive testing
/// @dev Heavy external-integration suite; pinned low to keep CI fast (global default is raised in foundry.toml).
/// forge-config: default.fuzz.runs = 10
contract StableSwapFuzz is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // V4 Pool configuration
    uint24 constant POOL_FEE = 500; // 0.05%
    int24 constant TICK_SPACING = 10; // Default tick spacing for a 0.05% fee pool
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 1:1 price

    // Price limits for swaps
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    // Curve pool parameters
    uint256 constant DEFAULT_A = 200;
    uint256 constant DEFAULT_FEE = 4000000; // 0.04%
    uint256 constant DEFAULT_ASSET_TYPE = 0; // USD

    // Storage slots for Curve factory (Metapool Factory)
    // The Metapool Factory uses Vyper storage layout
    // admin is at slot 0, fee_receiver is at slot 1
    uint256 constant SLOT_ADMIN = 0;
    uint256 constant SLOT_FEE_RECEIVER = 1;

    // Precompiled bytecode paths
    string constant FACTORY_BYTECODE_PATH = "test/aggregator-hooks/StableSwap/precompiled/StableSwapFactory.bin";
    string constant POOL2_BYTECODE_PATH = "test/aggregator-hooks/StableSwap/precompiled/StableSwapPool2.bin";
    string constant POOL3_BYTECODE_PATH = "test/aggregator-hooks/StableSwap/precompiled/StableSwapPool3.bin";
    string constant POOL4_BYTECODE_PATH = "test/aggregator-hooks/StableSwap/precompiled/StableSwapPool4.bin";

    // Contracts
    IPoolManager public manager;
    SafePoolSwapTest public swapRouter;
    ICurveFactory public curveFactory;
    StableSwapAggregatorFactory public hookFactory;

    address public pool2Impl;
    address public pool3Impl;
    address public pool4Impl;
    address public curveOwner;
    address public curveFeeReceiver;

    address public alice = makeAddr("alice");
    address public tokenJar = makeAddr("tokenJar");
    MockV4FeeAdapter public feeAdapter;
    MockMetaRegistry public mockMetaRegistry;

    error UnsupportedNumberOfTokens();
    error AddLiquidityFailed();

    function setUp() public {
        curveOwner = makeAddr("curveOwner");
        curveFeeReceiver = makeAddr("curveFeeReceiver");

        // Deploy Uniswap V4 PoolManager
        manager = IPoolManager(vm.deployCode("foundry-out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));

        // Deploy swap router
        swapRouter = new SafePoolSwapTest(manager);

        // Deploy fee adapter, mock meta registry, and hook factory
        feeAdapter = new MockV4FeeAdapter(manager, tokenJar);
        mockMetaRegistry = new MockMetaRegistry();
        hookFactory = new StableSwapAggregatorFactory(manager, IMetaRegistry(address(mockMetaRegistry)));

        // Set this contract as the protocol fee controller
        manager.setProtocolFeeController(address(feeAdapter));

        // Deploy Curve factory from precompiled bytecode
        curveFactory = ICurveFactory(_deployFromBytecode(FACTORY_BYTECODE_PATH));
        pool2Impl = _deployFromBytecode(POOL2_BYTECODE_PATH);
        pool3Impl = _deployFromBytecode(POOL3_BYTECODE_PATH);
        pool4Impl = _deployFromBytecode(POOL4_BYTECODE_PATH);

        // Initialize Curve factory storage - set admin and fee receiver
        vm.store(address(curveFactory), bytes32(SLOT_ADMIN), bytes32(uint256(uint160(curveOwner))));
        vm.store(address(curveFactory), bytes32(SLOT_FEE_RECEIVER), bytes32(uint256(uint160(curveFeeReceiver))));

        // Set plain_implementations using the admin function
        // The factory has set_plain_implementations(uint256 _n_coins, address[10] _implementations)
        _setPlainImplementations();
    }

    /// @notice Set plain implementations using admin function
    function _setPlainImplementations() internal {
        // Build implementations arrays for each coin count
        address[10] memory impls2;
        impls2[0] = pool2Impl;

        address[10] memory impls3;
        impls3[0] = pool3Impl;

        address[10] memory impls4;
        impls4[0] = pool4Impl;

        // Call as admin to set implementations
        vm.startPrank(curveOwner);
        (bool success2,) = address(curveFactory)
            .call(abi.encodeWithSignature("set_plain_implementations(uint256,address[10])", 2, impls2));
        require(success2, "Failed to set 2-coin impl");

        (bool success3,) = address(curveFactory)
            .call(abi.encodeWithSignature("set_plain_implementations(uint256,address[10])", 3, impls3));
        require(success3, "Failed to set 3-coin impl");

        (bool success4,) = address(curveFactory)
            .call(abi.encodeWithSignature("set_plain_implementations(uint256,address[10])", 4, impls4));
        require(success4, "Failed to set 4-coin impl");
        vm.stopPrank();
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
        // Use address[4] with zeros for unused slots
        address[4] memory coins = [address(token0), address(token1), address(0), address(0)];

        pool =
            curveFactory.deploy_plain_pool("Test Pool", "TP", coins, amplification, DEFAULT_FEE, DEFAULT_ASSET_TYPE, 0);
    }

    /// @notice Add liquidity to a Curve pool
    function _addCurveLiquidity(address pool, MockERC20 token0, MockERC20 token1, uint256 amount0, uint256 amount1)
        internal
    {
        token0.mint(address(this), amount0);
        token1.mint(address(this), amount1);
        token0.approve(pool, amount0);
        token1.approve(pool, amount1);

        // StableSwap uses fixed-size arrays: add_liquidity(uint256[2], uint256)
        uint256[2] memory amounts = [amount0, amount1];
        (bool success,) = pool.call(abi.encodeWithSignature("add_liquidity(uint256[2],uint256)", amounts, 0));
        require(success, "Add liquidity failed");
    }

    /// @notice Deploy a Curve pool with N tokens and custom amplification
    /// @dev Uses address[4] with zeros for unused slots (Curve factory requirement)
    function _deployCurvePoolMulti(MockERC20[] memory tokens, uint256 amplification) internal returns (address pool) {
        uint256 numTokens = tokens.length;
        require(numTokens >= 2 && numTokens <= 4, "Unsupported number of tokens");

        // Build address[4] array with zeros for unused slots
        address[4] memory coins;
        for (uint256 i = 0; i < numTokens; i++) {
            coins[i] = address(tokens[i]);
        }
        // Remaining slots are already address(0) by default

        pool = curveFactory.deploy_plain_pool(
            "Test Multi Pool", "TMP", coins, amplification, DEFAULT_FEE, DEFAULT_ASSET_TYPE, 0
        );
    }

    /// @notice Add liquidity to a Curve pool with N tokens
    function _addCurveLiquidityMulti(address pool, MockERC20[] memory tokens, uint256[] memory amounts) internal {
        require(tokens.length == amounts.length, "Array length mismatch");
        uint256 numTokens = tokens.length;

        for (uint256 i = 0; i < numTokens; i++) {
            tokens[i].mint(address(this), amounts[i]);
            tokens[i].approve(pool, amounts[i]);
        }

        // StableSwap uses fixed-size arrays: add_liquidity(uint256[N], uint256)
        // Each coin count has a different function selector
        bool success;
        if (numTokens == 2) {
            uint256[2] memory fixedAmounts = [amounts[0], amounts[1]];
            (success,) = pool.call(abi.encodeWithSignature("add_liquidity(uint256[2],uint256)", fixedAmounts, 0));
        } else if (numTokens == 3) {
            uint256[3] memory fixedAmounts = [amounts[0], amounts[1], amounts[2]];
            (success,) = pool.call(abi.encodeWithSignature("add_liquidity(uint256[3],uint256)", fixedAmounts, 0));
        } else if (numTokens == 4) {
            uint256[4] memory fixedAmounts = [amounts[0], amounts[1], amounts[2], amounts[3]];
            (success,) = pool.call(abi.encodeWithSignature("add_liquidity(uint256[4],uint256)", fixedAmounts, 0));
        } else {
            revert UnsupportedNumberOfTokens();
        }
        if (!success) revert AddLiquidityFailed();
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
    function _deployHook(ICurveStableSwap curvePool, Currency currency0, Currency currency1)
        internal
        returns (StableSwapAggregator hook, PoolKey memory poolKey)
    {
        mockMetaRegistry.setIsRegistered(address(curvePool), true);

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );

        bytes memory constructorArgs = abi.encode(address(manager), address(curvePool), address(mockMetaRegistry));
        (address expectedHookAddress, bytes32 salt) =
            HookMiner.find(address(hookFactory), flags, type(StableSwapAggregator).creationCode, constructorArgs);

        // Deploy hook via factory
        Currency[] memory tokens = new Currency[](2);
        tokens[0] = currency0;
        tokens[1] = currency1;

        address hookAddress = hookFactory.createPool(salt, curvePool, tokens, POOL_FEE, TICK_SPACING, SQRT_PRICE_1_1);

        require(hookAddress == expectedHookAddress, "Hook address mismatch");
        hook = StableSwapAggregator(payable(hookAddress));

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
    function _deployHookMulti(ICurveStableSwap curvePool, Currency[] memory currencies)
        internal
        returns (StableSwapAggregator hook)
    {
        mockMetaRegistry.setIsRegistered(address(curvePool), true);

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );

        bytes memory constructorArgs = abi.encode(address(manager), address(curvePool), address(mockMetaRegistry));
        (address expectedHookAddress, bytes32 salt) =
            HookMiner.find(address(hookFactory), flags, type(StableSwapAggregator).creationCode, constructorArgs);

        // Deploy hook via factory (creates V4 pools for all pairs)
        address hookAddress =
            hookFactory.createPool(salt, curvePool, currencies, POOL_FEE, TICK_SPACING, SQRT_PRICE_1_1);

        require(hookAddress == expectedHookAddress, "Hook address mismatch");
        hook = StableSwapAggregator(payable(hookAddress));
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
            StableSwapAggregator hook,
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
            StableSwapAggregator hook,
            Currency[] memory currencies
        ) = _setupPoolAndHook(numTokensRaw, amplificationRaw, seed);

        // Execute 3 exact input swaps (oneForZero)
        for (uint256 i = 0; i < 3; i++) {
            _executeExactInSwap(hook, tokens, currencies, balances, seed, i, false);
        }
    }

    // NOTE: StableSwap (non-NG) does not support exact output swaps
    // The pool's exchange() function only supports exact-in, and there's no get_dx() for computing exact-out

    /// @notice Regression test: protocol fee rounding (1-wei difference from integer division truncation)
    /// @dev Counterexample from fuzz run: testFuzz_exactIn_oneForZero(53, 102089634039300134962802909115238314461027419237443557584673670268305811701761, 4339)
    function test_repro_protocolFeeRounding() public {
        testFuzz_exactIn_oneForZero(
            53, 102089634039300134962802909115238314461027419237443557584673670268305811701761, 4339
        );
    }

    // ========== HELPERS ==========

    /// @notice Helper to setup pool and hook (reduces code duplication)
    function _setupPoolAndHook(uint256 numTokensRaw, uint256 amplificationRaw, uint256 seed)
        internal
        returns (
            MockERC20[] memory tokens,
            uint256[] memory balances,
            StableSwapAggregator hook,
            Currency[] memory currencies
        )
    {
        // StableSwap supports 2-4 coins
        uint256 numTokens = bound(numTokensRaw, 2, 4);
        uint256 amplification = bound(amplificationRaw, 10, 500);

        tokens = _createSortedTokens(seed, numTokens);
        balances = _deriveBalances(seed, numTokens);

        address curvePoolAddr = _deployCurvePoolMulti(tokens, amplification);
        _addCurveLiquidityMulti(curvePoolAddr, tokens, balances);

        currencies = _toCurrencies(tokens);
        hook = _deployHookMulti(ICurveStableSwap(curvePoolAddr), currencies);

        // Derive and set protocol fee from seed
        uint24 protocolFee = _deriveProtocolFee(seed);
        if (protocolFee > 0) {
            uint24 packed = (protocolFee << 12) | protocolFee;
            for (uint256 i = 0; i < currencies.length; i++) {
                for (uint256 j = i + 1; j < currencies.length; j++) {
                    PoolKey memory poolKey = _buildPoolKey(currencies[i], currencies[j], IHooks(address(hook)));
                    vm.prank(address(feeAdapter));
                    manager.setProtocolFee(poolKey, packed);
                }
            }
        }

        _setupAliceMulti(tokens, balances);
    }

    /// @dev Struct to bundle swap context and reduce stack depth
    struct SwapContext {
        uint256 tokenInIdx;
        uint256 tokenOutIdx;
        uint256 amountIn;
        uint256 expectedOut;
        uint256 expectedFeeAmount;
        bool zeroForOne;
    }

    /// @notice Derive swap context including protocol fee from seed
    function _deriveSwapContext(
        StableSwapAggregator hook,
        MockERC20[] memory tokens,
        Currency[] memory currencies,
        uint256[] memory balances,
        uint256 seed,
        uint256 swapIdx,
        bool zeroForOne
    ) internal returns (SwapContext memory ctx, PoolKey memory poolKey) {
        ctx.zeroForOne = zeroForOne;
        uint256 swapSeed = uint256(keccak256(abi.encode(seed, "swap", swapIdx)));
        (ctx.tokenInIdx, ctx.tokenOutIdx) = _deriveSwapPairForDirection(swapSeed, tokens.length, zeroForOne);
        uint256 minPairBalance =
            balances[ctx.tokenInIdx] < balances[ctx.tokenOutIdx] ? balances[ctx.tokenInIdx] : balances[ctx.tokenOutIdx];
        ctx.amountIn = bound(uint256(keccak256(abi.encode(swapSeed, "amount"))), 1000 ether, minPairBalance / 20);
        poolKey = _buildPoolKey(currencies[ctx.tokenInIdx], currencies[ctx.tokenOutIdx], IHooks(address(hook)));
        ctx.expectedOut = hook.quote(ctx.zeroForOne, -int256(ctx.amountIn), poolKey.toId());
        uint24 protocolFee = _deriveProtocolFee(seed) * 25;
        ctx.expectedFeeAmount = (ctx.expectedOut * protocolFee) / (ProtocolFeeLibrary.PIPS_DENOMINATOR - protocolFee);
    }

    /// @notice Execute an exact input swap and verify the output matches the quote
    function _executeExactInSwap(
        StableSwapAggregator hook,
        MockERC20[] memory tokens,
        Currency[] memory currencies,
        uint256[] memory balances,
        uint256 seed,
        uint256 swapIdx,
        bool zeroForOne
    ) internal {
        (SwapContext memory ctx, PoolKey memory poolKey) =
            _deriveSwapContext(hook, tokens, currencies, balances, seed, swapIdx, zeroForOne);
        assertGt(ctx.expectedOut, 0, "Quote should be non-zero");

        uint256 tokenInBefore = tokens[ctx.tokenInIdx].balanceOf(alice);
        uint256 tokenOutBefore = tokens[ctx.tokenOutIdx].balanceOf(alice);
        uint256 tokenJarBefore = tokens[ctx.tokenOutIdx].balanceOf(tokenJar);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: ctx.zeroForOne,
                amountSpecified: -int256(ctx.amountIn),
                sqrtPriceLimitX96: ctx.zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(
            tokenInBefore - tokens[ctx.tokenInIdx].balanceOf(alice), ctx.amountIn, "Should spend exact input amount"
        );
        assertEq(
            tokens[ctx.tokenOutIdx].balanceOf(alice) - tokenOutBefore,
            ctx.expectedOut,
            "Received amount should match quoted output"
        );
        // Allow 1-wei tolerance: the test reverse-computes fee from post-fee output
        // (expectedOut * fee / (PIPS - fee)), but the contract computes fee from raw output
        // (rawOutput * fee / PIPS). Integer division truncation causes up to 1-wei difference.
        assertApproxEqAbs(
            tokens[ctx.tokenOutIdx].balanceOf(tokenJar) - tokenJarBefore,
            ctx.expectedFeeAmount,
            2,
            "Token jar should receive protocol fee"
        );
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

    /// @notice Derive protocol fee from seed (0 to MAX_PROTOCOL_FEE)
    function _deriveProtocolFee(uint256 seed) internal pure returns (uint24) {
        return
            uint24(bound(uint256(keccak256(abi.encode(seed, "protocolFee"))), 0, ProtocolFeeLibrary.MAX_PROTOCOL_FEE));
    }

    receive() external payable {}
}
