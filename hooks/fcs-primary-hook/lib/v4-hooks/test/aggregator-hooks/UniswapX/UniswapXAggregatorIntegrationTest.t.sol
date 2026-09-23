// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";
import {SafePoolSwapTest} from "../shared/SafePoolSwapTest.sol";
import {UniswapXAggregator} from "../../../src/aggregator-hooks/implementations/UniswapX/UniswapXAggregator.sol";
import {IReactor as IBriefcaseReactor} from "@uniswapx/interfaces/IReactor.sol";

// Real UniswapX contracts (brought in as the lib/uniswapx submodule). Uses the ExclusiveDutchOrderReactor —
// the same order type as the production mainnet Dutch reactor — with no exclusivity (exclusiveFiller = 0),
// i.e. an open Dutch order. The hook is reactor-agnostic; it forwards the SignedOrder and reads the ResolvedOrder.
import {ExclusiveDutchOrderReactor} from "../../../lib/uniswapx/src/reactors/ExclusiveDutchOrderReactor.sol";
import {ExclusiveDutchOrder, ExclusiveDutchOrderLib} from "../../../lib/uniswapx/src/lib/ExclusiveDutchOrderLib.sol";
import {DutchInput, DutchOutput} from "../../../lib/uniswapx/src/lib/DutchOrderLib.sol";
import {OrderInfo, SignedOrder} from "../../../lib/uniswapx/src/base/ReactorStructs.sol";
import {IReactor} from "../../../lib/uniswapx/src/interfaces/IReactor.sol";
import {IValidationCallback} from "../../../lib/uniswapx/src/interfaces/IValidationCallback.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {DeployPermit2} from "../../../lib/uniswapx/test/util/DeployPermit2.sol";

