import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import { storeConstructorArgs } from "../../../helper/store.args";
import { ADDRESS } from "../../../exports/address.mainnet.config";
import { mainnet } from "viem/chains";
import { Address } from "viem";

// config and select
export const NAME: string = "Savings"; // <-- select smart contract
export const FILE: string = "SavingsCross"; // <-- name exported file
export const MOD: string = NAME + "Module";
console.log(NAME);

// params
export type DeploymentParams = {
  zchf: Address;
  rate: number;
};

export const params: DeploymentParams = {
  zchf: ADDRESS[mainnet.id].frankencoin,
  rate: 30_000, // 3% in ppm
};

export type ConstructorArgs = [Address, number];

export const args: ConstructorArgs = [params.zchf, params.rate];

console.log("Imported Params:");
console.log(params);

// export args
storeConstructorArgs(FILE, args);
console.log("Constructor Args");
console.log(args);

// fail safe
process.exit();

// deploy module
export default buildModule(MOD, (m) => {
  return {
    [NAME]: m.contract(NAME, args),
  };
});
