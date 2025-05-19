import { arbitrum, mainnet, optimism, polygon } from "viem/chains";
import { Address, zeroAddress } from "viem";

export interface ChainAddress {
  [mainnet.id]: {
    // core
    frankencoin: Address; // ZCHF token
    equity: Address; // FPS token

    // utils
    wFPS: Address; // wrapped FPS
    referenceTransfer: Address;
    savingsDetached: Address;

    // minting hub v1
    mintingHubV1: Address;
    positionFactoryV1: Address;

    // minting hub v2 + utils v2
    savings: Address;
    roller: Address;
    mintingHubV2: Address;
    positionFactoryV2: Address;

    // stablecoin swap bridges
    stablecoinBridgeXCHF: Address;
    xchf: Address;
    stablecoinBridgeVCHF: Address;
    vchf: Address;
  };
  [polygon.id]: {
    bridgePolygonFrankencoin: Address;
    bridgePolygonWfps: Address;
  };
  [arbitrum.id]: {
    bridgeArbitrumFrankencoin: Address;
  };
  [optimism.id]: {
    bridgeOptimismFrankencoin: Address;
  };
}

export const ADDRESS: ChainAddress = {
  [mainnet.id]: {
    // core
    frankencoin: "0xB58E61C3098d85632Df34EecfB899A1Ed80921cB",
    equity: "0x1bA26788dfDe592fec8bcB0Eaff472a42BE341B2",

    // utils
    wFPS: "0x5052D3Cc819f53116641e89b96Ff4cD1EE80B182",
    referenceTransfer: "0x6A9ffB6727dfd8811B7e67a578e2E576f779ab7e",
    savingsDetached: zeroAddress,

    // minting hub v1
    mintingHubV1: "0x7546762fdb1a6d9146b33960545C3f6394265219",
    positionFactoryV1: "0x0CDE500e6940931ED190ded77bb48640c9486392",

    // minting hub v2 + utils v2
    savings: "0x3BF301B0e2003E75A3e86AB82bD1EFF6A9dFB2aE",
    roller: "0xAD0107D3Da540Fd54b1931735b65110C909ea6B6",
    mintingHubV2: "0xDe12B620A8a714476A97EfD14E6F7180Ca653557",
    positionFactoryV2: "0x728310FeaCa72dc46cD5BF7d739556D5668472BA",

    // stablecoin swap bridges
    stablecoinBridgeXCHF: "0x7bbe8F18040aF0032f4C2435E7a76db6F1E346DF",
    xchf: "0xb4272071ecadd69d933adcd19ca99fe80664fc08",
    stablecoinBridgeVCHF: "0x3b71ba73299f925a837836160c3e1fec74340403",
    vchf: "0x79d4f0232A66c4c91b89c76362016A1707CFBF4f",
  },
  [polygon.id]: {
    bridgePolygonFrankencoin: "0x02567e4b14b25549331fCEe2B56c647A8bAB16FD",
    bridgePolygonWfps: "0x54Cc50D5CC4914F0c5DA8b0581938dC590d29b3D",
  },
  [arbitrum.id]: {
    bridgeArbitrumFrankencoin: "0xB33c4255938de7A6ec1200d397B2b2F329397F9B",
  },
  [optimism.id]: {
    bridgeOptimismFrankencoin: "0x4F8a84C442F9675610c680990EdDb2CCDDB8aB6f",
  },
};
