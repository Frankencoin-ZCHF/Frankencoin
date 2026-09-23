// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {AggregatorHookMiner} from "../src/aggregator-hooks/utils/AggregatorHookMiner.sol";

import {StableSwapNGAggregator} from "../src/aggregator-hooks/implementations/StableSwapNG/StableSwapNGAggregator.sol";
import {StableSwapAggregator} from "../src/aggregator-hooks/implementations/StableSwap/StableSwapAggregator.sol";
import {FluidDexT1Aggregator} from "../src/aggregator-hooks/implementations/FluidDexT1/FluidDexT1Aggregator.sol";
import {FluidDexLiteAggregator} from "../src/aggregator-hooks/implementations/FluidDexLite/FluidDexLiteAggregator.sol";
import {
    TempoExchangeAggregator
} from "../src/aggregator-hooks/implementations/TempoExchange/TempoExchangeAggregator.sol";
import {UniswapV3Aggregator} from "../src/aggregator-hooks/implementations/UniswapV3/UniswapV3Aggregator.sol";
import {SlipstreamAggregator} from "../src/aggregator-hooks/implementations/Slipstream/SlipstreamAggregator.sol";
import {
    PancakeSwapV3Aggregator
} from "../src/aggregator-hooks/implementations/PancakeSwapV3/PancakeSwapV3Aggregator.sol";
import {UniswapV2Aggregator} from "../src/aggregator-hooks/implementations/UniswapV2/UniswapV2Aggregator.sol";
import {UniswapXAggregator} from "../src/aggregator-hooks/implementations/UniswapX/UniswapXAggregator.sol";
import {LitePSMAggregator} from "../src/aggregator-hooks/implementations/LitePSM/LitePSMAggregator.sol";

/// @notice Mines an address for an aggregator hook using AggregatorHookMiner
/// @dev This script finds a salt that produces a hook address with the correct flags and first byte identifier
contract MineAggregatorHookScript is Script {
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);
    uint8 constant ID_STABLESWAP = 0xC1;
    uint8 constant ID_STABLESWAPNG = 0xC2;
    uint8 constant ID_FLUIDDEXT1 = 0xF1;
    uint8 constant ID_FLUIDDEXLITE = 0xF3;
    uint8 constant ID_TEMPO = 0x71;
    uint8 constant ID_UNISWAP_V3 = 0x03;
    uint8 constant ID_SLIPSTREAM = 0xA1;
    uint8 constant ID_PANCAKE_V3 = 0x93;
    uint8 constant ID_LITEPSM = 0x95;
    uint8 constant ID_UNISWAP_V2 = 0x02;
    uint8 constant ID_UNISWAPX = 0xDC;

    function run() public view {
        // Read salt offset from environment variable (default to 0)
        // Increment by 160_444 (MAX_LOOP) for each subsequent attempt
        uint256 saltOffset = vm.envOr("SALT_OFFSET", uint256(0));

        // Read deployer address from environment variable (default to CREATE2_DEPLOYER)
        // When using a factory, pass the factory address as the deployer
        // When self-deploying, pass the wallet address that will deploy
        address deployer = vm.envOr("DEPLOYER", CREATE2_DEPLOYER);

        // Load constructor arguments from environment variable.
        // CONSTRUCTOR_ARGS must be abi.encode of constructor params
        bytes memory constructorArgs = vm.envBytes("CONSTRUCTOR_ARGS");

        // First byte identifiers for aggregator hooks:
        // 0xC1 = StableSwap
        // 0xC2 = StableSwap-NG
        // 0xF1 = FluidDexT1
        // 0xF2 = FluidDexV2 (not yet implemented)
        // 0xF3 = FluidDexLite
        // 0x71 = Tempo (TempoExchange)
        // 0x03 = Uniswap V3
        // 0xA1 = Slipstream
        // 0x93 = PancakeSwap V3
        // 0x95 = LitePSM
        // 0x02 = Uniswap V2
        // 0xDC = UniswapX

        uint8 firstByte = uint8(vm.envUint("PROTOCOL_ID"));
        bytes memory creationCode;
        if (firstByte == ID_STABLESWAP) {
            creationCode = type(StableSwapAggregator).creationCode;
        } else if (firstByte == ID_STABLESWAPNG) {
            creationCode = type(StableSwapNGAggregator).creationCode;
        } else if (firstByte == ID_FLUIDDEXT1) {
            creationCode = type(FluidDexT1Aggregator).creationCode;
        } else if (firstByte == 0xF2) {
            revert("FluidDexV2 not yet implemented");
        } else if (firstByte == ID_FLUIDDEXLITE) {
            creationCode = type(FluidDexLiteAggregator).creationCode;
        } else if (firstByte == ID_TEMPO) {
            creationCode = type(TempoExchangeAggregator).creationCode;
        } else if (firstByte == ID_UNISWAP_V3) {
            creationCode = type(UniswapV3Aggregator).creationCode;
        } else if (firstByte == ID_SLIPSTREAM) {
            creationCode = type(SlipstreamAggregator).creationCode;
        } else if (firstByte == ID_PANCAKE_V3) {
            creationCode = type(PancakeSwapV3Aggregator).creationCode;
        } else if (firstByte == ID_LITEPSM) {
            creationCode = type(LitePSMAggregator).creationCode;
        } else if (firstByte == ID_UNISWAP_V2) {
            creationCode = type(UniswapV2Aggregator).creationCode;
        } else if (firstByte == ID_UNISWAPX) {
            creationCode = type(UniswapXAggregator).creationCode;
        } else {
            revert("Invalid protocol ID");
        }

        // Aggregator hooks require BEFORE_SWAP_FLAG, BEFORE_SWAP_RETURNS_DELTA_FLAG, BEFORE_INITIALIZE_FLAG, and BEFORE_ADD_LIQUIDITY_FLAG
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );

        console.log("Deployer address:", deployer);
        console.log("Searching with salt offset:", saltOffset);

        // Mine a salt that will produce a hook address with the correct flags and first byte
        (address hookAddress, bytes32 salt) =
            AggregatorHookMiner.find(deployer, flags, firstByte, creationCode, constructorArgs, saltOffset);

        // Output the results
        console.log("=== Aggregator Hook Mining Results ===");
        console.log("Hook Address:", vm.toString(hookAddress));
        console.log("Salt (bytes32):", vm.toString(salt));
        console.log("Salt (uint256):", uint256(salt));
        console.log("Deployer:", deployer);
        console.log("First Byte:", firstByte);
        console.log("Flags:", flags);
        console.log("=====================================");
    }
}
