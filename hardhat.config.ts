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
import { Wallet } from "ethers";
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

// const index = process.env.DEPLOYER_SEED_INDEX;
// const start = index && index?.length > 0 ? parseInt(index) : 0;

// const seed = process.env.DEPLOYER_SEED ?? process.env.DEPLOYER_ACCOUNT_SEED;
// if (!seed) throw new Error("Failed to import the seed string from .env");
// const deployer = getChildFromSeed(seed, start);

const privateKey = process.env.PRIVATE_KEY;
if (!privateKey) throw new Error("Missing PRIVATE_KEY in .env");
const deployer = new Wallet(privateKey);

console.log("### Deployer Wallet ###");
console.log(deployer.address, `index: `, (deployer as any).index ?? 0);

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
      accounts: [deployer.privateKey],
      timeout: 50_000,
      testnet: false,
    },
    sepolia: {
      url: `https://eth-sepolia.g.alchemy.com/v2/${alchemy}`,
      chainId: 11155111,
      gas: "auto",
      gasPrice: "auto",
      accounts: [deployer.privateKey],
      timeout: 50_000,
      testnet: true,
    },
    polygon: {
      url: `https://polygon-mainnet.g.alchemy.com/v2/${alchemy}`,
      chainId: 137,
      gas: "auto",
      gasPrice: "auto",
      accounts: [deployer.privateKey],
      timeout: 50_000,
      testnet: false,
    },
    optimism: {
      url: `https://opt-mainnet.g.alchemy.com/v2/${alchemy}`,
      chainId: 10,
      gas: "auto",
      gasPrice: "auto",
      accounts: [deployer.privateKey],
      timeout: 50_000,
      testnet: false,
    },
    arbitrum: {
      url: `https://arb-mainnet.g.alchemy.com/v2/${alchemy}`,
      chainId: 42161,
      gas: "auto",
      gasPrice: "auto",
      accounts: [deployer.privateKey],
      timeout: 50_000,
      testnet: false,
    },
    base: {
      url: `https://base-mainnet.g.alchemy.com/v2/${alchemy}`,
      chainId: 8453,
      gas: "auto",
      gasPrice: "auto",
      accounts: [deployer.privateKey],
      timeout: 50_000,
      testnet: false,
    },
    avalanche: {
      url: `https://avax-mainnet.g.alchemy.com/v2/${alchemy}`,
      chainId: 43114,
      gas: "auto",
      gasPrice: "auto",
      accounts: [deployer.privateKey],
      timeout: 50_000,
      testnet: false,
    },
    gnosis: {
      url: `https://gnosis-mainnet.g.alchemy.com/v2/${alchemy}`,
      chainId: 100,
      gas: "auto",
      gasPrice: "auto",
      accounts: [deployer.privateKey],
      timeout: 50_000,
      testnet: false,
    },
    sonic: {
      url: `https://sonic-mainnet.g.alchemy.com/v2/${alchemy}`,
      chainId: 146,
      gas: "auto",
      gasPrice: "auto",
      accounts: [deployer.privateKey],
      timeout: 50_000,
      testnet: false,
    },
    citrea: {
      url: `https://rpc.testnet.citrea.xyz`,
      chainId: 5115,
      gas: "auto",
      gasPrice: "auto",
      accounts: [deployer.privateKey],
      timeout: 50_000,
    },
  },
  etherscan: {
    apiKey: {
      mainnet: etherscan!,
      polygon: etherscan!,
      arbitrum: etherscan!,
      optimism: etherscan!,
      base: etherscan!,
      avalanche: etherscan!,
    },
    customChains: [
      {
        network: "mainnet",
        chainId: 1,
        urls: {
          apiURL: "https://api.etherscan.io/v2/api?chainid=1",
          browserURL: "https://etherscan.io",
        },
      },
      {
        network: "polygon",
        chainId: 137,
        urls: {
          apiURL: "https://api.etherscan.io/v2/api?chainid=137",
          browserURL: "https://polygonscan.com",
        },
      },
      {
        network: "arbitrum",
        chainId: 42161,
        urls: {
          apiURL: "https://api.etherscan.io/v2/api?chainid=42161",
          browserURL: "https://arbiscan.io",
        },
      },
      {
        network: "optimism",
        chainId: 10,
        urls: {
          apiURL: "https://api.etherscan.io/v2/api?chainid=10",
          browserURL: "https://optimistic.etherscan.io",
        },
      },
      {
        network: "base",
        chainId: 8453,
        urls: {
          apiURL: "https://api.etherscan.io/v2/api?chainid=8453",
          browserURL: "https://basescan.org",
        },
      },
      {
        network: "avalanche",
        chainId: 43114,
        urls: {
          apiURL: "https://api.etherscan.io/v2/api?chainid=43114",
          browserURL: "https://snowtrace.io",
        },
      },
    ],
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
