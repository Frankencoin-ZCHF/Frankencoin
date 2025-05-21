import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import { storeConstructorArgs } from "../../../helper/store.args";
import { ADDRESS } from "../../../exports/address.mainnet.config";
import { Address } from "viem";
import { mainnet } from "viem/chains";

// config and select
export const NAME: string = "ReferenceTransfer"; // <-- select smart contract
export const FILE: string = "ReferenceTransfer"; // <-- name exported file
export const MOD: string = NAME + "Module";
console.log(NAME);

// params
export type DeploymentParams = {
  zchf: Address;
};

export const params: DeploymentParams = {
  zchf: ADDRESS[mainnet.id].frankencoin,
};

export type ConstructorArgs = [Address];

export const args: ConstructorArgs = [params.zchf];

console.log("Imported Params:");
console.log(params);

// export args
storeConstructorArgs(FILE, args);
console.log("Constructor Args");
console.log(args);

// fail safe
process.exit();

export default buildModule(MOD, (m) => {
  return {
    [NAME]: m.contract(NAME, args),
  };
});
