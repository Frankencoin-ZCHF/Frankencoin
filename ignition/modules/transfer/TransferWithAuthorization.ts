import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import { storeConstructorArgs } from "../../../helper/store.args";
import { ADDRESS } from "../../../exports/address.config";
import { Address } from "viem";
import { base } from "viem/chains";

// config and select
export const NAME: string = "TransferWithAuthorization";
export const FILE: string = "TransferWithAuthorization";
export const MOD: string = NAME + "Module";
console.log(NAME);

// params
export type DeploymentParams = {
  zchf: Address;
};

export const params: DeploymentParams = {
  zchf: ADDRESS[base.id].ccipBridgedFrankencoin, // 0xD4dD9e2F021BB459D5A5f6c24C12fE09c5D45553
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
