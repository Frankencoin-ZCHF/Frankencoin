// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Script, console2} from "forge-std/Script.sol";
import {FCSPrimaryHook} from "../src/FCSPrimaryHook.sol";
import {IFCS} from "../src/interfaces/IFCS.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-hooks/utils/HookMiner.sol";

/// @notice Read-only deployment preparation. Never broadcasts, signs or deploys.
contract PrepareMainnet is Script {
    struct Plan {
        address hook;
        address router;
        bytes32 salt;
        bytes32 initCodeHash;
        bytes factoryCalldata;
    }
    address public constant FCS = 0xDb861830D9Ae2d1fCF99fA0cfd3973de382B0B5b;
    address public constant ZCHF = 0xB58E61C3098d85632Df34EecfB899A1Ed80921cB;
    address public constant FPS = 0x1bA26788dfDe592fec8bcB0Eaff472a42BE341B2;
    address public constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    error WrongChain();
    error DeploymentMismatch();

    function prepare() public view returns (Plan memory p) {
        if (block.chainid != 1) revert WrongChain();
        if (
            FCS.codehash != 0x9dacc056e5f2d59b75a9c9ae8a3cd5134abf7bfb675462f50c12ab777603cc62
                || MANAGER.codehash != 0x785f1014552b7ce7d5fb7d0c970ca60edee94fd00425d7ca21609acac7ce1293
                || FACTORY.code.length == 0 || IFCS(FCS).asset() != ZCHF || IFCS(FCS).ZCHF() != ZCHF
                || IFCS(FCS).FPS1() != FPS
        ) revert DeploymentMismatch();
        bytes memory args = abi.encode(IPoolManager(MANAGER), IFCS(FCS));
        (p.hook, p.salt) = HookMiner.find(FACTORY, 0x2888, type(FCSPrimaryHook).creationCode, args);
        bytes memory initCode = abi.encodePacked(type(FCSPrimaryHook).creationCode, args);
        p.initCodeHash = keccak256(initCode);
        p.factoryCalldata = abi.encodePacked(p.salt, initCode);
        // Router is the hook's first CREATE (nonce 1), executed inside its constructor.
        p.router = address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", p.hook, hex"01")))));
    }

    function run() external view returns (address predicted, bytes32 salt, bytes32 initCodeHash) {
        Plan memory p = prepare();
        console2.log("READ ONLY: no transactions generated or broadcast");
        console2.log("Hook", p.hook);
        console2.log("Router", p.router);
        console2.log("CREATE2 salt");
        console2.logBytes32(p.salt);
        console2.log("Initcode hash");
        console2.logBytes32(p.initCodeHash);
        return (p.hook, p.salt, p.initCodeHash);
    }
}
