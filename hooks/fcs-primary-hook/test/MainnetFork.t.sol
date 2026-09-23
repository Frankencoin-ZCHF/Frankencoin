// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {PrepareMainnet} from "../script/PrepareMainnet.s.sol";
import {FCSPrimaryHook} from "../src/FCSPrimaryHook.sol";
import {FCSPrimaryRouter} from "../src/FCSPrimaryRouter.sol";
import {IFCS, IFPS} from "../src/interfaces/IFCS.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {HookMiner} from "v4-hooks/utils/HookMiner.sol";

/// @notice Actual deployed FCS and actual deployed Ethereum v4 PoolManager, pinned block.
/// Test-only deal funds the payer; NO FCS code, gates, balances, timestamps or storage are patched.
contract MainnetForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    uint256 constant FORK_BLOCK = 26038677;
    address constant FCS_ADDRESS = 0xDb861830D9Ae2d1fCF99fA0cfd3973de382B0B5b;
    address constant ZCHF_ADDRESS = 0xB58E61C3098d85632Df34EecfB899A1Ed80921cB;
    address constant FPS_ADDRESS = 0x1bA26788dfDe592fec8bcB0Eaff472a42BE341B2;
    address constant MANAGER_ADDRESS = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    IFCS fcs;
    IERC20 zchf;
    IPoolManager manager;
    FCSPrimaryHook hook;
    FCSPrimaryRouter router;
    PoolKey key;
    address alice = address(0xA11CE);

    function setUp() public {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com")), FORK_BLOCK);
        assertEq(block.chainid, 1);
        assertEq(FCS_ADDRESS.codehash, 0x9dacc056e5f2d59b75a9c9ae8a3cd5134abf7bfb675462f50c12ab777603cc62);
        assertEq(MANAGER_ADDRESS.codehash, 0x785f1014552b7ce7d5fb7d0c970ca60edee94fd00425d7ca21609acac7ce1293);
        fcs = IFCS(FCS_ADDRESS);
        zchf = IERC20(ZCHF_ADDRESS);
        manager = IPoolManager(MANAGER_ADDRESS);
        assertEq(fcs.asset(), ZCHF_ADDRESS);
        assertEq(fcs.ZCHF(), ZCHF_ADDRESS);
        assertEq(fcs.FPS1(), FPS_ADDRESS);
        assertFalse(fcs.isBinding());
        assertFalse(IFPS(FPS_ADDRESS).canRedeem(FCS_ADDRESS));
        bytes memory args = abi.encode(manager, fcs);
        (address predicted, bytes32 salt) = HookMiner.find(FACTORY, 0x2888, type(FCSPrimaryHook).creationCode, args);
        (bool ok,) = FACTORY.call(abi.encodePacked(salt, type(FCSPrimaryHook).creationCode, args));
        require(ok && predicted.code.length != 0, "fork-only CREATE2 deployment failed");
        hook = FCSPrimaryHook(predicted);
        assertEq(uint160(address(hook)) & ((1 << 14) - 1), 0x2888);
        router = hook.router();
        key = router.poolKey();
        manager.initialize(key, uint160(1 << 96));
        // Standard test-only payer funding, not an eligibility simulation.
        deal(ZCHF_ADDRESS, alice, 10000e18);
        vm.startPrank(alice);
        zchf.approve(address(router), type(uint256).max);
        fcs.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function testFork_liveBuyWithDeployedManagerAndFCS() public {
        uint256 managerZchf = zchf.balanceOf(MANAGER_ADDRESS);
        uint256 managerFcs = fcs.balanceOf(MANAGER_ADDRESS);
        uint256 expected = fcs.previewDeposit(1000e18);
        assertEq(expected, 792901508858246948);
        (uint256 quoted, bool available,) = hook.quoteExactInput(true, 1000e18);
        assertEq(quoted, expected);
        assertTrue(available);
        vm.prank(alice);
        uint256 out = router.swapExactInput(true, 1000e18, expected, alice, block.timestamp);
        assertEq(out, expected);
        assertEq(fcs.balanceOf(alice), out);
        assertEq(zchf.balanceOf(alice), 9000e18);
        assertEq(zchf.balanceOf(MANAGER_ADDRESS), managerZchf);
        assertEq(fcs.balanceOf(MANAGER_ADDRESS), managerFcs);
        assertEq(manager.getLiquidity(key.toId()), 0);
        assertEq(zchf.balanceOf(address(hook)), 0);
        assertEq(fcs.balanceOf(address(hook)), 0);
    }

    function testFork_positiveSellPreviewButCurrentlyUnavailable() public view {
        assertEq(fcs.previewRedeem(1e18), 1243229609390445936114);
        (uint256 out, bool available, FCSPrimaryHook.QuoteStatus reason) = hook.quoteExactInput(false, 1e18);
        assertGt(out, 0);
        assertFalse(available);
        assertEq(uint256(reason), uint256(FCSPrimaryHook.QuoteStatus.NotBinding));
    }

    function testFork_currentSellGateRejectsBoughtSharesAtomically() public {
        vm.prank(alice);
        uint256 bought = router.swapExactInput(true, 1000e18, 1, alice, block.timestamp);
        uint256 supply = fcs.totalSupply();
        uint256 cash = zchf.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(bytes4(keccak256("RedemptionsDisabled()"))),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        router.swapExactInput(false, bought, 1, alice, block.timestamp);
        assertEq(fcs.totalSupply(), supply);
        assertEq(fcs.balanceOf(alice), bought);
        assertEq(zchf.balanceOf(alice), cash);
    }

    function testFork_preparationMinesAndSimulatesDeployablePair() public {
        PrepareMainnet preparation = new PrepareMainnet();
        PrepareMainnet.Plan memory p = preparation.prepare();
        assertEq(uint160(p.hook) & ((1 << 14) - 1), 0x2888);
        assertEq(p.hook.code.length, 0);
        (bool ok,) = FACTORY.call(p.factoryCalldata);
        assertTrue(ok);
        FCSPrimaryHook deployed = FCSPrimaryHook(p.hook);
        assertEq(address(deployed.router()), p.router);
        assertEq(address(deployed.FCS()), FCS_ADDRESS);
        assertEq(deployed.ZCHF(), ZCHF_ADDRESS);
        assertEq(address(deployed.poolManager()), MANAGER_ADDRESS);
        assertEq(keccak256(_withoutSalt(p.factoryCalldata)), p.initCodeHash);
    }

    function _withoutSalt(bytes memory data) internal pure returns (bytes memory result) {
        result = new bytes(data.length - 32);
        for (uint256 i; i < result.length; ++i) {
            result[i] = data[i + 32];
        }
    }

    function testFork_zeroOutputQuoteIsUnavailable() public view {
        (uint256 out, bool available, FCSPrimaryHook.QuoteStatus reason) = hook.quoteExactInput(true, 1);
        assertEq(out, 0);
        assertFalse(available);
        assertEq(uint256(reason), uint256(FCSPrimaryHook.QuoteStatus.ZeroOutput));
    }
}
