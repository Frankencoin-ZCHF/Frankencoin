import { Address } from "viem";

export type DeploymentParams = {
  zchf: Address;
};

export const params: DeploymentParams = {
  zchf: "0x89C31867c878E4268C65de3CDf8Ea201310c5851", // <-- this is testnet polygon
};

export type ConstructorArgs = [Address];

export const args: ConstructorArgs = [params.zchf];
