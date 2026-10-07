// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FCSPrimaryRouter} from "../src/FCSPrimaryRouter.sol";

/// @notice Initializes the canonical ZCHF/FCS primary pool on the already-deployed, already-verified
/// hook. Reads the pool key from the deployed router rather than reconstructing it, and hardcodes the
/// expected hook address so this can never target the wrong (e.g. accidentally-redeployed) contract.
/// @dev Naturally idempotent: PoolManager.initialize reverts PoolAlreadyInitialized on a repeat call,
/// so unlike the CREATE2 hook deployment, accidentally re-running this cannot create a duplicate pool.
/// This script also pre-checks and reverts before ever broadcasting if the pool already exists.
///
/// Initial price is nominal 1:1, matching Uniswap's own convention for this exact hook pattern: their
/// official, audited WstETHHook mainnet deployment (0xcdde8f9c3414a00f804e5c565eed9949ad17e888) is
/// initialized at nominal 1:1 despite wstETH/stETH genuinely not being 1:1 (~1.245 stETH per wstETH at
/// time of writing). This hook fully absorbs every swap's specified amount via its returned
/// BeforeSwapDelta, so v4 core's own price-moving swap step never runs for this pool (confirmed by
/// test_noLPInventoryAndSlot0DoesNotPricePrimary): slot0.sqrtPriceX96 is frozen at whatever it's
/// initialized to, forever, regardless of trading activity, and is not used for pricing by the hook
/// itself. A round, obviously-nominal placeholder is the clearer signal to any external reader that this
/// is a wrapper-hook pool and slot0 should not be trusted as a price, versus a precise-looking computed
/// number that could be mistaken for a real one.
contract InitializePool is Script {
    using PoolIdLibrary for PoolKey;

    address public constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant HOOK = 0x747a076611A138ae063179800D43d8aE33b7E888;
    address public constant ROUTER = 0xc056Bb03EB2eF7F86f570AAB52C8Fba13B3E8566;
    uint160 public constant INITIAL_SQRT_PRICE_X96 = 1 << 96;

    error RouterHookMismatch(address expected, address actual);
    error PoolAlreadyLive(uint160 existingSqrtPriceX96);
    error InitializeVerificationFailed(uint160 expected, uint160 actual);

    function run() external {
        FCSPrimaryRouter router = FCSPrimaryRouter(ROUTER);
        if (address(router.hook()) != HOOK) revert RouterHookMismatch(HOOK, address(router.hook()));

        PoolKey memory key = router.poolKey();
        IPoolManager manager = IPoolManager(MANAGER);
        PoolId id = key.toId();

        (uint160 existingPrice,,,) = StateLibrary.getSlot0(manager, id);
        if (existingPrice != 0) revert PoolAlreadyLive(existingPrice);

        console2.log("About to initialize pool on manager", MANAGER);
        console2.log("Hook  ", HOOK);
        console2.log("Currency0", Currency.unwrap(key.currency0));
        console2.log("Currency1", Currency.unwrap(key.currency1));
        console2.log("Fee / tickSpacing", key.fee, uint256(int256(key.tickSpacing)));

        vm.startBroadcast();
        manager.initialize(key, INITIAL_SQRT_PRICE_X96);
        vm.stopBroadcast();

        (uint160 priceAfter,,,) = StateLibrary.getSlot0(manager, id);
        if (priceAfter != INITIAL_SQRT_PRICE_X96) revert InitializeVerificationFailed(INITIAL_SQRT_PRICE_X96, priceAfter);
        console2.log("SUCCESS: pool initialized at sqrtPriceX96", priceAfter);
    }
}
