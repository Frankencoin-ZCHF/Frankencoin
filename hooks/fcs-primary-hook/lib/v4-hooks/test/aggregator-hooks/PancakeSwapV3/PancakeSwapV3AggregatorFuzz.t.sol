// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";
import {SafePoolSwapTest} from "../shared/SafePoolSwapTest.sol";
import {
    PancakeSwapV3Aggregator
} from "../../../src/aggregator-hooks/implementations/PancakeSwapV3/PancakeSwapV3Aggregator.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPancakeV3Factory} from "@pancakeswap/v3-core/interfaces/IPancakeV3Factory.sol";
import {IPancakeV3Pool} from "@pancakeswap/v3-core/interfaces/IPancakeV3Pool.sol";
import {IPancakeV3PoolDeployer} from "./mocks/IPancakeV3PoolDeployer.sol";
import {PancakeV3MintHelper} from "./mocks/PancakeV3MintHelper.sol";
import "forge-std/Test.sol";

/// @notice Fuzz with canonical PancakeSwap V3 bytecode: pool deployer + factory.
/// @dev Precompile `.bin` files are **creation** bytecode for `CREATE` (not runtime `eth_getCode`).
contract PancakeSwapV3AggregatorFuzz is Test {
    using PoolIdLibrary for PoolKey;

    string constant POOL_DEPLOYER_BYTECODE_PATH =
        "test/aggregator-hooks/PancakeSwapV3/precompile/PancakeV3PoolDeployer.bin";
    string constant FACTORY_BYTECODE_PATH = "test/aggregator-hooks/PancakeSwapV3/precompile/PancakeV3Factory.bin";

    /// @dev Pancake factory enables 100 / 500 / 2500 (not 3000) / 10000 bps.
    uint24 constant POOL_FEE = 2500;
    int24 constant TICK_LOWER = -500;
    int24 constant TICK_UPPER = 500;
    uint128 constant LIQUIDITY_AMOUNT = 1e24;

    IPoolManager public poolManager;
    SafePoolSwapTest public swapRouter;
    PancakeSwapV3Aggregator public hook;

    IPancakeV3Factory public factory;
    address public extPool;

    MockERC20 public token0;
    MockERC20 public token1;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant MIN_PRICE = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE = TickMath.MAX_SQRT_PRICE - 1;

    address public alice = makeAddr("alice");
    PoolKey public poolKey;
    PoolId public poolId;

    function setUp() public {
        poolManager =
            IPoolManager(vm.deployCode("foundry-out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        swapRouter = new SafePoolSwapTest(poolManager);

        address poolDeployer = _deployCreate(POOL_DEPLOYER_BYTECODE_PATH);
        bytes memory factoryBytecode = _readPrecompileHex(FACTORY_BYTECODE_PATH);
        bytes memory factoryCreation = abi.encodePacked(factoryBytecode, abi.encode(poolDeployer));
        address factoryAddr = _deployCreateBytecode(factoryCreation);
        IPancakeV3PoolDeployer(poolDeployer).setFactoryAddress(factoryAddr);
        factory = IPancakeV3Factory(factoryAddr);

        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        if (address(token0) > address(token1)) (token0, token1) = (token1, token0);

        extPool = factory.createPool(address(token0), address(token1), POOL_FEE);
        IPancakeV3Pool(extPool).initialize(SQRT_PRICE_1_1);

        PancakeV3MintHelper mintHelper = new PancakeV3MintHelper();
        token0.mint(address(this), type(uint128).max);
        token1.mint(address(this), type(uint128).max);
        token0.approve(address(mintHelper), type(uint256).max);
        token1.approve(address(mintHelper), type(uint256).max);
        mintHelper.mint(extPool, address(this), TICK_LOWER, TICK_UPPER, LIQUIDITY_AMOUNT);

        hook = _deployHook();

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: POOL_FEE,
            tickSpacing: IPancakeV3Pool(extPool).tickSpacing(),
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();

        poolManager.initialize(poolKey, SQRT_PRICE_1_1);

        token0.mint(alice, type(uint128).max);
        token1.mint(alice, type(uint128).max);
        token0.mint(address(poolManager), type(uint128).max);
        token1.mint(address(poolManager), type(uint128).max);
        token0.mint(extPool, type(uint128).max);
        token1.mint(extPool, type(uint128).max);

        vm.startPrank(alice);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _deployHook() internal returns (PancakeSwapV3Aggregator) {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );
        bytes memory constructorArgs = abi.encode(poolManager, address(factory), "PancakeSwapV3Aggregator v1.0");
        (, bytes32 salt) =
            HookMiner.find(address(this), flags, type(PancakeSwapV3Aggregator).creationCode, constructorArgs);
        return new PancakeSwapV3Aggregator{salt: salt}(poolManager, address(factory), "PancakeSwapV3Aggregator v1.0");
    }

    /// @dev Reads a single-line hex file; adds `0x` if missing (matches `UniswapV3Factory.bin` style).
    function _readPrecompileHex(string memory path) internal view returns (bytes memory) {
        string memory raw = vm.readFile(path);
        bytes memory rb = bytes(raw);
        if (rb.length >= 2 && rb[0] == bytes1(uint8(48)) && rb[1] == bytes1(uint8(120))) {
            return vm.parseBytes(raw);
        }
        return vm.parseBytes(string.concat("0x", raw));
    }

    function _deployCreate(string memory path) internal returns (address deployed) {
        bytes memory bytecode = _readPrecompileHex(path);
        return _deployCreateBytecode(bytecode);
    }

    function _deployCreateBytecode(bytes memory bytecode) internal returns (address deployed) {
        require(bytecode.length > 0, "Empty bytecode");
        assembly {
            deployed := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        require(deployed != address(0), "CREATE failed");
        return deployed;
    }

    function testFuzz_swapExactIn_zeroForOne(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e12, 1e17);
        uint256 expectedOut = hook.quote(true, -int256(amountIn), poolId);

        uint256 t1Before = token1.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(token1.balanceOf(alice) - t1Before, expectedOut);
    }

    function testFuzz_swapExactOut_zeroForOne(uint256 amountOut) public {
        amountOut = bound(amountOut, 1e12, 1e17);
        uint256 expectedIn = hook.quote(true, int256(amountOut), poolId);

        uint256 t0Before = token0.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MIN_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(t0Before - token0.balanceOf(alice), expectedIn);
    }

    function testFuzz_swapExactIn_oneForZero(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e12, 1e17);
        uint256 expectedOut = hook.quote(false, -int256(amountIn), poolId);

        uint256 t0Before = token0.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MAX_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(token0.balanceOf(alice) - t0Before, expectedOut);
    }

    function testFuzz_swapExactOut_oneForZero(uint256 amountOut) public {
        amountOut = bound(amountOut, 1e12, 1e17);
        uint256 expectedIn = hook.quote(false, int256(amountOut), poolId);

        uint256 t1Before = token1.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MAX_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(t1Before - token1.balanceOf(alice), expectedIn);
    }

    receive() external payable {}
}
