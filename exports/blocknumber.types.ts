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

// Deploy block per contract, per chain — for indexers (e.g. Ponder) to use as `startBlock`.
// Read from the ignition deployment journals (ignition/deployments/chain-*/journal.jsonl).

export type ChainBlockNumberMainnet = {
  // identifier
  chainId: typeof mainnet.id;

  // core
  frankencoin: number;
  mintingHubV1: number;
  mintingHubV2: number;
  transferReference: number;
  savingsReferral: number;
  uniswapPoolV3ZCHFUSDT: number;

  // ccip — ccipAdmin and ccipBridgeAccounting share a deploy tx
  ccipAdmin: number;
  ccipBridgeAccounting: number;

  // FCS
  // FCS's constructor deploys mainnetVotes/interestGovernance/minterGovernance/ccipGovernance
  // in the same transaction, so they share fcs' block.
  governanceFactory: number;
  fcs: number;
  mainnetVotes: number;
  interestGovernance: number;
  minterGovernance: number;
  ccipGovernance: number;

  // amplifier (mainnet + optimism only)
  uniswapAmplifier: number;
};

export type ChainBlockNumberSide = {
  // identifier
  chainId:
    | typeof polygon.id
    | typeof arbitrum.id
    | typeof optimism.id
    | typeof base.id
    | typeof avalanche.id
    | typeof gnosis.id
    | typeof sonic.id;

  // core
  ccipBridgedFrankencoin: number;
  ccipBridgedSavings: number;

  // FCS
  // minterGovernance/ccipGovernance/bridgedVotes are created inside the
  // GovernanceFactory.deploy(fcsmainnet) transaction, not the GovernanceFactory deployment itself.
  governanceFactory: number;
  minterGovernance: number;
  ccipGovernance: number;
  bridgedVotes: number;

  // amplifier — optimism only, the sole L2 deployment
  uniswapAmplifier?: number;
};

export type ChainBlockNumberMap = {
  [mainnet.id]: ChainBlockNumberMainnet;
  [polygon.id]: ChainBlockNumberSide;
  [arbitrum.id]: ChainBlockNumberSide;
  [optimism.id]: ChainBlockNumberSide;
  [base.id]: ChainBlockNumberSide;
  [avalanche.id]: ChainBlockNumberSide;
  [gnosis.id]: ChainBlockNumberSide;
  [sonic.id]: ChainBlockNumberSide;
};
