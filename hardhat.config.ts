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

// ---------------------------------------------------------------------------------------

const index = process.env.DEPLOYER_SEED_INDEX;
const start = index && index?.length > 0 ? parseInt(index) : 0;

const seed = process.env.DEPLOYER_ACCOUNT_SEED;
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
    version: "0.8.20",
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
    },
    polygon: {
      url: `https://polygon-mainnet.g.alchemy.com/v2/${alchemy}`,
      chainId: 137,
      gas: "auto",
      gasPrice: "auto",
      accounts: [wallet.privateKey],
      timeout: 50_000,
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
