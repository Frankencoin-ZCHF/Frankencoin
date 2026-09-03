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
import { ChainBlockNumberMap } from "./blocknumber.types";

export const BLOCKNUMBER: ChainBlockNumberMap = {
  [mainnet.id]: {
    chainId: mainnet.id,

    // FCS
    governanceFactory: 25852496,
    fcs: 25852506,
    mainnetVotes: 25852506,
    interestGovernance: 25852506,
    minterGovernance: 25852506,
    ccipGovernance: 25852506,
  },
  [polygon.id]: {
    chainId: polygon.id,

    // FCS
    governanceFactory: 92807409,
    minterGovernance: 92807414,
    ccipGovernance: 92807414,
    bridgedVotes: 92807414,
  },
  [arbitrum.id]: {
    chainId: arbitrum.id,

    // FCS
    governanceFactory: 499275369,
    minterGovernance: 499275377,
    ccipGovernance: 499275377,
    bridgedVotes: 499275377,
  },
  [optimism.id]: {
    chainId: optimism.id,

    // FCS
    governanceFactory: 156162576,
    minterGovernance: 156162581,
    ccipGovernance: 156162581,
    bridgedVotes: 156162581,
  },
  [base.id]: {
    chainId: base.id,

    // FCS
    governanceFactory: 50558420,
    minterGovernance: 50558425,
    ccipGovernance: 50558425,
    bridgedVotes: 50558425,
  },
  [avalanche.id]: {
    chainId: avalanche.id,

    // FCS
    governanceFactory: 93888077,
    minterGovernance: 93888083,
    ccipGovernance: 93888083,
    bridgedVotes: 93888083,
  },
  [gnosis.id]: {
    chainId: gnosis.id,

    // FCS
    governanceFactory: 47958829,
    minterGovernance: 47958834,
    ccipGovernance: 47958834,
    bridgedVotes: 47958834,
  },
  [sonic.id]: {
    chainId: sonic.id,

    // FCS
    governanceFactory: 78327140,
    minterGovernance: 78327147,
    ccipGovernance: 78327147,
    bridgedVotes: 78327147,
  },
} as const;
