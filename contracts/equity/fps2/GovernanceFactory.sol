// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./MainnetVotes.sol";
import "./BridgedVotes.sol";
import "./CCIPGovernance.sol";
import "./MinterGovernance.sol";
import "./InterestGovernance.sol";

/**
 * @title GovernanceFactory
 *
 * This factory contract deploys FPS2 and is intended to be only deployed and used once on every chain
 * that is currently supported. Future chains will need their own logic and build on their own instances
 * of BridgedVotes.
 * 
 * Deployment steps:
 * 1. Deploy GovernanceFactory on mainnet
 * 2. Deploy FPS2 on mainnet, this automatically also deploys the governance contracts
 * 3. Deploy GovernanceFactory on all bridged chains and call deploy(fps2mainnet)
 * 4. Push FPS1 votes and delegations from mainnet to all bridged chains using GovernanceSender.syncVotes.
 *    The following voters must be pushed:
 *     - Mainnet FPS2 address
 *     - Mainnet InterestGovernance address
 *     - Mainnet MinterGovernance address
 * 5. Later: push FPS1 votes to all bridged chains once FPS1 has reached veto power
 */
contract GovernanceFactory {

    address public constant ARACHNID_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 public constant INNER_SALT = keccak256("Frankencoin FPS2 InnerFactory v1");

    error InnerFactoryDeploymentFailed();

    function deploy(address fps2mainnet) external returns (address governance) {
        address inner = innerFactoryAddress();
        if (inner.code.length == 0) {
            (bool ok, ) = ARACHNID_DEPLOYER.call(abi.encodePacked(INNER_SALT, type(InnerFactory).creationCode));
            if (!ok || inner.code.length == 0) revert InnerFactoryDeploymentFailed();
        } else {
            // Already deployed, do nothing.
        }
        return InnerFactory(inner).deploy(fps2mainnet);
    }

    function innerFactoryAddress() public pure returns (address) {
        bytes32 initCodeHash = keccak256(type(InnerFactory).creationCode);
        bytes32 h = keccak256(abi.encodePacked(bytes1(0xff), ARACHNID_DEPLOYER, INNER_SALT, initCodeHash));
        return address(uint160(uint256(h)));
    }
}

/**
 * @notice Same-address-on-every-chain deployer for the FPS2 governance contracts.
 * Reachable at a deterministic address via Arachnid CREATE2 from FPS2Factory; never deployed
 * by hand. Constructor has no arguments so its init code is identical across chains.
 */
contract InnerFactory {

    IFrankencoin public constant MAINNET_ZCHF = IFrankencoin(0xB58E61C3098d85632Df34EecfB899A1Ed80921cB);
    IGovernance public constant MAINNET_FPS1 = IGovernance(0x1bA26788dfDe592fec8bcB0Eaff472a42BE341B2);
    ILeadrateProposal public constant MAINNET_BORROWING_LEADRATE = ILeadrateProposal(0x3BF301B0e2003E75A3e86AB82bD1EFF6A9dFB2aE);
    ILeadrateProposal public constant MAINNET_SAVINGS_LEADRATE = ILeadrateProposal(0x27d9AD987BdE08a0d083ef7e0e4043C857A17B38);
    ITokenPoolStub public constant MAINNET_TOKEN_POOL = ITokenPoolStub(0x9359cd75549DaE00Cdd8D22297BC9B13FbBe4B79);
    
    IFrankencoin public constant L2_FRANKENCOIN = IFrankencoin(0xD4dD9e2F021BB459D5A5f6c24C12fE09c5D45553);
    ITokenPoolStub public constant TOKEN_POOL = ITokenPoolStub(0x7CBac118B3F299f8BE1C3DBA66368D96B37D7743);

    function deploy(address fps2mainnet) external returns (address votes, address helper) {
        IGovernance governance = createGovernance(fps2mainnet);
        if (block.chainid == 1) {
            CCIPGovernance ccipGov = new CCIPGovernance(governance, fps2mainnet, MAINNET_TOKEN_POOL.owner());
            MinterGovernance minterGov = new MinterGovernance(MAINNET_ZCHF, MAINNET_FPS1, governance, address(ccipGov), fps2mainnet);
            InterestGovernance interestGov = new InterestGovernance(MAINNET_FPS1, governance, fps2mainnet, MAINNET_BORROWING_LEADRATE, MAINNET_SAVINGS_LEADRATE, address(minterGov));
            return (address(governance), address(interestGov));
        } else {
            CCIPGovernance ccipGov = new CCIPGovernance(governance, fps2mainnet, TOKEN_POOL.owner());
            return (address(governance), address(0));
        }
    }

    function createGovernance(address fps2mainnet) internal returns (IGovernance) {
        if (block.chainid == 1) {
            return new MainnetVotes(fps2mainnet, IRouterClient(MAINNET_TOKEN_POOL.getRouter()));
        } else {
            return new BridgedVotes(TOKEN_POOL.getRouter());
        }
    }

}

interface ITokenPoolStub {
    function owner() external view returns (ICCIPAdmin);
    function getRouter() external view returns (address);
}
