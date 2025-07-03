// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

contract TestTokenAdminRegistry {
    struct TokenConfig {
        address administrator; // the current administrator of the token
        address pendingAdministrator; // the address that is pending to become the new administrator
        address tokenPool; // the token pool for this token. Can be address(0) if not deployed or not configured.
    }
    mapping(address => TokenConfig) public tokenConfigs;

    event FunctionCalled(string name, bytes args);

    function getPool(address token) external returns (address) {
        emit FunctionCalled("getPool", abi.encode(token));
    }

    function proposeAdministrator(address localToken, address administrator) external {
        emit FunctionCalled("proposeAdministrator", abi.encode(localToken, administrator));
    }

    function acceptAdminRole(address localToken) external {
        emit FunctionCalled("acceptAdminRole", abi.encode(localToken));
    }

    function setPool(address localToken, address pool) external {
        emit FunctionCalled("setPool", abi.encode(localToken, pool));
    }

    function transferAdminRole(address localToken, address newAdmin) external {
        emit FunctionCalled("transferAdminRole", abi.encode(localToken, newAdmin));
    }

    function setTokenConfig(address localToken, TokenConfig memory config) external {
        tokenConfigs[localToken] = config;
    }

    function getTokenConfig(address localToken) external view returns (TokenConfig memory) {
        return tokenConfigs[localToken];
    }
}
