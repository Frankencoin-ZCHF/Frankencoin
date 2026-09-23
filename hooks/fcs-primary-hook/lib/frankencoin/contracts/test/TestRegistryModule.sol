// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

contract TestRegistryModule {
    event FunctionCalled(string name, bytes args);

    function registerAdminViaGetCCIPAdmin(address token) external {
        emit FunctionCalled("registerAdminViaGetCCIPAdmin", abi.encode(token));
    }

}
