import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import { getChildFromSeed } from "../../../helper/wallet";
import { ADDRESS, ChainAddress } from "../../../exports/address.mainnet.config";
import { Chain } from "viem";
import {
  arbitrum,
  avalanche,
  base,
  gnosis,
  optimism,
  polygon,
  polygonAmoy,
  sonic,
} from "viem/chains";
import { ethers } from "ethers";

const seed = process.env.DEPLOYER_SEED;
if (!seed) throw new Error("Failed to import the seed string from .env");

const w0 = getChildFromSeed(seed, 0); // deployer

// frankencoin addresses
const id = parseInt(process.env?.CHAINID || "1");
const ADDR = ADDRESS[Number(id)] as ChainAddress["1"];

export const config = {
  deployer: w0.address,
  ecosystem: ADDR,
};

console.log("Config Info");
console.log(config);

let chainUpdates: any[] = [];
if (id === 1) {
  chainUpdates = [
    getChainUpdate(polygon.id),
    getChainUpdate(arbitrum.id),
    getChainUpdate(optimism.id),
    getChainUpdate(base.id),
    getChainUpdate(avalanche.id),
    getChainUpdate(gnosis.id),
    getChainUpdate(sonic.id),
  ];
} else {
  chainUpdates = [getChainUpdate(polygonAmoy.id)];
}
chainUpdates = chainUpdates.filter((x) => x !== undefined);

console.log("Chain Updates");
console.log(chainUpdates);

const CCIPFinalizeModule = buildModule("CCIPFinalize", (m) => {
  const ccipAdmin = m.contractAt("CCIPAdmin", ADDR.ccipAdmin);
  m.call(ccipAdmin, "acceptAdmin", [ADDR.ccipTokenPool, chainUpdates]);

  return {};
});

function getChainUpdate(chainId: Chain["id"]) {
  const ADDR = ADDRESS[chainId];
  if (
    ADDR &&
    ADDR.ccipBridgedFrankencoin &&
    ADDR.chainSelector &&
    ADDR.ccipTokenPool
  ) {
    const abiCoder = ethers.AbiCoder.defaultAbiCoder();
    return {
      remoteChainSelector: ADDR.chainSelector,
      remotePoolAddresses: [abiCoder.encode(["address"], [ADDR.ccipTokenPool])],
      remoteTokenAddress: abiCoder.encode(["address"], [ADDR.ccipBridgedFrankencoin]),
      outboundRateLimiterConfig: {
        isEnabled: false,
        capacity: 0,
        rate: 0,
      },
      inboundRateLimiterConfig: {
        isEnabled: false,
        capacity: 0,
        rate: 0,
      },
    };
  }
  return undefined;
}

export default CCIPFinalizeModule;
