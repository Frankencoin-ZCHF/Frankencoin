import { buildModule } from "@nomicfoundation/ignition-core";
import { storeConstructorArgs } from "../../../helper/store.args";
import { getChildFromSeed } from "../../../helper/wallet";
import { ADDRESS } from "../../../exports/address.config";

const seed = process.env.DEPLOYER_SEED;
if (!seed) throw new Error("Failed to import the seed string from .env");

const w0 = getChildFromSeed(seed, 0); // deployer

// frankencoin addresses
const ADDR = ADDRESS[1];

export const config = {
  deployer: w0.address,
  ecosystem: ADDR,
};

export default buildModule("FCS", (m) => {
  const mainnetFCS = ADDRESS[1].fcs;
  if (!mainnetFCS) {
    throw new Error("Missing required addresses for FCS deployment");
  }

  const governanceFactory = m.contract("GovernanceFactory");
  m.call(governanceFactory, "deploy", [mainnetFCS])
  storeConstructorArgs("GovernanceFactory", [], true);
  return {
    governanceFactory,
  };
});
