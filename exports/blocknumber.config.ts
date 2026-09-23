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

    // core
    frankencoin: 18451518,
    mintingHubV1: 18451536,
    mintingHubV2: 21280757,
    transferReference: 22678761,
    savingsReferral: 22536327,
    uniswapPoolV3ZCHFUSDT: 19122801,

    // ccip
    ccipAdmin: 22623055,
    ccipBridgeAccounting: 22623055,

    // FCS
    governanceFactory: 25852496,
    fcs: 25852506,
    mainnetVotes: 25852506,
    interestGovernance: 25852506,
    minterGovernance: 25852506,
    ccipGovernance: 25852506,

    // amplifier
    uniswapAmplifier: 25795552,
  },
  [polygon.id]: {
    chainId: polygon.id,

    // core
    ccipBridgedFrankencoin: 72384538,
    ccipBridgedSavings: 72993144,

    // FCS
    governanceFactory: 92807409,
    minterGovernance: 92807414,
    ccipGovernance: 92807414,
    bridgedVotes: 92807414,
  },
  [arbitrum.id]: {
    chainId: arbitrum.id,

    // core
    ccipBridgedFrankencoin: 343470012,
    ccipBridgedSavings: 349273896,

    // FCS
    governanceFactory: 499275369,
    minterGovernance: 499275377,
    ccipGovernance: 499275377,
    bridgedVotes: 499275377,
  },
  [optimism.id]: {
    chainId: optimism.id,

    // core
    ccipBridgedFrankencoin: 136678320,
    ccipBridgedSavings: 137404676,

    // FCS
    governanceFactory: 156162576,
    minterGovernance: 156162581,
    ccipGovernance: 156162581,
    bridgedVotes: 156162581,

    // amplifier
    uniswapAmplifier: 155811236,
  },
  [base.id]: {
    chainId: base.id,

    // core
    ccipBridgedFrankencoin: 31080190,
    ccipBridgedSavings: 31809565,

    // FCS
    governanceFactory: 50558420,
    minterGovernance: 50558425,
    ccipGovernance: 50558425,
    bridgedVotes: 50558425,
  },
  [avalanche.id]: {
    chainId: avalanche.id,

    // core
    ccipBridgedFrankencoin: 63337938,
    ccipBridgedSavings: 64919925,

    // FCS
    governanceFactory: 93888077,
    minterGovernance: 93888083,
    ccipGovernance: 93888083,
    bridgedVotes: 93888083,
  },
  [gnosis.id]: {
    chainId: gnosis.id,

    // core
    ccipBridgedFrankencoin: 40394536,
    ccipBridgedSavings: 40678291,

    // FCS
    governanceFactory: 47958829,
    minterGovernance: 47958834,
    ccipGovernance: 47958834,
    bridgedVotes: 47958834,
  },
  [sonic.id]: {
    chainId: sonic.id,

    // core
    ccipBridgedFrankencoin: 31589491,
    ccipBridgedSavings: 34961851,

    // FCS
    governanceFactory: 78327140,
    minterGovernance: 78327147,
    ccipGovernance: 78327147,
    bridgedVotes: 78327147,
  },
} as const;
