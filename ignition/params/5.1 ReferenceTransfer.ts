import { Address } from "viem";

export type DeploymentParams = {
  zchf: Address;
};

export const params: DeploymentParams = {
  zchf: "0xB58E61C3098d85632Df34EecfB899A1Ed80921cB",
};

export type ConstructorArgs = [Address];

export const args: ConstructorArgs = [params.zchf];
