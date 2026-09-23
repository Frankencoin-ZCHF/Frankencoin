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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";
import {SafePoolSwapTest} from "../shared/SafePoolSwapTest.sol";
import {UniswapXAggregator} from "../../../src/aggregator-hooks/implementations/UniswapX/UniswapXAggregator.sol";
import {IReactor as IBriefcaseReactor} from "@uniswapx/interfaces/IReactor.sol";

// Real UniswapX contracts (brought in as the lib/uniswapx submodule). The production mainnet Dutch reactor
// (0x6000da47...) is the ExclusiveDutchOrderReactor, so we encode/sign an ExclusiveDutchOrder. The hook itself
// is reactor-agnostic: it forwards the SignedOrder and reads the ResolvedOrder the reactor hands back.
import {ExclusiveDutchOrderReactor} from "../../../lib/uniswapx/src/reactors/ExclusiveDutchOrderReactor.sol";
import {ExclusiveDutchOrder, ExclusiveDutchOrderLib} from "../../../lib/uniswapx/src/lib/ExclusiveDutchOrderLib.sol";
import {DutchInput, DutchOutput} from "../../../lib/uniswapx/src/lib/DutchOrderLib.sol";
import {OrderInfo, SignedOrder} from "../../../lib/uniswapx/src/base/ReactorStructs.sol";
import {IReactor} from "../../../lib/uniswapx/src/interfaces/IReactor.sol";
import {IValidationCallback} from "../../../lib/uniswapx/src/interfaces/IValidationCallback.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

