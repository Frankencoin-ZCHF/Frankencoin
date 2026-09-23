// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {
    TempoExchangeAggregator
} from "../src/aggregator-hooks/implementations/TempoExchange/TempoExchangeAggregator.sol";
import {ITempoExchange} from "../src/aggregator-hooks/implementations/TempoExchange/interfaces/ITempoExchange.sol";
import {SafePoolSwapTest} from "../test/aggregator-hooks/shared/SafePoolSwapTest.sol";

/// @title DeployTempoAggregator
/// @notice Deploys the TempoExchangeAggregator hook and a SafePoolSwapTest router
/// @dev Uses the deterministic CREATE2 factory directly to ensure correct hook addresses
///      on both standard EVM and Tempo (type 0x76) chains.
/// @dev On Tempo testnet, fund wallet first via RPC:
///      curl -X POST https://rpc.moderato.tempo.xyz -H "Content-Type: application/json" \
///        -d '{"jsonrpc":"2.0","method":"tempo_fundAddress","params":["ADDRESS"],"id":1}'
contract DeployTempoAggregator is Script {
    address constant DEFAULT_POOL_MANAGER = 0x33620f62C5b9B2086dD6b62F4A297A9f30347029;
    address constant DEFAULT_TEMPO_EXCHANGE = 0xDEc0000000000000000000000000000000000000;

    /// @notice Deploy using pre-mined salt (e.g. from script/mine_hook.sh). Run with --broadcast --skip-simulation
    /// @dev If the salt was mined via script/mine_hook.sh, you must pass --via-ir so the deployed
    ///      bytecode matches the bytecode used during mining; otherwise CREATE2 yields a different
    ///      address and the hook constructor reverts with HookAddressNotValid.
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        bytes32 salt = vm.envBytes32("HOOK_SALT");

        address poolManager = vm.envOr("POOL_MANAGER", DEFAULT_POOL_MANAGER);
        address tempoExchange = vm.envOr("TEMPO_EXCHANGE", DEFAULT_TEMPO_EXCHANGE);

        bytes memory constructorArgs = abi.encode(poolManager, tempoExchange);
        bytes memory initCode = abi.encodePacked(type(TempoExchangeAggregator).creationCode, constructorArgs);

        // Compute expected address from the deterministic CREATE2 factory
        address expectedHook = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_FACTORY, salt, keccak256(initCode)))))
        );

        console.log("PoolManager:", poolManager);
        console.log("TempoExchange:", tempoExchange);
        console.log("Expected hook address:", expectedHook);

        vm.startBroadcast(deployerKey);

        // Call deterministic CREATE2 factory directly: first 32 bytes = salt, rest = init code
        bytes memory payload = abi.encodePacked(salt, initCode);
        (bool success,) = CREATE2_FACTORY.call(payload);
        require(success, "CREATE2 deployment failed");

        // Verify the hook was deployed with correct address
        require(expectedHook.code.length > 0, "Hook not deployed");
        console.log(string.concat("HOOK_ADDRESS=", vm.toString(expectedHook)));

        // Deploy swap router (standard CREATE is fine)
        SafePoolSwapTest router = new SafePoolSwapTest(IPoolManager(poolManager));
        console.log(string.concat("ROUTER_ADDRESS=", vm.toString(address(router))));

        vm.stopBroadcast();
    }
}
