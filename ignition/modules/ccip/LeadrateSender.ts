import { getChildFromSeed } from "../../../helper/wallet";
import { ADDRESS } from "../../../exports/address.mainnet.config";
import { ChainAddressMap } from "../../../exports/address.mainnet.types";
import { buildModule } from "@nomicfoundation/ignition-core";
import { Address } from "viem";
import { storeConstructorArgs } from "../../../helper/store.args";

const seed = process.env.DEPLOYER_SEED;
if (!seed) throw new Error("Failed to import the seed string from .env");

const w0 = getChildFromSeed(seed, 0); // deployer

// frankencoin addresses
const id = parseInt(process.env?.CHAINID || "1");
const ADDR = ADDRESS[Number(id)] as ChainAddressMap["1"];

export const config = {
  deployer: w0.address,
  ecosystem: ADDR,
};

console.log("Config Info");
console.log(config);

export const NAME: string = "LeadrateSender"; // <-- select smart contract
export const FILE: string = "LeadrateSender"; // <-- name exported file
export const MOD: string = NAME + "Module";
console.log(NAME);

// params
export type DeploymentParams = {
  leadrate: Address;
  router: Address;
  linkToken: Address;
};

export const params: DeploymentParams = {
  leadrate: ADDR.savingsReferral,
  router: ADDR.ccipRouter,
  linkToken: ADDR.linkToken,
};

export type ConstructorArgs = [Address, Address, Address];

export const args: ConstructorArgs = [
  params.leadrate,
  params.router,
  params.linkToken,
];

console.log("Imported Params:");
console.log(params);

// export args
storeConstructorArgs(FILE, args);
console.log("Constructor Args");
console.log(args);

export default buildModule("LeadrateSender", (m) => {
  return {
    [NAME]: m.contract(NAME, args),
  };
});
