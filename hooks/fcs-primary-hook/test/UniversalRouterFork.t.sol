// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {FCSPrimaryHook} from "../src/FCSPrimaryHook.sol";
import {FCSPrimaryRouter} from "../src/FCSPrimaryRouter.sol";
import {IFCS, IFPS} from "../src/interfaces/IFCS.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "v4-hooks/utils/HookMiner.sol";

/// @dev Minimal ABI of the deployed Uniswap Universal Router (v2, v4-capable) and Permit2.
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
    function poolManager() external view returns (address);
}

interface IPermit2Allowance {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @dev ABI of the deployed mainnet V4Quoter.
interface IV4QuoterLike {
    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    function poolManager() external view returns (address);
    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);
}

/// @notice Drives the ACTUAL deployed Universal Router through the primary hook on a pinned
/// mainnet fork. Proves which action sequences work and which the hook rejects.
/// Only the test payer balance is dealt; FCS, PoolManager, Universal Router and Permit2 are live code.
contract UniversalRouterForkTest is Test {
    using PoolIdLibrary for PoolKey;

    uint256 constant FORK_BLOCK = 26038677;
    address constant FCS_ADDRESS = 0xDb861830D9Ae2d1fCF99fA0cfd3973de382B0B5b;
    address constant ZCHF_ADDRESS = 0xB58E61C3098d85632Df34EecfB899A1Ed80921cB;
    address constant FPS_ADDRESS = 0x1bA26788dfDe592fec8bcB0Eaff472a42BE341B2;
    address constant MANAGER_ADDRESS = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant V4_QUOTER = 0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203;

    // Universal Router command and V4Router actions (Uniswap/universal-router Commands.sol, v4-periphery Actions.sol)
    uint8 constant V4_SWAP = 0x10;
    uint8 constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 constant SETTLE = 0x0b;
    uint8 constant SETTLE_ALL = 0x0c;
    uint8 constant TAKE_ALL = 0x0f;

    /// @dev Layout of IV4Router.ExactInputSingleParams as deployed in the mainnet Universal Router
    /// (no `minHopPriceX36` field; that was added to v4-periphery later).
    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    bytes32 constant EXECUTION_TOPIC = keccak256("PrimaryExecution(bytes32,address,bool,uint256,uint256)");

    IFCS fcs;
    IERC20 zchf;
    IPoolManager manager;
    IUniversalRouter ur;
    FCSPrimaryHook hook;
    PoolKey key;
    bool buyZeroForOne;
    address alice = address(0xA11CE);

    function setUp() public {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://eth-mainnet.public.blastapi.io")), FORK_BLOCK);
        assertEq(block.chainid, 1);
        assertEq(FCS_ADDRESS.codehash, 0x9dacc056e5f2d59b75a9c9ae8a3cd5134abf7bfb675462f50c12ab777603cc62);
        assertEq(MANAGER_ADDRESS.codehash, 0x785f1014552b7ce7d5fb7d0c970ca60edee94fd00425d7ca21609acac7ce1293);
        fcs = IFCS(FCS_ADDRESS);
        zchf = IERC20(ZCHF_ADDRESS);
        manager = IPoolManager(MANAGER_ADDRESS);
        ur = IUniversalRouter(UNIVERSAL_ROUTER);
        assertEq(ur.poolManager(), MANAGER_ADDRESS, "deployed Universal Router must target the v4 PoolManager");
        assertGt(PERMIT2.code.length, 0);
        assertFalse(fcs.isBinding());
        assertFalse(IFPS(FPS_ADDRESS).canRedeem(FCS_ADDRESS));

        bytes memory args = abi.encode(manager, fcs);
        (address predicted, bytes32 salt) = HookMiner.find(FACTORY, 0x2888, type(FCSPrimaryHook).creationCode, args);
        (bool ok,) = FACTORY.call(abi.encodePacked(salt, type(FCSPrimaryHook).creationCode, args));
        require(ok && predicted.code.length != 0, "fork-only CREATE2 deployment failed");
        hook = FCSPrimaryHook(predicted);
        key = hook.router().poolKey();
        manager.initialize(key, uint160(1 << 96));
        buyZeroForOne = ZCHF_ADDRESS < FCS_ADDRESS;

        deal(ZCHF_ADDRESS, alice, 10_000e18);
        // Standard Universal Router user setup: ERC20 approval to Permit2, Permit2 allowance to the router.
        vm.startPrank(alice);
        zchf.approve(PERMIT2, type(uint256).max);
        fcs.approve(PERMIT2, type(uint256).max);
        IPermit2Allowance(PERMIT2).approve(ZCHF_ADDRESS, UNIVERSAL_ROUTER, type(uint160).max, type(uint48).max);
        IPermit2Allowance(PERMIT2).approve(FCS_ADDRESS, UNIVERSAL_ROUTER, type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ helpers

    function _v4(bytes memory actions, bytes[] memory params)
        internal
        pure
        returns (bytes memory commands, bytes[] memory inputs)
    {
        commands = abi.encodePacked(V4_SWAP);
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
    }

    function _swapParams(bool buy, uint128 amountIn, uint128 minOut, bytes memory hookData)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(ExactInputSingleParams(key, buy == buyZeroForOne, amountIn, minOut, hookData));
    }

    function _executeExpectingFailure(bytes memory commands, bytes[] memory inputs, bytes4 innerSelector) internal {
        vm.prank(alice);
        (bool ok, bytes memory reason) =
            UNIVERSAL_ROUTER.call(abi.encodeCall(IUniversalRouter.execute, (commands, inputs, block.timestamp)));
        assertFalse(ok, "sequence unexpectedly succeeded");
        assertTrue(_contains(reason, innerSelector), "revert data must carry the hook's rejection reason");
    }

    function _contains(bytes memory data, bytes4 sel) internal pure returns (bool) {
        if (data.length < 4) return false;
        for (uint256 i; i + 4 <= data.length; ++i) {
            if (bytes4(bytes.concat(data[i], data[i + 1], data[i + 2], data[i + 3])) == sel) return true;
        }
        return false;
    }

    function _executionLogs(Vm.Log[] memory logs) internal view returns (Vm.Log[] memory filtered) {
        filtered = new Vm.Log[](logs.length);
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics.length != 0 && logs[i].topics[0] == EXECUTION_TOPIC)
            {
                filtered[count++] = logs[i];
            }
        }
        assembly ("memory-safe") {
            mstore(filtered, count)
        }
    }

    function _buy(uint128 amountIn, uint128 swapAmountField) internal returns (uint256 expected) {
        expected = fcs.previewDeposit(amountIn);
        (uint256 quoted, bool available,) = hook.quoteExactInput(true, amountIn);
        assertTrue(available);
        assertEq(quoted, expected);
        bytes memory actions = abi.encodePacked(SETTLE, SWAP_EXACT_IN_SINGLE, TAKE_ALL);
        bytes[] memory params = new bytes[](3);
        // 1. Prefund: pull ZCHF from the user via Permit2 into the PoolManager and settle => router credit.
        params[0] = abi.encode(Currency.wrap(ZCHF_ADDRESS), uint256(amountIn), true);
        // 2. Swap through the hook with the mandatory 64-byte hookData (minOut, deadline).
        params[1] = _swapParams(true, swapAmountField, uint128(expected), abi.encode(expected, block.timestamp));
        // 3. Deliver all FCS credit to the user.
        params[2] = abi.encode(Currency.wrap(FCS_ADDRESS), expected);
        (bytes memory commands, bytes[] memory inputs) = _v4(actions, params);
        vm.prank(alice);
        ur.execute(commands, inputs, block.timestamp);
    }

    // -------------------------------------------------------------------- tests

    /// @dev The working integration: SETTLE (prefund) -> SWAP_EXACT_IN_SINGLE (hookData) -> TAKE_ALL.
    function testFork_universalRouterBuyWithSettleBeforeSwap() public {
        uint256 managerZchf = zchf.balanceOf(MANAGER_ADDRESS);
        uint256 managerFcs = fcs.balanceOf(MANAGER_ADDRESS);
        vm.recordLogs();
        uint256 expected = _buy(1000e18, 1000e18);
        assertEq(expected, 792901508858246948);
        assertEq(fcs.balanceOf(alice), expected);
        assertEq(zchf.balanceOf(alice), 9000e18);
        assertEq(zchf.balanceOf(MANAGER_ADDRESS), managerZchf);
        assertEq(fcs.balanceOf(MANAGER_ADDRESS), managerFcs);
        assertEq(zchf.balanceOf(address(hook)), 0);
        assertEq(fcs.balanceOf(address(hook)), 0);
        assertEq(zchf.balanceOf(UNIVERSAL_ROUTER), 0);
        assertEq(fcs.balanceOf(UNIVERSAL_ROUTER), 0);
        Vm.Log[] memory logs = _executionLogs(vm.getRecordedLogs());
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[1], PoolId.unwrap(key.toId()));
        assertEq(
            logs[0].topics[2], bytes32(uint256(uint160(UNIVERSAL_ROUTER))), "indexed router is the Universal Router"
        );
        assertEq(logs[0].data, abi.encode(true, uint256(1000e18), expected));
    }

    /// @dev amountIn = OPEN_DELTA (0) makes the router swap its full settled credit.
    function testFork_universalRouterOpenDeltaSwapsFullSettledCredit() public {
        uint256 expected = _buy(1000e18, 0);
        assertEq(fcs.balanceOf(alice), expected);
        assertEq(zchf.balanceOf(alice), 9000e18);
    }

    /// @dev EXACTLY what the Uniswap app's Universal Router encoding does: swap first with empty
    /// hookData, settle the input afterwards, take the output. The hook bridges the gap with the
    /// singleton's ambient ZCHF (other pools' reserves at the fork block) and settlement repays it.
    function _defaultEncodingBuy(uint128 amountIn, uint128 minOut)
        internal
        view
        returns (bytes memory, bytes[] memory)
    {
        bytes memory actions = abi.encodePacked(SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL);
        bytes[] memory params = new bytes[](3);
        params[0] = _swapParams(true, amountIn, minOut, "");
        params[1] = abi.encode(Currency.wrap(ZCHF_ADDRESS), uint256(amountIn));
        params[2] = abi.encode(Currency.wrap(FCS_ADDRESS), uint256(minOut));
        return _v4(actions, params);
    }

    function testFork_universalRouterDefaultEncodingBuysWithoutHookData() public {
        uint256 float = zchf.balanceOf(MANAGER_ADDRESS);
        assertGt(float, 1000e18, "fork block must have ambient ZCHF in the singleton");
        uint256 expected = fcs.previewDeposit(1000e18);
        (bytes memory commands, bytes[] memory inputs) = _defaultEncodingBuy(1000e18, uint128(expected));
        vm.recordLogs();
        vm.prank(alice);
        ur.execute(commands, inputs, block.timestamp);
        assertEq(fcs.balanceOf(alice), expected);
        assertEq(zchf.balanceOf(alice), 9000e18);
        assertEq(zchf.balanceOf(MANAGER_ADDRESS), float, "borrowed float repaid by SETTLE_ALL");
        assertEq(zchf.balanceOf(address(hook)), 0);
        assertEq(fcs.balanceOf(address(hook)), 0);
        Vm.Log[] memory logs = _executionLogs(vm.getRecordedLogs());
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(UNIVERSAL_ROUTER))));
        assertEq(logs[0].data, abi.encode(true, uint256(1000e18), expected));
    }

    /// @dev A buy larger than the singleton's ZCHF float fails with the hook's explicit reason.
    function testFork_universalRouterDefaultEncodingRevertsBeyondSingletonFloat() public {
        uint256 float = zchf.balanceOf(MANAGER_ADDRESS);
        uint128 amountIn = uint128(float + 1);
        deal(ZCHF_ADDRESS, alice, amountIn);
        (bytes memory commands, bytes[] memory inputs) = _defaultEncodingBuy(amountIn, 1);
        _executeExpectingFailure(commands, inputs, FCSPrimaryHook.InsufficientInventory.selector);
        assertEq(zchf.balanceOf(alice), amountIn);
        assertEq(fcs.balanceOf(alice), 0);
    }

    /// @dev The deployed V4 Quoter (used by the routing API) can now price the pool with empty hookData.
    function testFork_v4QuoterPricesDefaultEncodingBuy() public {
        assertEq(IV4QuoterLike(V4_QUOTER).poolManager(), MANAGER_ADDRESS);
        (uint256 amountOut, uint256 gasEstimate) = IV4QuoterLike(V4_QUOTER)
            .quoteExactInputSingle(IV4QuoterLike.QuoteExactSingleParams(key, buyZeroForOne, 1000e18, ""));
        assertEq(amountOut, fcs.previewDeposit(1000e18), "quoter output equals amount-specific primary preview");
        assertGt(gasEstimate, 0);
        // Quoting is a simulation: nothing changed.
        assertEq(fcs.balanceOf(alice), 0);
        assertEq(zchf.balanceOf(alice), 10_000e18);
    }

    /// @dev Live sell gates propagate through the Universal Router: bought shares cannot be sold today.
    function testFork_universalRouterSellRejectedByLiveGates() public {
        uint256 bought = _buy(1000e18, 1000e18);
        (uint256 quoted, bool available, FCSPrimaryHook.QuoteStatus status) = hook.quoteExactInput(false, bought);
        assertGt(quoted, 0);
        assertFalse(available);
        assertEq(uint256(status), uint256(FCSPrimaryHook.QuoteStatus.NotBinding));
        bytes memory actions = abi.encodePacked(SETTLE, SWAP_EXACT_IN_SINGLE, TAKE_ALL);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(Currency.wrap(FCS_ADDRESS), bought, true);
        params[1] = _swapParams(false, uint128(bought), 1, abi.encode(uint256(1), block.timestamp));
        params[2] = abi.encode(Currency.wrap(ZCHF_ADDRESS), uint256(1));
        (bytes memory commands, bytes[] memory inputs) = _v4(actions, params);
        _executeExpectingFailure(commands, inputs, bytes4(keccak256("RedemptionsDisabled()")));
        assertEq(fcs.balanceOf(alice), bought, "shares untouched after atomic rejection");
        assertEq(zchf.balanceOf(alice), 9000e18);
    }
}
