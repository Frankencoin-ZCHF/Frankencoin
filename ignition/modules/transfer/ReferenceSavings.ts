import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import { storeConstructorArgs } from "../../../helper/store.args";
import { ADDRESS } from "../../../exports/address.mainnet.config";
import { Address } from "viem";
import { mainnet } from "viem/chains";

// config and select
export const NAME: string = "ReferenceTransfer"; // <-- select smart contract
export const FILE: string = "ReferenceSavings"; // <-- name exported file
export const MOD: string = NAME + "Module";
console.log(NAME);

// params
export type DeploymentParams = {
  zchf: Address;
  savings: Address;
};

export const params: DeploymentParams = {
  zchf: ADDRESS[mainnet.id].frankencoin,
  savings: ADDRESS[mainnet.id].savings,
};

export type ConstructorArgs = [Address, Address];

export const args: ConstructorArgs = [params.zchf, params.savings];

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
