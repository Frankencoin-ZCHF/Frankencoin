import {
  arbitrum,
  avalanche,
  base,
  gnosis,
  mainnet,
  optimism,
  polygon,
  sonic,
} from "viem/chains";
import { Address } from "viem";

export type ChainIdMain = typeof mainnet.id;

export type ChainIdSide =
  | typeof polygon.id
  | typeof arbitrum.id
  | typeof optimism.id
  | typeof base.id
  | typeof avalanche.id
  | typeof gnosis.id
  | typeof sonic.id;

export type ChainId = ChainIdMain | ChainIdSide;

export type ChainAddressMainnet = {
  // identifier
  chainId: typeof mainnet.id;
  chainSelector: string;

  // core
  frankencoin: Address; // ZCHF token
  equity: Address; // FPS token

  // utils
  wFPS: Address; // wrapped FPS

  // minting hub v1
  mintingHubV1: Address;
  positionFactoryV1: Address;

  // minting hub v2 + utils v2
  savingsV2: Address;
  rollerV2: Address;
  mintingHubV2: Address;
  positionFactoryV2: Address;

  // stablecoin swap bridges
  stablecoinBridgeXCHF: Address;
  xchfToken: Address;
  stablecoinBridgeVCHF: Address;
  vchfToken: Address;

  // multi chain support
  transferReference: Address; // separate SC for mainnet transfers
  savingsReferral: Address; // detached, implements referral

  // ccip support
  ccipAdmin: Address;
  ccipTokenPool: Address;
  ccipBridgeAccounting: Address;
  ccipGovernanceSender: Address;
  ccipLeadrateSender: Address;
  ccipTokenAdminRegistry: Address;
  ccipRmnProxy: Address;
  ccipRouter: Address;
  linkToken: Address;
};

export type ChainAddressPolygon = {
  // identifier
  chainId: typeof polygon.id;
  chainSelector: string;

  // standard bridges
  bridgePolygonFrankencoin: Address;
  bridgePolygonWfps: Address;

  // ccip cross chain support
  ccipTokenPool: Address;
  ccipAdmin: Address;
  ccipBridgedFrankencoin: Address;
  ccipBridgedGovernance: Address;
  ccipBridgedSavings: Address;
  ccipRouter: Address;
};

export type ChainAddressArbitrum = {
  // identifier
  chainId: typeof arbitrum.id;
  chainSelector: string;

  // standard bridges
  bridgeArbitrumFrankencoin: Address;

  // ccip cross chain support
  ccipTokenPool: Address;
  ccipAdmin: Address;
  ccipBridgedFrankencoin: Address;
  ccipBridgedGovernance: Address;
  ccipBridgedSavings: Address;
  ccipRouter: Address;
};

export type ChainAddressOptimism = {
  // identifier
  chainId: typeof optimism.id;
  chainSelector: string;

  // standard bridges
  bridgeOptimismFrankencoin: Address;

  // ccip cross chain support
  ccipTokenPool: Address;
  ccipAdmin: Address;
  ccipBridgedFrankencoin: Address;
  ccipBridgedGovernance: Address;
  ccipBridgedSavings: Address;
  ccipRouter: Address;
};

export type ChainAddressBase = {
  // identifier
  chainId: typeof base.id;
  chainSelector: string;

  // ccip cross chain support
  ccipTokenPool: Address;
  ccipAdmin: Address;
  ccipBridgedFrankencoin: Address;
  ccipBridgedGovernance: Address;
  ccipBridgedSavings: Address;
  ccipRouter: Address;
};

export type ChainAddressAvalanche = {
  // identifier
  chainId: typeof avalanche.id;
  chainSelector: string;

  // ccip cross chain support
  ccipTokenPool: Address;
  ccipAdmin: Address;
  ccipBridgedFrankencoin: Address;
  ccipBridgedGovernance: Address;
  ccipBridgedSavings: Address;
  ccipRouter: Address;
};

export type ChainAddressGnosis = {
  // identifier
  chainId: typeof gnosis.id;
  chainSelector: string;

  // ccip cross chain support
  ccipTokenPool: Address;
  ccipAdmin: Address;
  ccipBridgedFrankencoin: Address;
  ccipBridgedGovernance: Address;
  ccipBridgedSavings: Address;
  ccipRouter: Address;
};

export type ChainAddressSonic = {
  // identifier
  chainId: typeof sonic.id;
  chainSelector: string;

  // ccip cross chain support
  ccipTokenPool: Address;
  ccipAdmin: Address;
  ccipBridgedFrankencoin: Address;
  ccipBridgedGovernance: Address;
  ccipBridgedSavings: Address;
  ccipRouter: Address;
};

export type ChainAddressMap = {
  [mainnet.id]: ChainAddressMainnet;
  [polygon.id]: ChainAddressPolygon;
  [arbitrum.id]: ChainAddressArbitrum;
  [optimism.id]: ChainAddressOptimism;
  [base.id]: ChainAddressBase;
  [avalanche.id]: ChainAddressAvalanche;
  [gnosis.id]: ChainAddressGnosis;
  [sonic.id]: ChainAddressSonic;
};
