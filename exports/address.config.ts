import { mainnet, polygon } from "viem/chains";
import { Address, zeroAddress } from "viem";

export interface ChainAddress {
  frankenCoin: Address;
  equity: Address;
  wFPS: Address;
  bridge: Address;
  xchf: Address;
  savings: Address;
  roller: Address;
  mintingHubV1: Address;
  positionFactoryV1: Address;
  mintingHubV2: Address;
  positionFactoryV2: Address;
  referenceTransfer: Address;

  bridgePolygonFrankencoin?: Address;
  bridgePolygonWfps?: Address;
  bridgeArbitrumFrankencoin?: Address;
  bridgeArbitrumWfps?: Address;
  bridgeOptimismFrankencoin?: Address;
  bridgeOptimismWfps?: Address;

  // accept any optional key
  // [key: string]: Address | undefined;
}

export const ADDRESS: Record<number, ChainAddress> = {
  [mainnet.id]: {
    // natice contract addresses
    frankenCoin: "0xB58E61C3098d85632Df34EecfB899A1Ed80921cB",
    equity: "0x1bA26788dfDe592fec8bcB0Eaff472a42BE341B2",
    wFPS: "0x5052D3Cc819f53116641e89b96Ff4cD1EE80B182",
    bridge: "0x7bbe8F18040aF0032f4C2435E7a76db6F1E346DF",
    xchf: "0xb4272071ecadd69d933adcd19ca99fe80664fc08",
    savings: "0x3BF301B0e2003E75A3e86AB82bD1EFF6A9dFB2aE",
    roller: "0xAD0107D3Da540Fd54b1931735b65110C909ea6B6",
    mintingHubV1: "0x7546762fdb1a6d9146b33960545C3f6394265219",
    positionFactoryV1: "0x0CDE500e6940931ED190ded77bb48640c9486392",
    mintingHubV2: "0xDe12B620A8a714476A97EfD14E6F7180Ca653557",
    positionFactoryV2: "0x728310FeaCa72dc46cD5BF7d739556D5668472BA",

    referenceTransfer: zeroAddress,

    // bridge contracts for ZCHF
    bridgePolygonFrankencoin: "0x02567e4b14b25549331fCEe2B56c647A8bAB16FD",
    bridgeArbitrumFrankencoin: "0xB33c4255938de7A6ec1200d397B2b2F329397F9B",
    bridgeOptimismFrankencoin: "0x4F8a84C442F9675610c680990EdDb2CCDDB8aB6f",

    // bridge contracts for WFPS
    bridgePolygonWfps: "0x54Cc50D5CC4914F0c5DA8b0581938dC590d29b3D",
    bridgeArbitrumWfps: zeroAddress,
    bridgeOptimismWfps: zeroAddress,
  },
  [polygon.id]: {
    // For test deployment only
    frankenCoin: "0x89C31867c878E4268C65de3CDf8Ea201310c5851",
    equity: "0x5e97Bb61440f3BbaB94Bbb61C41159B675175D49",
    wFPS: "0x47Cb2fF74F92d14184ABa028a744371aD07F3036",
    bridge: zeroAddress, // not used
    xchf: zeroAddress, // not used
    savings: "0xc50bF51ee9AaC98E2886ABD8c18876dA11D38709",
    roller: "0xA640dcc5a7050020A7b38D57bEe2C06a4301fb4E",
    mintingHubV1: "0x2357dc93cA35b4d761e6A1bbad070C2493A6ff7C",
    positionFactoryV1: "0x56Fa604fD5F96e456798F2dB50c88528A8a81F57",
    mintingHubV2: "0xf214ea93D12F425F71Fc28b5D15F38E700e2daeC",
    positionFactoryV2: "0x151E58D4dAA67EC33f4809491441791e48d1Fe56",

    referenceTransfer: "0x685fE606265465900bbeBA327eEc9223dAcfA424",
  },
};
