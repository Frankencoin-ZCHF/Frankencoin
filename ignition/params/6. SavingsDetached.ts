import { Address } from "viem";

export type DeploymentParams = {
  zchf: Address;
  rate: number;
};

export const params: DeploymentParams = {
  zchf: "0x89C31867c878E4268C65de3CDf8Ea201310c5851",
  rate: 30_000, // 3% in ppm
};

export type ConstructorArgs = [Address, number];

export const args: ConstructorArgs = [params.zchf, params.rate];
