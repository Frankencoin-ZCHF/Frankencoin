import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import { storeConstructorArgs } from "../../../helper/store.args";
import { ADDRESS } from "../../../exports/address.mainnet.config";
import { Address } from "viem";
import { mainnet } from "viem/chains";

// config and select
export const NAME: string = "TransferReference"; // <-- select smart contract
export const FILE: string = "TransferReference"; // <-- name exported file
export const MOD: string = NAME + "Module";
console.log(NAME);

// params
export type DeploymentParams = {
  token: Address;
  router: Address;
  link: Address;
};

export const params: DeploymentParams = {
  token: ADDRESS[mainnet.id].frankencoin,
  router: ADDRESS[mainnet.id].ccipRouter,
  link: ADDRESS[mainnet.id].linkToken,
};

export type ConstructorArgs = [Address, Address, Address];

export const args: ConstructorArgs = [params.token, params.router, params.link];

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
