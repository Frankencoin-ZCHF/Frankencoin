import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import { storeConstructorArgs } from "../../../helper/store.args";
import { ADDRESS } from "../../../exports/address.config";
import { mainnet } from "viem/chains";
import { Address } from "viem";

// config and select
export const NAME: string = "CloneHelper"; // <-- select smart contract
export const FILE: string = "CloneHelperV2"; // <-- name exported file
export const MOD: string = NAME + "Module";
console.log(NAME);

// params
export type DeploymentParams = {
  hubV2: Address;
};

export const params: DeploymentParams = {
  hubV2: ADDRESS[mainnet.id].mintingHubV2,
};

export type ConstructorArgs = [Address];

export const args: ConstructorArgs = [params.hubV2];

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
