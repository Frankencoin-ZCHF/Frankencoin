import { Address } from "viem";

export type DeploymentParams = {
  zchf: Address;
  savings: Address;
};

export const params: DeploymentParams = {
  zchf: "0xB58E61C3098d85632Df34EecfB899A1Ed80921cB",
  savings: "0x3BF301B0e2003E75A3e86AB82bD1EFF6A9dFB2aE",
};

export type ConstructorArgs = [Address, Address];

export const args: ConstructorArgs = [params.zchf, params.savings];
