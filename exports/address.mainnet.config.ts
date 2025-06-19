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
import { zeroAddress } from "viem";
import { ChainAddressMap } from "./address.mainnet.types";

export const ADDRESS: ChainAddressMap = {
  [mainnet.id]: {
    // identifier
    chainId: 1,
    chainSelector: "5009297550715157269",

    // core
    frankencoin: "0xB58E61C3098d85632Df34EecfB899A1Ed80921cB",
    equity: "0x1bA26788dfDe592fec8bcB0Eaff472a42BE341B2",

    // utils
    wFPS: "0x5052D3Cc819f53116641e89b96Ff4cD1EE80B182",

    // minting hub v1
    mintingHubV1: "0x7546762fdb1a6d9146b33960545C3f6394265219",
    positionFactoryV1: "0x0CDE500e6940931ED190ded77bb48640c9486392",

    // minting hub v2 + utils v2
    savingsV2: "0x3BF301B0e2003E75A3e86AB82bD1EFF6A9dFB2aE",
    rollerV2: "0xAD0107D3Da540Fd54b1931735b65110C909ea6B6",
    mintingHubV2: "0xDe12B620A8a714476A97EfD14E6F7180Ca653557",
    positionFactoryV2: "0x728310FeaCa72dc46cD5BF7d739556D5668472BA",

    // stablecoin swap bridges
    stablecoinBridgeXCHF: "0x7bbe8F18040aF0032f4C2435E7a76db6F1E346DF",
    xchfToken: "0xb4272071ecadd69d933adcd19ca99fe80664fc08",
    stablecoinBridgeVCHF: "0x3b71ba73299f925a837836160c3e1fec74340403",
    vchfToken: "0x79d4f0232A66c4c91b89c76362016A1707CFBF4f",

    // multi chain support
    transferReference: "0xf98c221661F51578f5E5236B189a493E2a8a1916",
    savingsReferral: "0x27d9AD987BdE08a0d083ef7e0e4043C857A17B38",
    ccipAdmin: "0x2527ec458c863073a303CF0a362Bf78aDD5dFEf8",
    ccipTokenPool: "0x9359cd75549DaE00Cdd8D22297BC9B13FbBe4B79",
    ccipBridgeAccounting: "0x88fd2ECD0B9250F203e99E80eb78b0C32B8AdB16",
    ccipGovernanceSender: "0xFD23272DfcB13Dc3Fabd8DB851fCD4827Af876EB",
    ccipLeadrateSender: zeroAddress,
    ccipTokenAdminRegistry: "0xb22764f98dD05c789929716D677382Df22C05Cb6",
    ccipRmnProxy: "0x411dE17f12D1A34ecC7F45f49844626267c75e81",
    ccipRouter: "0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D",
    linkToken: "0x514910771AF9Ca656af840dff83E8264EcF986CA",
  },
  [polygon.id]: {
    // identifier
    chainId: 137,
    chainSelector: "4051577828743386545",

    // bridge
    bridgePolygonFrankencoin: "0x02567e4b14b25549331fCEe2B56c647A8bAB16FD",
    bridgePolygonWfps: "0x54Cc50D5CC4914F0c5DA8b0581938dC590d29b3D",

    // ccip
    ccipTokenPool: "0x7CBac118B3F299f8BE1C3DBA66368D96B37D7743",
    ccipAdmin: "0xdE4cB79A62fd4036Cadf6D71D23240dc4d7a484E",
    ccipBridgedFrankencoin: "0xD4dD9e2F021BB459D5A5f6c24C12fE09c5D45553",
    ccipBridgedGovernance: "0x4fF458f3Aa2c5cd970891909d72CF029939313ab",
    ccipRouter: "0x849c5ED5a80F5B408Dd4969b78c2C8fdf0565Bfe",
  },
  [arbitrum.id]: {
    // identifier
    chainId: 42161,
    chainSelector: "4949039107694359620",

    // bridge
    bridgeArbitrumFrankencoin: "0xB33c4255938de7A6ec1200d397B2b2F329397F9B",

    // ccip
    ccipTokenPool: "0x7CBac118B3F299f8BE1C3DBA66368D96B37D7743",
    ccipAdmin: "0xdE4cB79A62fd4036Cadf6D71D23240dc4d7a484E",
    ccipBridgedFrankencoin: "0xD4dD9e2F021BB459D5A5f6c24C12fE09c5D45553",
    ccipBridgedGovernance: "0x4fF458f3Aa2c5cd970891909d72CF029939313ab",
    ccipRouter: "0x141fa059441E0ca23ce184B6A78bafD2A517DdE8",
  },
  [optimism.id]: {
    // identifier
    chainId: 10,
    chainSelector: "3734403246176062136",

    // bridge
    bridgeOptimismFrankencoin: "0x4F8a84C442F9675610c680990EdDb2CCDDB8aB6f",

    // ccip
    ccipTokenPool: "0x7CBac118B3F299f8BE1C3DBA66368D96B37D7743",
    ccipAdmin: "0xdE4cB79A62fd4036Cadf6D71D23240dc4d7a484E",
    ccipBridgedFrankencoin: "0xD4dD9e2F021BB459D5A5f6c24C12fE09c5D45553",
    ccipBridgedGovernance: "0x4fF458f3Aa2c5cd970891909d72CF029939313ab",
    ccipRouter: "0x3206695CaE29952f4b0c22a169725a865bc8Ce0f",
  },
  [base.id]: {
    // identifier
    chainId: 8453,
    chainSelector: "15971525489660198786",

    // ccip
    ccipTokenPool: "0x7CBac118B3F299f8BE1C3DBA66368D96B37D7743",
    ccipAdmin: "0xdE4cB79A62fd4036Cadf6D71D23240dc4d7a484E",
    ccipBridgedFrankencoin: "0xD4dD9e2F021BB459D5A5f6c24C12fE09c5D45553",
    ccipBridgedGovernance: "0x4fF458f3Aa2c5cd970891909d72CF029939313ab",
    ccipRouter: "0x881e3A65B4d4a04dD529061dd0071cf975F58bCD",
  },
  [avalanche.id]: {
    // identifier
    chainId: 43114,
    chainSelector: "6433500567565415381",

    // ccip
    ccipTokenPool: "0x7CBac118B3F299f8BE1C3DBA66368D96B37D7743",
    ccipAdmin: "0xdE4cB79A62fd4036Cadf6D71D23240dc4d7a484E",
    ccipBridgedFrankencoin: "0xD4dD9e2F021BB459D5A5f6c24C12fE09c5D45553",
    ccipBridgedGovernance: "0x4fF458f3Aa2c5cd970891909d72CF029939313ab",
    ccipRouter: "0xF4c7E640EdA248ef95972845a62bdC74237805dB",
  },
  [gnosis.id]: {
    // identifier
    chainId: 100,
    chainSelector: "465200170687744372",

    // ccip
    ccipTokenPool: "0x7CBac118B3F299f8BE1C3DBA66368D96B37D7743",
    ccipAdmin: "0xdE4cB79A62fd4036Cadf6D71D23240dc4d7a484E",
    ccipBridgedFrankencoin: "0xD4dD9e2F021BB459D5A5f6c24C12fE09c5D45553",
    ccipBridgedGovernance: "0x4fF458f3Aa2c5cd970891909d72CF029939313ab",
    ccipRouter: "0x4aAD6071085df840abD9Baf1697d5D5992bDadce",
  },
  [sonic.id]: {
    // identifier
    chainId: 146,
    chainSelector: "1673871237479749969",

    // ccip
    ccipTokenPool: "0x7CBac118B3F299f8BE1C3DBA66368D96B37D7743",
    ccipAdmin: "0xdE4cB79A62fd4036Cadf6D71D23240dc4d7a484E",
    ccipBridgedFrankencoin: "0xD4dD9e2F021BB459D5A5f6c24C12fE09c5D45553",
    ccipBridgedGovernance: "0x4fF458f3Aa2c5cd970891909d72CF029939313ab",
    ccipRouter: "0xB4e1Ff7882474BB93042be9AD5E1fA387949B860",
  },
} as const;