/// @notice End-to-end integration test that fills real UniswapX Dutch orders through the aggregator hook.
/// @dev Deploys the canonical Permit2 and a real ExclusiveDutchOrderReactor locally (no fork required). A V4 swap
///      against the hook calls the reactor's executeWithCallback; the reactor resolves the order (applying
///      Dutch decay) and the hook sources the output from the PoolManager during reactorCallback.
contract UniswapXAggregatorIntegrationTest is Test, DeployPermit2 {
    using PoolIdLibrary for PoolKey;
    using ExclusiveDutchOrderLib for ExclusiveDutchOrder;

    // Permit2 EIP-712 constants (mirrors UniswapX's PermitSignature test helper)
    bytes32 constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");
    bytes32 constant NAME_HASH = keccak256("Permit2");
    bytes32 constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    string constant TYPEHASH_STUB =
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,";

    IPoolManager public poolManager;
    SafePoolSwapTest public swapRouter;
    IPermit2 public permit2;
    ExclusiveDutchOrderReactor public reactor;
    WETH public weth;
    UniswapXAggregator public hook;

    MockERC20 public tokenA; // order input token
    MockERC20 public tokenB; // order output token
    MockERC20 public usdc;

    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant MIN_PRICE = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE = TickMath.MAX_SQRT_PRICE - 1;
    Currency constant NATIVE = Currency.wrap(address(0));

    address public maker;
    uint256 public makerPk;
    address public alice = makeAddr("alice");

    function setUp() public {
        (maker, makerPk) = makeAddrAndKey("maker");

        poolManager =
            IPoolManager(vm.deployCode("foundry-out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        swapRouter = new SafePoolSwapTest(poolManager);

        permit2 = IPermit2(deployPermit2());
        reactor = new ExclusiveDutchOrderReactor(permit2, address(this));
        weth = new WETH();

        hook = _deployHook();

        tokenA = new MockERC20("TokenA", "TKA", 18);
        tokenB = new MockERC20("TokenB", "TKB", 18);
        usdc = new MockERC20("USDC", "USDC", 6);
    }

    function _deployHook() internal returns (UniswapXAggregator) {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );
        bytes memory args = abi.encode(poolManager, IBriefcaseReactor(address(reactor)), address(weth));
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(UniswapXAggregator).creationCode, args);
        return new UniswapXAggregator{salt: salt}(poolManager, IBriefcaseReactor(address(reactor)), address(weth));
    }

    function _initPool(Currency c0, Currency c1) internal returns (PoolKey memory key) {
        (Currency currency0, Currency currency1) = Currency.unwrap(c0) < Currency.unwrap(c1) ? (c0, c1) : (c1, c0);
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        poolManager.initialize(key, SQRT_PRICE_1_1);
    }

    function _zeroForOne(PoolKey memory key, Currency takeCurrency) internal pure returns (bool) {
        return Currency.unwrap(takeCurrency) == Currency.unwrap(key.currency0);
    }

    /// @dev Build a (non-decaying by default) open Dutch order — no exclusivity — maker gives input, wants output.
    function _buildOrder(
        address inTok,
        uint256 inStart,
        uint256 inEnd,
        address outTok,
        uint256 outStart,
        uint256 outEnd,
        uint256 nonce
    ) internal view returns (ExclusiveDutchOrder memory order) {
        DutchOutput[] memory outputs = new DutchOutput[](1);
        outputs[0] = DutchOutput({token: outTok, startAmount: outStart, endAmount: outEnd, recipient: maker});
        order = ExclusiveDutchOrder({
            info: OrderInfo({
                reactor: IReactor(address(reactor)),
                swapper: maker,
                nonce: nonce,
                deadline: block.timestamp + 1000,
                additionalValidationContract: IValidationCallback(address(0)),
                additionalValidationData: ""
            }),
            decayStartTime: block.timestamp,
            decayEndTime: block.timestamp + 1000,
            exclusiveFiller: address(0), // open fill — no exclusive filler
            exclusivityOverrideBps: 0,
            input: DutchInput({token: ERC20(inTok), startAmount: inStart, endAmount: inEnd}),
            outputs: outputs
        });
    }

    /// @dev Sign an exclusive Dutch order via Permit2 witness (subset of UniswapX's PermitSignature helper).
    function _sign(ExclusiveDutchOrder memory order) internal view returns (bytes memory) {
        bytes32 domainSep = keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, block.chainid, address(permit2)));
        bytes32 typeHash = keccak256(abi.encodePacked(TYPEHASH_STUB, ExclusiveDutchOrderLib.PERMIT2_ORDER_TYPE));
        bytes32 tokenPermissions = keccak256(
            abi.encode(
                TOKEN_PERMISSIONS_TYPEHASH,
                ISignatureTransfer.TokenPermissions({token: address(order.input.token), amount: order.input.endAmount})
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                typeHash,
                tokenPermissions,
                address(order.info.reactor),
                order.info.nonce,
                order.info.deadline,
                order.hash()
            )
        );
        bytes32 msgHash = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, msgHash);
        return bytes.concat(r, s, bytes1(v));
    }

    function _hookData(ExclusiveDutchOrder memory order) internal view returns (bytes memory) {
        return abi.encode(SignedOrder({order: abi.encode(order), sig: _sign(order)}));
    }

    // ─────────────────────────── tests ───────────────────────────

    function test_fillRealDutchOrder_erc20() public {
        uint256 inAmt = 100 ether;
        uint256 outAmt = 99 ether;

        PoolKey memory key = _initPool(Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)));

        // maker funds the order input and approves Permit2
        tokenA.mint(maker, inAmt);
        vm.prank(maker);
        tokenA.approve(address(permit2), type(uint256).max);

        // PoolManager float so the hook can take tokenB before alice settles
        tokenB.mint(address(poolManager), 1000 ether);

        // alice (V4 swapper) provides tokenB
        tokenB.mint(alice, outAmt);
        vm.prank(alice);
        tokenB.approve(address(swapRouter), type(uint256).max);

        ExclusiveDutchOrder memory order =
            _buildOrder(address(tokenA), inAmt, inAmt, address(tokenB), outAmt, outAmt, 0);
        Currency takeCurrency = Currency.wrap(address(tokenB));

        vm.prank(alice);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: _zeroForOne(key, takeCurrency),
                amountSpecified: -int256(outAmt),
                sqrtPriceLimitX96: _zeroForOne(key, takeCurrency) ? MIN_PRICE : MAX_PRICE
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            _hookData(order)
        );

        assertEq(tokenA.balanceOf(maker), 0, "maker spent input");
        assertEq(tokenB.balanceOf(maker), outAmt, "maker received output");
        assertEq(tokenB.balanceOf(alice), 0, "alice spent tokenB");
        assertEq(tokenA.balanceOf(alice), inAmt, "alice received tokenA");
        assertEq(tokenA.balanceOf(address(hook)), 0, "hook holds no tokenA");
        assertEq(tokenB.balanceOf(address(hook)), 0, "hook holds no tokenB");
    }

    function test_fillRealDutchOrder_nativeOutput() public {
        uint256 inAmt = 100e6; // maker gives USDC
        uint256 outAmt = 1 ether; // maker wants native ETH

        PoolKey memory key = _initPool(NATIVE, Currency.wrap(address(usdc)));

        usdc.mint(maker, inAmt);
        vm.prank(maker);
        usdc.approve(address(permit2), type(uint256).max);

        vm.deal(address(poolManager), 100 ether); // native float for the take
        vm.deal(alice, outAmt);

        ExclusiveDutchOrder memory order = _buildOrder(address(usdc), inAmt, inAmt, address(0), outAmt, outAmt, 0);
        Currency takeCurrency = NATIVE;

        vm.prank(alice);
        swapRouter.swap{value: outAmt}(
            key,
            SwapParams({
                zeroForOne: _zeroForOne(key, takeCurrency),
                amountSpecified: -int256(outAmt),
                sqrtPriceLimitX96: _zeroForOne(key, takeCurrency) ? MIN_PRICE : MAX_PRICE
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            _hookData(order)
        );

        assertEq(usdc.balanceOf(maker), 0, "maker spent usdc");
        assertEq(maker.balance, outAmt, "maker received native ETH");
        assertEq(usdc.balanceOf(alice), inAmt, "alice received usdc");
        assertEq(address(hook).balance, 0, "hook holds no ETH");
    }

    function test_fillRealDutchOrder_decayResolvesAtEnd() public {
        // Output decays from 110 -> 100; warp to the end so the resolved (static) output is 100.
        uint256 inAmt = 50 ether;
        uint256 outStart = 110 ether;
        uint256 outEnd = 100 ether;

        PoolKey memory key = _initPool(Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)));

        tokenA.mint(maker, inAmt);
        vm.prank(maker);
        tokenA.approve(address(permit2), type(uint256).max);

        tokenB.mint(address(poolManager), 1000 ether);
        tokenB.mint(alice, outStart);
        vm.prank(alice);
        tokenB.approve(address(swapRouter), type(uint256).max);

        ExclusiveDutchOrder memory order =
            _buildOrder(address(tokenA), inAmt, inAmt, address(tokenB), outStart, outEnd, 0);

        // Move to decayEndTime: the resolved output is now the static end amount.
        vm.warp(order.decayEndTime);

        Currency takeCurrency = Currency.wrap(address(tokenB));
        vm.prank(alice);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: _zeroForOne(key, takeCurrency),
                amountSpecified: -int256(outEnd), // must match the resolved (decayed) amount
                sqrtPriceLimitX96: _zeroForOne(key, takeCurrency) ? MIN_PRICE : MAX_PRICE
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            _hookData(order)
        );

        assertEq(tokenB.balanceOf(maker), outEnd, "maker received decayed output");
        assertEq(tokenA.balanceOf(alice), inAmt, "alice received input");
        assertEq(tokenB.balanceOf(alice), outStart - outEnd, "alice only paid the decayed amount");
    }

    /// @dev `quoteWithHookData` resolves the order (via the OrderQuoter) to the exact fill amounts.
    function test_quoteWithHookData_returnsResolvedAmounts() public {
        uint256 inAmt = 100 ether;
        uint256 outAmt = 99 ether;

        PoolKey memory key = _initPool(Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)));

        // The quoter calls the reactor (which pulls the maker's input before rolling back), so the order must
        // be fundable: maker funded + Permit2-approved.
        tokenA.mint(maker, inAmt);
        vm.prank(maker);
        tokenA.approve(address(permit2), type(uint256).max);

        ExclusiveDutchOrder memory order =
            _buildOrder(address(tokenA), inAmt, inAmt, address(tokenB), outAmt, outAmt, 0);
        bytes memory hookData = _hookData(order);
        bool zeroForOne = _zeroForOne(key, Currency.wrap(address(tokenB)));

        // exact-in: swapper provides the order's output (tokenB) and receives the order's input (tokenA).
        uint256 quotedIn = hook.quoteWithHookData(zeroForOne, -int256(outAmt), key.toId(), hookData);
        assertEq(quotedIn, inAmt, "exact-in quote = order input amount");

        // exact-out: swapper wants the order's input (tokenA) and pays the order's output (tokenB).
        uint256 quotedOut = hook.quoteWithHookData(zeroForOne, int256(inAmt), key.toId(), hookData);
        assertEq(quotedOut, outAmt, "exact-out quote = order output amount");
    }

    /// @dev `quoteWithHookData` reflects Dutch decay: same order quotes differently as time advances.
    function test_quoteWithHookData_appliesDutchDecay() public {
        uint256 inAmt = 50 ether;
        uint256 outStart = 110 ether;
        uint256 outEnd = 100 ether;

        PoolKey memory key = _initPool(Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)));

        tokenA.mint(maker, inAmt);
        vm.prank(maker);
        tokenA.approve(address(permit2), type(uint256).max);

        ExclusiveDutchOrder memory order =
            _buildOrder(address(tokenA), inAmt, inAmt, address(tokenB), outStart, outEnd, 0);
        bytes memory hookData = _hookData(order);
        bool zeroForOne = _zeroForOne(key, Currency.wrap(address(tokenB)));

        // At decayStartTime (now), the required output is the start amount.
        assertEq(hook.quoteWithHookData(zeroForOne, int256(inAmt), key.toId(), hookData), outStart, "decay start");

        // At decayEndTime, it has fully decayed to the end amount.
        vm.warp(order.decayEndTime);
        assertEq(hook.quoteWithHookData(zeroForOne, int256(inAmt), key.toId(), hookData), outEnd, "decay end");
    }

    /// @dev Exact-in quote must reject only when the V4 swap input cannot cover the order's required output;
    ///      over-providing input is allowed (the surplus goes to the token jar).
    function test_quoteWithHookData_exactIn_amountMismatch_reverts() public {
        uint256 inAmt = 100 ether;
        uint256 outAmt = 99 ether;

        PoolKey memory key = _initPool(Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)));
        tokenA.mint(maker, inAmt);
        vm.prank(maker);
        tokenA.approve(address(permit2), type(uint256).max);

        ExclusiveDutchOrder memory order =
            _buildOrder(address(tokenA), inAmt, inAmt, address(tokenB), outAmt, outAmt, 0);
        bytes memory hookData = _hookData(order);
        bool zeroForOne = _zeroForOne(key, Currency.wrap(address(tokenB)));

        // swap input 50 < order output 99 -> reject (cannot cover the order)
        vm.expectRevert(UniswapXAggregator.OrderAmountMismatch.selector);
        hook.quoteWithHookData(zeroForOne, -int256(50 ether), key.toId(), hookData);

        // swap input 150 > order output 99 -> accepted; the swapper still receives the order's input
        assertEq(
            hook.quoteWithHookData(zeroForOne, -int256(150 ether), key.toId(), hookData), inAmt, "surplus input ok"
        );

        // sanity: an input equal to the order output is accepted
        assertEq(hook.quoteWithHookData(zeroForOne, -int256(outAmt), key.toId(), hookData), inAmt, "exact input ok");
    }

    /// @dev Exact-out quote must reject only when the order supplies less than the requested output;
    ///      under-requesting is allowed (the order's surplus input goes to the token jar).
    function test_quoteWithHookData_exactOut_amountMismatch_reverts() public {
        uint256 inAmt = 100 ether;
        uint256 outAmt = 99 ether;

        PoolKey memory key = _initPool(Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)));
        tokenA.mint(maker, inAmt);
        vm.prank(maker);
        tokenA.approve(address(permit2), type(uint256).max);

        ExclusiveDutchOrder memory order =
            _buildOrder(address(tokenA), inAmt, inAmt, address(tokenB), outAmt, outAmt, 0);
        bytes memory hookData = _hookData(order);
        bool zeroForOne = _zeroForOne(key, Currency.wrap(address(tokenB)));

        // request 150 of the order input (tokenA) but the order only supplies 100 -> reject
        vm.expectRevert(UniswapXAggregator.OrderAmountMismatch.selector);
        hook.quoteWithHookData(zeroForOne, int256(150 ether), key.toId(), hookData);

        // request 50 of the order input (tokenA), below the order's 100 -> accepted; the swapper still
        // pays the order's full output (the order fills whole)
        assertEq(hook.quoteWithHookData(zeroForOne, int256(50 ether), key.toId(), hookData), outAmt, "under-request ok");
    }

    /// @dev Amounts above int128.max would silently sign-flip when narrowed to form the V4 delta; the quote
    ///      must reject them (mirroring the execution-time guard in `_conductSwap`).
    function test_quoteWithHookData_outputOverflow_reverts() public {
        uint256 inAmt = 1 ether;
        uint256 hugeOut = uint256(uint128(type(int128).max)) + 1; // just over int128.max

        PoolKey memory key = _initPool(Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)));
        tokenA.mint(maker, inAmt);
        vm.prank(maker);
        tokenA.approve(address(permit2), type(uint256).max);

        ExclusiveDutchOrder memory order =
            _buildOrder(address(tokenA), inAmt, inAmt, address(tokenB), hugeOut, hugeOut, 0);
        bytes memory hookData = _hookData(order);
        bool zeroForOne = _zeroForOne(key, Currency.wrap(address(tokenB)));

        // exact-out returns the (overflowing) order output -> reject before it can be used as a delta
        vm.expectRevert(UniswapXAggregator.OrderOutputOverflow.selector);
        hook.quoteWithHookData(zeroForOne, int256(inAmt), key.toId(), hookData);
    }

    receive() external payable {}
}
