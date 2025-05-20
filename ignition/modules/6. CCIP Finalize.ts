import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import { getChildFromSeed } from "../../helper/wallet";
import { ADDRESS } from "../../exports/address.config";
import { Chain } from "viem";
import { polygon, polygonAmoy } from "viem/chains";
import { ethers } from "ethers";

const seed = process.env.DEPLOYER_ACCOUNT_SEED;
if (!seed) throw new Error("Failed to import the seed string from .env");

const w0 = getChildFromSeed(seed, 0); // deployer

// frankencoin addresses
const id = process.env?.CHAINID || 1;
const ADDR = ADDRESS[id as Chain["id"]];

export const config = {
  deployer: w0.address,
  ecosystem: ADDR,
};

console.log("Config Info");
console.log(config);

let chainUpdates: any[] = [];
if (id === 1) {
  chainUpdates = [getChainUpdate(polygon.id)];
} else {
  chainUpdates = [getChainUpdate(polygonAmoy.id)];
}
chainUpdates = chainUpdates.filter((x) => x !== undefined);

console.log("Chain Updates");
console.log(chainUpdates);

const CCIPFinalizeModule = buildModule("CCIPFinalize", (m) => {
  const ccipAdmin = m.contractAt("CCIPAdmin", ADDR.ccipAdmin);
  m.call(ccipAdmin, "acceptAdmin", [ADDR.tokenPool, chainUpdates]);

  return {};
});

function getChainUpdate(chainId: Chain["id"]) {
  const ADDR = ADDRESS[chainId];
  if (ADDR && ADDR.frankenCoin && ADDR.chainSelector && ADDR.tokenPool) {
    const abiCoder = ethers.AbiCoder.defaultAbiCoder();
    return {
      remoteChainSelector: ADDR.chainSelector,
      remotePoolAddresses: [abiCoder.encode(["address"], [ADDR.tokenPool])],
      remoteTokenAddress: abiCoder.encode(["address"], [ADDR.frankenCoin]),
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
