import { getChildFromSeed } from "../../../helper/wallet";
import { ADDRESS } from "../../../exports/address.mainnet.config";
import { ChainIdSide } from "../../../exports/address.mainnet.types";
import { buildModule } from "@nomicfoundation/ignition-core";
import { Address } from "viem";
import { mainnet } from "viem/chains";
import { storeConstructorArgs } from "../../../helper/store.args";

const seed = process.env.DEPLOYER_SEED;
if (!seed) throw new Error("Failed to import the seed string from .env");

const w0 = getChildFromSeed(seed, 0); // deployer

// frankencoin addresses
const id = parseInt(process.env?.CHAINID || "137");
const ADDR = ADDRESS[Number(id) as ChainIdSide];

const MAINNET_ADDR = ADDRESS[mainnet.id];

export const config = {
  deployer: w0.address,
  ecosystem: ADDR,
};

console.log("Config Info");
console.log(config);

export const NAME: string = "BridgedSavings"; // <-- select smart contract
export const FILE: string = "BridgedSavings"; // <-- name exported file
export const MOD: string = NAME + "Module";
console.log(NAME);

// params
export type DeploymentParams = {
  zchf: Address;
  router: Address;
  rate: number;
  mainnetChainSelector: string;
  leadrateSender: Address;
};

export const params: DeploymentParams = {
  zchf: ADDR.ccipBridgedFrankencoin,
  router: ADDR.ccipRouter,
  rate: 30_000,
  mainnetChainSelector: MAINNET_ADDR.chainSelector,
  leadrateSender: MAINNET_ADDR.ccipLeadrateSender,
};

export type ConstructorArgs = [Address, Address, number, string, Address];

export const args: ConstructorArgs = [
  params.zchf,
  params.router,
  params.rate,
  params.mainnetChainSelector,
  params.leadrateSender,
];

console.log("Imported Params:");
console.log(params);

// export args
storeConstructorArgs(FILE, args);
console.log("Constructor Args");
console.log(args);

export default buildModule("BridgedSavings", (m) => {
  return {
    [NAME]: m.contract(NAME, args),
  };
});
