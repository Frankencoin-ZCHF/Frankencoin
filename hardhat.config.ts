import "@nomicfoundation/hardhat-ethers";
import "@nomicfoundation/hardhat-verify";
import "@nomicfoundation/hardhat-toolbox";
import "@nomicfoundation/hardhat-network-helpers";
import "@nomicfoundation/hardhat-ignition-ethers";
import "hardhat-deploy";
import "hardhat-abi-exporter";
import "hardhat-contract-sizer";
import { HardhatUserConfig } from "hardhat/config";
import { getChildFromSeed } from "./helper/wallet";

import dotenv from "dotenv";
dotenv.config();

// Extend Hardhat typings
declare module "hardhat/types/config" {
  export interface HardhatNetworkUserConfig {
    testnet?: boolean;
  }

  export interface HttpNetworkUserConfig {
    testnet?: boolean;
  }

  export interface HardhatNetworkConfig {
    testnet?: boolean;
  }

  export interface HttpNetworkConfig {
    testnet?: boolean;
  }
}

// ---------------------------------------------------------------------------------------

const index = process.env.DEPLOYER_SEED_INDEX;
const start = index && index?.length > 0 ? parseInt(index) : 0;

const seed = process.env.DEPLOYER_SEED ?? process.env.DEPLOYER_ACCOUNT_SEED;
if (!seed) throw new Error("Failed to import the seed string from .env");
const wallet = getChildFromSeed(seed, start); // deployer
console.log("### Deployer Wallet ###");
console.log(wallet.address, `index: `, wallet.index);

const alchemy = process.env.ALCHEMY_RPC_KEY;
if (alchemy?.length == 0 || !alchemy)
  console.log("WARN: No Alchemy Key found in .env");

const etherscan = process.env.ETHERSCAN_API;
if (etherscan?.length == 0 || !etherscan)
  console.log("WARN: No Etherscan Key found in .env");

// ---------------------------------------------------------------------------------------

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  networks: {
    mainnet: {
      url: `https://eth-mainnet.g.alchemy.com/v2/${alchemy}`,
      chainId: 1,
      gas: "auto",
      gasPrice: "auto",
      gasMultiplier: 0.7,
      accounts: [wallet.privateKey],
      timeout: 50_000,
      testnet: false,
    },
    sepolia: {
      url: `https://eth-sepolia.g.alchemy.com/v2/${alchemy}`,
      chainId: 11155111,
      gas: "auto",
      gasPrice: "auto",
      accounts: [wallet.privateKey],
      timeout: 50_000,
      testnet: true,
    },
    polygon: {
      url: `https://virtual.polygon.rpc.tenderly.co/59fa380d-d2aa-44f6-8242-5ed8d8906173`,
      chainId: 137,
      gas: "auto",
      gasPrice: "auto",
      accounts: [wallet.privateKey],
      timeout: 50_000,
      testnet: false,
    },
    optimism: {
      url: `https://virtual.optimism.rpc.tenderly.co/7041682d-1f98-4e4f-a500-d330f37945bf`,
      chainId: 10,
      gas: "auto",
      gasPrice: "auto",
      accounts: [wallet.privateKey],
      timeout: 50_000,
      testnet: false,
    },
    arbitrum: {
      url: `https://virtual.arbitrum.rpc.tenderly.co/b4fd0976-3b5c-44c8-b6aa-f5c6a68c8cba`,
      chainId: 42161,
      gas: "auto",
      gasPrice: "auto",
      accounts: [wallet.privateKey],
      timeout: 50_000,
      testnet: false,
    },
    base: {
      url: `https://virtual.base.rpc.tenderly.co/69ddfa3a-d326-4305-a5c5-21363c036e3e`,
      chainId: 8453,
      gas: "auto",
      gasPrice: "auto",
      accounts: [wallet.privateKey],
      timeout: 50_000,
      testnet: false,
    },
    avalanche: {
      url: `https://virtual.avalanche.rpc.tenderly.co/0644a35d-3766-4bf5-923a-5fa8f0b63214`,
      chainId: 43114,
      gas: "auto",
      gasPrice: "auto",
      accounts: [wallet.privateKey],
      timeout: 50_000,
      testnet: false,
    },
    gnosis: {
      url: `https://virtual.gnosis.rpc.tenderly.co/dc8b8dee-b55e-45e0-99d7-dca7d9915925`,
      chainId: 100,
      gas: "auto",
      gasPrice: "auto",
      accounts: [wallet.privateKey],
      timeout: 50_000,
      testnet: false,
    },
    sonic: {
      url: `https://virtual.sonic.rpc.tenderly.co/4dc7eb6a-3ce0-48eb-908b-80ffda59033c`,
      chainId: 146,
      gas: "auto",
      gasPrice: "auto",
      accounts: [wallet.privateKey],
      timeout: 50_000,
      testnet: false,
    },
    citrea: {
      url: `https://rpc.testnet.citrea.xyz`,
      chainId: 5115,
      gas: "auto",
      gasPrice: "auto",
      accounts: [wallet.privateKey],
      timeout: 50_000,
    },
  },
  etherscan: {
    apiKey: etherscan,
    // apiKey: {
    // citrea: 'your API key',
    // },
    // customChains: [
    // 	{
    // 		network: 'citrea',
    // 		chainId: 5115,
    // 		urls: {
    // 			apiURL: 'https://explorer.testnet.citrea.xyz/api',
    // 			browserURL: 'https://explorer.testnet.citrea.xyz',
    // 		},
    // 	},
    // ],
  },
  sourcify: {
    enabled: true,
  },
  namedAccounts: {
    deployer: {
      default: 0,
    },
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts",
    deploy: "./scripts/deployment/deploy",
    deployments: "./scripts/deployment/deployments",
  },
  contractSizer: {
    alphaSort: false,
    runOnCompile: false,
    disambiguatePaths: false,
  },
  gasReporter: {
    enabled: true,
    currency: "USD",
  },
  abiExporter: [
    {
      path: "./abi",
      clear: false,
      runOnCompile: true,
      flat: false,
      spacing: 4,
      pretty: false,
    },
    {
      path: "./abi/signature",
      clear: false,
      runOnCompile: true,
      flat: false,
      spacing: 4,
      pretty: true,
    },
  ],
  mocha: {
    timeout: 120000,
  },
  typechain: {
    outDir: "typechain",
    target: "ethers-v6",
  },
};

export default config;
