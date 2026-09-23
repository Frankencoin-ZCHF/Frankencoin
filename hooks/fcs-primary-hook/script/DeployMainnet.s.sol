// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {FCSPrimaryHook} from "../src/FCSPrimaryHook.sol";
import {FCSPrimaryRouter} from "../src/FCSPrimaryRouter.sol";
import {IFCS} from "../src/interfaces/IFCS.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-hooks/utils/HookMiner.sol";
import {PrepareMainnet} from "./PrepareMainnet.s.sol";

/// @notice Broadcasts the exact CREATE2 deployment computed by PrepareMainnet.s.sol.
/// @dev Re-derives and re-validates the plan itself (does not trust a pasted address/salt),
/// then sends exactly one transaction to the canonical deterministic-deployment factory.
/// The router deploys automatically inside the hook constructor (its first CREATE, nonce 1).
///
/// HookMiner.find skips any candidate address that already has code (see its `hookAddress.code.length
/// == 0` check), so once the canonical hook is live, simply re-running this script does NOT no-op or
/// fail loudly - it silently mines a different salt and deploys a second, different, fully-functional
/// duplicate pair. This already happened once. CANONICAL_HOOK below is the deployment this script must
/// never be allowed to run again after: run() reverts up front if it already has code.
contract DeployMainnet is Script {
    address public constant CANONICAL_HOOK = 0x747a076611A138ae063179800D43d8aE33b7E888;

    error AlreadyDeployed(address canonicalHook);
    error PredictedAddressMismatch(address predicted, address actual);
    error RouterMismatch(address predicted, address actual);
    error RouterBindingMismatch();
    error HookFlagsMismatch();

    function run() external {
        if (CANONICAL_HOOK.code.length != 0) revert AlreadyDeployed(CANONICAL_HOOK);

        PrepareMainnet preparer = new PrepareMainnet();
        PrepareMainnet.Plan memory p = preparer.prepare();

        console2.log("About to broadcast CREATE2 deployment to factory", preparer.FACTORY());
        console2.log("Predicted hook   ", p.hook);
        console2.log("Predicted router ", p.router);
        console2.log("Salt");
        console2.logBytes32(p.salt);
        console2.log("Initcode hash");
        console2.logBytes32(p.initCodeHash);

        vm.startBroadcast();
        (bool ok,) = preparer.FACTORY().call(p.factoryCalldata);
        vm.stopBroadcast();

        require(ok, "CREATE2 factory call reverted");
        // The deterministic-deployment proxy's return data isn't a reliable ABI-encoded address, so
        // don't decode it. A CREATE2 address is a pure function of (factory, salt, keccak256(initcode));
        // checking code now exists at the address we already mined is the real proof of a correct deploy.
        address deployed = p.hook;
        if (deployed.code.length == 0) revert PredictedAddressMismatch(p.hook, address(0));

        FCSPrimaryHook hook = FCSPrimaryHook(deployed);
        if (address(hook.router()) != p.router) revert RouterMismatch(p.router, address(hook.router()));
        if (p.router.code.length == 0) revert RouterMismatch(p.router, address(0));
        if (address(hook.router().hook()) != deployed) revert RouterBindingMismatch();
        if (hook.getHookPermissions().beforeInitialize != true) revert HookFlagsMismatch();

        console2.log("Deployed hook  ", deployed);
        console2.log("Deployed router", address(hook.router()));
        console2.log("SUCCESS: addresses, router binding and hook flags match the read-only plan.");
    }
}