/// @notice Fork test — fills a real, locally-signed UniswapX (exclusive) Dutch order against the *deployed*
///         reactor on Ethereum mainnet (chain id 1), routed through the aggregator hook on the real v4 PoolManager.
///         The production mainnet Dutch reactor is an ExclusiveDutchOrderReactor; the hook is reactor-agnostic.
/// @dev Env: `FORK_RPC_URL_1`, optional `FORK_BLOCK_NUMBER_1`, `POOL_MANAGER_1`, `UNISWAPX_DUTCH_REACTOR_1`, `WETH9_1`.
///      Skips when `FORK_RPC_URL_1` is unset. We sign the order ourselves with a maker key via the reactor's
///      canonical Permit2, so no off-chain order fixture is required.
contract UniswapXAggregatorForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using ExclusiveDutchOrderLib for ExclusiveDutchOrder;

    // Permit2 EIP-712 constants (mirrors UniswapX's PermitSignature test helper)
    bytes32 constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");
    bytes32 constant NAME_HASH = keccak256("Permit2");
    bytes32 constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    string constant TYPEHASH_STUB =
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,";

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant MIN_PRICE = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE = TickMath.MAX_SQRT_PRICE - 1;
    Currency constant NATIVE = Currency.wrap(address(0));

    IPoolManager public poolManager;
    SafePoolSwapTest public swapRouter;
    IPermit2 public permit2;
    ExclusiveDutchOrderReactor public reactor;
    address public weth;
    UniswapXAggregator public hook;

    address public maker;
    uint256 public makerPk;
    address public alice = makeAddr("alice");

    function setUp() public {
        string memory rpcUrl;
        try vm.envString("FORK_RPC_URL_1") returns (string memory r) {
            rpcUrl = r;
        } catch {
            vm.skip(true);
            return;
        }
        uint256 forkBlockNumber = vm.envOr("FORK_BLOCK_NUMBER_1", uint256(0));
        if (forkBlockNumber > 0) {
            vm.createSelectFork(rpcUrl, forkBlockNumber);
        } else {
            vm.createSelectFork(rpcUrl);
        }

        poolManager = IPoolManager(vm.envAddress("POOL_MANAGER_1"));
        reactor = ExclusiveDutchOrderReactor(payable(vm.envAddress("UNISWAPX_DUTCH_REACTOR_1")));
        weth = vm.envAddress("WETH9_1");
        permit2 = IPermit2(address(reactor.permit2()));

        (maker, makerPk) = makeAddrAndKey("maker");
        swapRouter = new SafePoolSwapTest(poolManager);
        hook = _deployHook();
    }

    function _deployHook() internal returns (UniswapXAggregator) {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );
        bytes memory args = abi.encode(poolManager, IBriefcaseReactor(address(reactor)), weth);
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(UniswapXAggregator).creationCode, args);
        return new UniswapXAggregator{salt: salt}(poolManager, IBriefcaseReactor(address(reactor)), weth);
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

    /// @dev Build a (non-decaying by default) exclusive Dutch order with no exclusivity (open to any filler):
    ///      maker gives input, wants output, with `nonce`.
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

    /// @notice Fill a USDC->WETH Dutch order against the real reactor; alice (V4 swapper) supplies the WETH.
    function test_fork_fillRealDutchOrder_erc20() public {
        uint256 inAmt = 1_000e6; // maker gives 1,000 USDC
        uint256 outAmt = 0.3 ether; // maker wants 0.3 WETH

        PoolKey memory key = _initPool(Currency.wrap(USDC), Currency.wrap(weth));

        // maker funds the order input and approves the reactor's Permit2
        deal(USDC, maker, inAmt);
        vm.prank(maker);
        IERC20(USDC).approve(address(permit2), type(uint256).max);

        // PoolManager float so the hook can take WETH before alice settles, plus alice's WETH input
        deal(weth, address(poolManager), 100 ether);
        deal(weth, alice, outAmt);
        vm.prank(alice);
        IERC20(weth).approve(address(swapRouter), type(uint256).max);

        ExclusiveDutchOrder memory order = _buildOrder(USDC, inAmt, inAmt, weth, outAmt, outAmt, 0);
        Currency takeCurrency = Currency.wrap(weth);

        uint256 makerWethBefore = IERC20(weth).balanceOf(maker);

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

        assertEq(IERC20(USDC).balanceOf(maker), 0, "maker spent USDC");
        assertEq(IERC20(weth).balanceOf(maker) - makerWethBefore, outAmt, "maker received WETH");
        assertEq(IERC20(weth).balanceOf(alice), 0, "alice spent WETH");
        assertEq(IERC20(USDC).balanceOf(alice), inAmt, "alice received USDC");
        assertEq(IERC20(USDC).balanceOf(address(hook)), 0, "hook holds no USDC");
        assertEq(IERC20(weth).balanceOf(address(hook)), 0, "hook holds no WETH");
    }

    /// @notice Fill a USDC->native-ETH Dutch order against the real reactor; exercises the WETH<->ETH bridge.
    function test_fork_fillRealDutchOrder_nativeOutput() public {
        uint256 inAmt = 1_000e6; // maker gives 1,000 USDC
        uint256 outAmt = 0.3 ether; // maker wants 0.3 native ETH

        PoolKey memory key = _initPool(NATIVE, Currency.wrap(USDC));

        deal(USDC, maker, inAmt);
        vm.prank(maker);
        IERC20(USDC).approve(address(permit2), type(uint256).max);

        vm.deal(address(poolManager), 100 ether); // native float for the take
        vm.deal(alice, outAmt);

        ExclusiveDutchOrder memory order = _buildOrder(USDC, inAmt, inAmt, address(0), outAmt, outAmt, 0);
        Currency takeCurrency = NATIVE;

        uint256 makerEthBefore = maker.balance;

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

        assertEq(IERC20(USDC).balanceOf(maker), 0, "maker spent USDC");
        assertEq(maker.balance - makerEthBefore, outAmt, "maker received native ETH");
        assertEq(IERC20(USDC).balanceOf(alice), inAmt, "alice received USDC");
        assertEq(address(hook).balance, 0, "hook holds no ETH");
        assertEq(IERC20(weth).balanceOf(address(hook)), 0, "hook holds no WETH");
    }

    receive() external payable {}
}
