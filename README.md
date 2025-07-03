# FrankenCoin Core

This is the source code repository for the smart contracts of the oracle-free, collateralized stablecoin Frankencoin.

There also is a [public frontend](https://frankencoin.com), a [documentation page](https://docs.frankencoin.com), an outdated [Frankencoin Research Paper](https://www.snb.ch/n/mmr/reference/sem_2022_06_03_maire/source/sem_2022_06_03_maire.n.pdf), and a more recent chapter of a [pending phd thesis](https://frankencoin.com/thesis-preprint-frankencoin.pdf).

### Source Code

The source code can be found in the [contracts](contracts) folder. The following are the most important contracts.

| Contract             | Description                                     |
| -------------------- | ----------------------------------------------- |
| Frankencoin.sol      | The Frankencoin (ZCHF) ERC20 token              |
| Equity.sol           | The Frankencoin Pool Shares (FPS) ERC20 token   |
| MintingHub.sol       | Plugin for oracle-free collateralized minting   |
| Position.sol         | A borrowed minting position holding collateral  |
| PositionRoller.sol   | A module to roll positions into new ones        |
| StablecoinBridge.sol | Plugin for 1:1 swaps with other CHF stablecoins |
| Savings.sol          | A module to pay out interest to ZCHF holders    |

# Development

### Yarn Package Scripts

```json
// yarn run <command> args...

"wallet": "npx ts-node helper/wallet.info.ts",

"compile": "npx hardhat compile",
"test": "npx hardhat test",
"coverage": "npx hardhat coverage",

"deploy": "npx hardhat ignition deploy",
"verify": "npx hardhat verify",

"build": "tsup",
"publish": "npm publish --access public"
```

### 1. Install dependencies

`yarn install`

### 2. Set Environment

> See .env.example

```JSON
file: .env

ALCHEMY_RPC_KEY=...
DEPLOYER_SEED="test test test test test test test test test test test junk"
DEPLOYER_SEED_INDEX=1 // optional, select deployer
ETHERSCAN_API=...
CHAINID=1 // Replace with correct chain id
```

> Create new session or re-navigate to the current directory, to make sure environment is loaded from `.env`

### 3. Develop Smart Contracts

> Develop your contracts in the `/contracts` directory and compile with:

```Bash
yarn run compile					# Compiles all contracts
```

### 4. Testing

> All test files are located in /test directory. Run tests using:

```Bash
yarn run test                    	# Run all tests
yarn run test test/TESTSCRIPT.ts 	# Run specific test file
yarn run coverage               	# Generate test coverage report
```

With tsc-watch (auto refresh commands)

```shell
npx tsc-watch --onCompilationComplete "npx hardhat test ./test/RollerTests.ts"
```

### 5.0 Deploy Contract (manual)

Then run a deployment script with tags and network params (e.g., `sepolia` that specifies the network)

```shell
hh deploy --network sepolia --tags MockTokens
hh deploy --network sepolia --tags Frankencoin
hh deploy --network sepolia --tags PositionFactory
hh deploy --network sepolia --tags MintingHub
hh deploy --network sepolia --tags MockCHFToken
hh deploy --network sepolia --tags XCHFBridge
hh deploy --network sepolia --tags positions
```

> Recommanded commands for `sepolia` network.
> The networks are configured in `hardhat.config.ts`.

### 5. Write Deployment Scripts (via ignition deploy and verify)

> Deployment modules are located in /ignition/modules. Deploy your contracts:

```Bash
yarn run deploy ignition/modules/MODULE --network polygon --verify --deployment-id MODULE_ID_01

--> increase: deployment-id
```

This will:

- Compile and deploy contracts
- Verify on Etherscan and Sourcify
- Generate deployment artifacts in /ignition/deployments

Verify:

- verifies contract on etherscan
- verifies contract on sourcify

Key deployment files:

- deployed_addresses.json: Contains contract addresses
- journal.json: Detailed deployment logs

- creates deployment artifacts in /ignition`/deployments` directory
- creates ./ignition/deployments/[deployment]/`deployed_addresses.json`
- creates ./ignition/deployments/[deployment]/`journal.jsonl`
- creates constructor-args in /ignition`/constructor-args` directory, as JS module export

### 5.1 Example

```Bash
✔ Confirm deploy to network polygon (137)? … yes
{
  message: 'Config Info: Deploying Module with accounts',
  admin: '0xb687FE7E47774B22F10Ca5E747496d81827167E3',
  executor: '0xBdae8D35EDe5bc5174E805DcBe3F7714d142DAAb',
  member: '0x2ACf17C04F1d8BE7E9D5529894DCee86bf2fcdC3'
}
Constructor Args
[
  '0xb687FE7E47774B22F10Ca5E747496d81827167E3',
  '0xBdae8D35EDe5bc5174E805DcBe3F7714d142DAAb',
  '0x2ACf17C04F1d8BE7E9D5529894DCee86bf2fcdC3'
]
Hardhat Ignition 🚀

Deploying [ MembershipModule ]

Batch #1
  Executed MembershipModule#Membership

Batch #2
  Executed MembershipModule#Storage

[ MembershipModule ] successfully deployed 🚀

Deployed Addresses

MembershipModule#Membership - 0x72950A0A9689fCA941Ddc9E1a58dcD3fb792E3D2
MembershipModule#Storage - 0x8A7e8091e71cCB7D1EbDd773C26AD82AAd323328

Verifying deployed contracts

Verifying contract "contracts/Membership.sol:Membership" for network polygon...
Contract contracts/Membership.sol:Membership already verified on network polygon:
  - https://polygonscan.com/address/0x72950A0A9689fCA941Ddc9E1a58dcD3fb792E3D2#code

Verifying contract "contracts/Storage.sol:Storage" for network polygon...
Contract contracts/Storage.sol:Storage already verified on network polygon:
  - https://polygonscan.com/address/0x8A7e8091e71cCB7D1EbDd773C26AD82AAd323328#code

✨  Done in 69.96s.
```

### 5.2 Manual Verify

`npx hardhat verify --network polygon --constructor-args ./ignition/constructor-args/$FILE.js $ADDRESS`

or manually include unrelated contracts

`npx hardhat ignition verify $DEPLOYMENT --include-unrelated-contracts`

### 6 Prepare NPM Package Support

- [x] Export ready to use TypeScript ABIs
- [x] Export ready to use TypeScript deployed address config
- [ ] ...

### 6.1 TypeScript ABIs

Export contract ABIs for npm package usage by copying the JSON into dedicated TypeScript files:

```TS
file: exports/abis/...

export const StorageABI = [
...
JSON
...
] as const;
```

### 6.2 TypeScript Address Config

Provides a mapping of contract addresses for the Membership and Storage contracts deployed on different blockchain networks.

The `ADDRESS` object contains the contract addresses for the `mainnet` and `polygon` networks, with the network ID as the key.
The `zeroAddress` is used as a placeholder for the `mainnet` network, as the contracts have not been deployed there yet.

```TS
file: exports/address.config.ts

import { mainnet, polygon } from 'viem/chains';
import { Address, zeroAddress } from 'viem';

export interface ChainAddress {
	membership: Address;
	storage: Address;
}

export const ADDRESS: Record<number, ChainAddress> = {
	[mainnet.id]: {
		membership: zeroAddress, // if not available
		storage: zeroAddress,
	},
	[polygon.id]: {
		membership: '0x72950A0A9689fCA941Ddc9E1a58dcD3fb792E3D2',
		storage: '0x8A7e8091e71cCB7D1EbDd773C26AD82AAd323328',
	},
};
```

# 7. TSUP and npm package

### 7.1 TSUP

> Config: /tsup.config.ts

TSUP bundles TypeScript code into optimized JavaScript packages. This package uses TSUP to create production-ready builds.

`yarn run build`

### 7.2 NPM Package

> **Increase Version:** Update version number in package.json using semantic versioning (e.g. 0.0.1 -> 0.0.2) before publishing new changes.

```
file: /package.json

"name": "@frankencoin/zchf",
"version": "0.2.16", <-- HERE
```

Login to your NPM account

`npm login`

This will publish your package to NPM with public access, making it **available for anyone to install and use**.

`yarn run publish`

To publish new version. `publish: "npm publish --access public"`

> **Note**: During npm package publishing, the command may execute twice. The second execution will fail with a version conflict since the package is already published. This is expected behavior and the first publish will have succeeded.

### 7.3 How to transpile package into bundled apps

(not needed, since its already a true JS bundled module)

E.g. for `NextJs` using the `next.config.js` in root of project.

```js
/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  transpilePackages: ["@.../core", "@.../api"],
};

module.exports = nextConfig;
```

# CCIP Integration

The Frankencoin is also integrated with the CCIP (Cross-Chain Interoperability Protocol) to enable seamless cross-chain transactions. This allows users to transfer tokens between different blockchain networks seamlessly.

The main contracts involved in CCIP integration are:
| Contract | Description |
| --- | --- |
| `CCIPAdmin.sol` | The CCIPAdmin contract is responsible for managing the CCIP integration. It provides functions for setting up and configuring the CCIP integration. |
| `BridgeAccounting.sol` | The BridgeAccounting contract is responsible for handling losses and profits occured on remote chains. It informs the mainnet system about the losses and profits. |
| `BridgedGovernance.sol` | The BridgedGovernance is the governance contract used on remote chains to manage the deployment there. Voting power and delegation is synced from mainnet. |
| `GovernanceSender.sol` | The contract that informs remote chains about the voting power and delegation of voters on mainnet. |
| `CrossChainERC20.sol` | Abstract contract that provides users with a simple integration to send and receive tokens across different blockchain networks. |
| `BridgedLeadrate.sol` | The leadrate contract for remote chains. It receives the current leadrate from the mainnet and stores it. |
| `LeadrateSender.sol` | The contract that informs remote chains about the current leadrate on mainnet. |
| `BridgedSavings.sol` | Uses the `BridgedLeadrate.sol` contract to provide the savings functionality for remote chains. |
| `BridgedFrankencoin.sol` | The Frankencoin contract for remote chains. It uses the `CrossChainERC20.sol` contract to provide users with a simple integration to send and receive tokens across different blockchain networks. |

## Deployment to new remote chains

To deploy the Frankencoin contracts to a new remote chain, follow these steps:

### 1. Update configurations

Update the `scripts/deployment/parameters/paramsCCIP.json` file with the necessary parameters for the new remote chain.
Under the key `remoteChains` you can add initial connections to other chains that should be available.
Also update all other `scripts/deployment/parameters/params*.json` files with the correct values for the new remote chain.

Then update the `hardhat.config.ts` file with the new remote chain.

### 2. Set Environment

> See .env.example

```JSON
file: .env

ALCHEMY_RPC_KEY=...
DEPLOYER_SEED="test test test test test test test test test test test junk"
DEPLOYER_SEED_INDEX=1 // optional, select deployer
ETHERSCAN_API=...
CHAINID=1 // Replace with correct chain id
```

> Create new session or re-navigate to the current directory, to make sure environment is loaded from `.env`

### 3. Deploy contracts

```sh
npx hardhat deploy --tags l2 --network YOUR_CHAIN
```

### 4. Verify contracts

The deployment scripts log for each deployed contract the command that needs to be run to verify the contract.
Follow the instructions of the deployment script to verify all deployed contracts.

### 5. Update configuration files

After all contracts are deployed and verified, update the `scripts/deployment/parameters/paramsCCIP.json` file with the addresses of the deployed contracts.
Also update `exports/address.config.ts` with the addresses of the deployed contracts so they are available in the NPM module.