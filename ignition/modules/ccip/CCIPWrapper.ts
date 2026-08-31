// import { getChildFromSeed } from "../../../helper/wallet";
import { ADDRESS } from "../../../exports/address.config";
import { buildModule } from "@nomicfoundation/ignition-core";
import { Address } from "viem";
import { optimism } from "viem/chains";
import { storeConstructorArgs } from "../../../helper/store.args";
import { Wallet } from "ethers";

// const seed = process.env.DEPLOYER_SEED;
// if (!seed) throw new Error("Failed to import the seed string from .env");
// const deployer = getChildFromSeed(seed, 0);

const privateKey = process.env.PRIVATE_KEY;
if (!privateKey) throw new Error("Missing PRIVATE_KEY in .env");
const deployer = new Wallet(privateKey);

// Optimism only — the only side chain with an ERC4626 svZCHF vault deployed so far
const ADDR = ADDRESS[optimism.id];

export const config = {
  deployer: deployer.address,
  ecosystem: ADDR,
};

console.log("Config Info");
console.log(config);

export const NAME: string = "CCIPWrapper"; // <-- select smart contract
export const FILE: string = "CCIPWrapper"; // <-- name exported file
export const MOD: string = NAME + "Module";
console.log(NAME);

// params
export type DeploymentParams = {
  svZCHF: Address;
  zCHF: Address;
  router: Address;
};

export const params: DeploymentParams = {
  svZCHF: ADDR.svZCHF,
  zCHF: ADDR.ccipBridgedFrankencoin,
  router: ADDR.ccipRouter,
};

export type ConstructorArgs = [Address, Address, Address];

export const args: ConstructorArgs = [
  params.svZCHF,
  params.zCHF,
  params.router,
];

console.log("Imported Params:");
console.log(params);

// export args
storeConstructorArgs(FILE, args);
console.log("Constructor Args");
console.log(args);

export default buildModule("CCIPWrapper", (m) => {
  return {
    [NAME]: m.contract(NAME, args),
  };
});
