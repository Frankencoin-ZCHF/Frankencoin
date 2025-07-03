import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import { getChildFromSeed } from "../../../helper/wallet";
import { storeConstructorArgs } from "../../../helper/store.args";
import { ADDRESS } from "../../../exports/address.mainnet.config";
import { mainnet } from "viem/chains";

// deployer settings
const seed = process.env.DEPLOYER_ACCOUNT_SEED;
if (!seed) throw new Error("Failed to import the seed string from .env");

const w0 = getChildFromSeed(seed, 0); // deployer

// frankencoin addresses
const ADDR = ADDRESS[mainnet.id];

export const config = {
  deployer: w0.address,
  chainId: mainnet.id,
};

console.log("Config Info");
console.log(config);

// constructor args
export const args = [ADDR.frankencoin, 50_000];
storeConstructorArgs("Savings", args, true);

console.log("Constructor Args");
console.log(args);

// buildModule
const SavingsModule = buildModule("SavingsModule", (m) => {
  const controller = m.contract("Savings", args);
  return { controller };
});

export default SavingsModule;
