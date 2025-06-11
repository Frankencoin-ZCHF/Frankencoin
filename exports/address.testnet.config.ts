import { polygon } from "viem/chains";
import { Address } from "viem";

export interface ChainAddress {
  [polygon.id]: {
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
    savingsV2: Address;
    rollerV2: Address;
    mintingHubV2: Address;
    positionFactoryV2: Address;
  };
}

export const ADDRESS: ChainAddress = {
  [polygon.id]: {
    // core
    frankencoin: "0x89C31867c878E4268C65de3CDf8Ea201310c5851",
    equity: "0x5e97Bb61440f3BbaB94Bbb61C41159B675175D49",

    // utils
    wFPS: "0x47Cb2fF74F92d14184ABa028a744371aD07F3036",
    referenceTransfer: "0x378424e6f2c8bFdbE8548E110f49c04f4d11C190",
    savingsDetached: "0xCa1b5E0AC05Cfe141BC77153DeD7dCe1b69b8A29",

    // minting hub v1
    mintingHubV1: "0x2357dc93cA35b4d761e6A1bbad070C2493A6ff7C",
    positionFactoryV1: "0x56Fa604fD5F96e456798F2dB50c88528A8a81F57",

    // minting hub v2 + utils v2
    savingsV2: "0xc50bF51ee9AaC98E2886ABD8c18876dA11D38709",
    rollerV2: "0xA640dcc5a7050020A7b38D57bEe2C06a4301fb4E",
    mintingHubV2: "0xf214ea93D12F425F71Fc28b5D15F38E700e2daeC",
    positionFactoryV2: "0x151E58D4dAA67EC33f4809491441791e48d1Fe56",
  },
};
