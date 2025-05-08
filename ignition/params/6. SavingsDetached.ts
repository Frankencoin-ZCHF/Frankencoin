import { Address } from "viem";

export type DeploymentParams = {
  zchf: Address;
  rate: number;
};

export const params: DeploymentParams = {
  zchf: "0xB58E61C3098d85632Df34EecfB899A1Ed80921cB",
  rate: 30_000, // 3% in ppm
};

export type ConstructorArgs = [Address, number];

export const args: ConstructorArgs = [params.zchf, params.rate];
