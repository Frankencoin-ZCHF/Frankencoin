// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CREATE3} from "solmate/src/utils/CREATE3.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMinerCreate3} from "../../src/utils/HookMinerCreate3.sol";
import {MockBlankHook} from "../mocks/MockBlankHook.sol";

/// @dev Address mining is expensive per run; pinned low to keep CI fast (global default is raised in foundry.toml).
/// forge-config: default.fuzz.runs = 10
contract HookMinerCreate3Test is Test {
    function test_fuzz_hookMinerCreate3(uint16 flags, uint256 number) public {
        bytes memory creationCode = type(MockBlankHook).creationCode;
        bytes memory ctorArgs = abi.encode(IPoolManager(address(0)), number, flags);

        (address predicted, bytes32 salt) = HookMinerCreate3.find(address(this), uint160(flags), creationCode, ctorArgs);

        address deployed = CREATE3.deploy(salt, abi.encodePacked(creationCode, ctorArgs), 0);

        assertEq(deployed, predicted, "CREATE3 deploy address must match the address predicted by find()");
        assertEq(
            uint160(deployed) & HookMinerCreate3.FLAG_MASK,
            flags & HookMinerCreate3.FLAG_MASK,
            "deployed address low 14 bits must equal requested hook flags"
        );

        MockBlankHook c = MockBlankHook(deployed);
        c.forceValidateAddress();
        assertEq(c.num(), number, "deployed hook must report the constructor-supplied number");
    }

    function test_hookMinerCreate3_findWithPrefix() public {
        uint16 flags = uint16(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        uint256 number = 42;
        bytes memory creationCode = type(MockBlankHook).creationCode;
        bytes memory ctorArgs = abi.encode(IPoolManager(address(0)), number, flags);

        (address predicted, bytes32 salt) =
            HookMinerCreate3.findWithPrefix(address(this), uint160(flags), creationCode, ctorArgs, "hook-");

        address deployed = CREATE3.deploy(salt, abi.encodePacked(creationCode, ctorArgs), 0);

        assertEq(deployed, predicted, "CREATE3 deploy address must match the address predicted by findWithPrefix()");
        assertEq(
            uint160(deployed) & HookMinerCreate3.FLAG_MASK,
            flags & HookMinerCreate3.FLAG_MASK,
            "deployed address low 14 bits must equal requested hook flags"
        );
        MockBlankHook(deployed).forceValidateAddress();
    }
}
