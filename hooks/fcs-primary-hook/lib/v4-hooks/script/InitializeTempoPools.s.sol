// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITempoExchange} from "../src/aggregator-hooks/implementations/TempoExchange/interfaces/ITempoExchange.sol";
import {ITIP20} from "../src/aggregator-hooks/implementations/TempoExchange/interfaces/ITIP20.sol";
import {SafePoolSwapTest} from "../test/aggregator-hooks/shared/SafePoolSwapTest.sol";

/// @title InitializeTempoPools
/// @notice Discovers TIP-20 tokens via FFI, initializes V4 pools for each (token, quoteToken) pair,
///         seeds the hook for gas optimization, and executes a test swap per pool.
/// @dev Use env vars to target testnet vs prod:
///      - TEMPO_RPC_KEY: key in foundry.toml [rpc_endpoints] for token discovery (default "tempo_testnet"; use "tempo_mainnet" for prod)
///      - POOL_MANAGER, TEMPO_EXCHANGE, PATH_USD: contract addresses (testnet defaults below; set for prod)
contract InitializeTempoPools is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant DEFAULT_POOL_MANAGER = 0x33620f62C5b9B2086dD6b62F4A297A9f30347029;
    address constant DEFAULT_TEMPO_EXCHANGE = 0xDEc0000000000000000000000000000000000000;
    address constant DEFAULT_PATH_USD = 0x20C0000000000000000000000000000000000000;

    uint24 constant POOL_FEE = 500;
    int24 constant TICK_SPACING = 10;
    uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;

    // Default min liquidity: 1000 tokens at 6 decimals
    uint256 constant DEFAULT_MIN_LIQUIDITY = 1_000_000_000;

    struct Config {
        IPoolManager pm;
        ITempoExchange exchange;
        SafePoolSwapTest router;
        address hookAddr;
        address pathUsd;
        uint256 minLiquidity;
    }

    struct PoolRecord {
        PoolKey key;
        PoolId id;
        string symbol0;
        string symbol1;
        uint256 tvl0;
        uint256 tvl1;
    }

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        Config memory cfg = _loadConfig();

        console.log("=== TEMPO POOL INITIALIZATION ===");
        console.log("Deployer:", vm.addr(deployerKey));
        console.log("Hook:", cfg.hookAddr);
        console.log("Router:", address(cfg.router));
        console.log("Min liquidity:", cfg.minLiquidity);

        address[] memory tokens = _discoverTokens();
        console.log("Discovered tokens:", tokens.length);

        PoolRecord[] memory records = new PoolRecord[](tokens.length);
        uint256 poolCount = 0;

        vm.startBroadcast(deployerKey);

        for (uint256 i = 0; i < tokens.length; i++) {
            (bool initialized, PoolRecord memory record) = _processToken(tokens[i], cfg);
            if (initialized) {
                records[poolCount++] = record;
            }
        }

        vm.stopBroadcast();

        _writeResults(records, poolCount);
    }

    function _loadConfig() internal view returns (Config memory) {
        return Config({
            pm: IPoolManager(vm.envOr("POOL_MANAGER", DEFAULT_POOL_MANAGER)),
            exchange: ITempoExchange(vm.envOr("TEMPO_EXCHANGE", DEFAULT_TEMPO_EXCHANGE)),
            router: SafePoolSwapTest(payable(vm.envAddress("ROUTER_ADDRESS"))),
            hookAddr: vm.envAddress("HOOK_ADDRESS"),
            pathUsd: vm.envOr("PATH_USD", DEFAULT_PATH_USD),
            minLiquidity: vm.envOr("MIN_LIQUIDITY", DEFAULT_MIN_LIQUIDITY)
        });
    }

    function _discoverTokens() internal returns (address[] memory) {
        string memory defaultRpcKey = "tempo_testnet";
        string memory rpcUrl = vm.rpcUrl(vm.envOr("TEMPO_RPC_KEY", defaultRpcKey));

        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = "script/util/fetch_tempo_tokens.sh";
        cmd[2] = rpcUrl;
        return abi.decode(vm.ffi(cmd), (address[]));
    }

    function _processToken(address token, Config memory cfg)
        internal
        returns (bool initialized, PoolRecord memory record)
    {
        // Skip root token (PathUSD has no parent pair)
        address parent = ITIP20(token).quoteToken();
        if (parent == address(0)) {
            console.log("Skipping root token:", ITIP20(token).symbol());
            return (false, record);
        }

        // Check liquidity
        if (IERC20(token).balanceOf(address(cfg.exchange)) < cfg.minLiquidity) {
            console.log("Skipping low-liquidity token:", ITIP20(token).symbol());
            return (false, record);
        }

        // Order tokens (lower address = currency0)
        address token0 = token < parent ? token : parent;
        address token1 = token < parent ? parent : token;

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(cfg.hookAddr)
        });
        PoolId poolId = poolKey.toId();

        // Skip if already initialized
        (uint160 sqrtPriceX96,,,) = cfg.pm.getSlot0(poolId);
        if (sqrtPriceX96 != 0) {
            console.log("Skipping already initialized pool:", ITIP20(token0).symbol(), "/", ITIP20(token1).symbol());
            return (false, record);
        }

        cfg.pm.initialize(poolKey, SQRT_PRICE_1_1);
        console.log("Initialized pool:", ITIP20(token0).symbol(), "/", ITIP20(token1).symbol());

        // Seed hook with 1 unit of each token for gas optimization
        _seedToken(token0, cfg.hookAddr, cfg.exchange, cfg.pathUsd);
        _seedToken(token1, cfg.hookAddr, cfg.exchange, cfg.pathUsd);
        console.log("  Seeded hook with 1 unit of each token");

        // Test swap (100 tokens exact-input, token0 -> token1)
        _testSwap(cfg.router, poolKey, token0, token1);
        console.log("  Test swap OK (100 tokens)");

        record = PoolRecord({
            key: poolKey,
            id: poolId,
            symbol0: ITIP20(token0).symbol(),
            symbol1: ITIP20(token1).symbol(),
            tvl0: IERC20(token0).balanceOf(address(cfg.exchange)),
            tvl1: IERC20(token1).balanceOf(address(cfg.exchange))
        });
        return (true, record);
    }

    function _testSwap(SafePoolSwapTest router, PoolKey memory poolKey, address token0, address token1) internal {
        uint256 swapAmount = 100 * 1e6;
        IERC20(token0).approve(address(router), type(uint256).max);
        IERC20(token1).approve(address(router), type(uint256).max);

        router.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(swapAmount), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _seedToken(address token, address hook, ITempoExchange exchange, address pathUsd) internal {
        if (IERC20(token).balanceOf(hook) > 0) return; // already seeded

        if (token == pathUsd) {
            IERC20(pathUsd).transfer(hook, 1);
        } else {
            IERC20(pathUsd).approve(address(exchange), type(uint256).max);
            exchange.swapExactAmountOut(pathUsd, token, 1, type(uint128).max);
            IERC20(token).transfer(hook, 1);
        }
    }

    function _writeResults(PoolRecord[] memory records, uint256 poolCount) internal {
        string memory md = "# Tempo Pools\n\n";
        md = string.concat(md, "Auto-generated by `InitializeTempoPools` script.\n\n");
        md = string.concat(md, "| Pool | Token0 | Token1 | TVL0 | TVL1 | Pool ID |\n");
        md = string.concat(md, "|------|--------|--------|------|------|---------|\n");

        for (uint256 i = 0; i < poolCount; i++) {
            PoolRecord memory r = records[i];
            md = string.concat(
                md,
                "| ",
                r.symbol0,
                "/",
                r.symbol1,
                " | ",
                r.symbol0,
                " | ",
                r.symbol1,
                " | ",
                vm.toString(r.tvl0),
                " | ",
                vm.toString(r.tvl1),
                " | `",
                vm.toString(PoolId.unwrap(r.id)),
                "` |\n"
            );
        }

        md = string.concat(md, "\nTotal pools initialized: ", vm.toString(poolCount), "\n");

        vm.writeFile("docs/TempoPools.md", md);
        console.log("");
        console.log("=== COMPLETE ===");
        console.log("Pools initialized:", poolCount);
        console.log("Results written to docs/TempoPools.md");
    }
}
