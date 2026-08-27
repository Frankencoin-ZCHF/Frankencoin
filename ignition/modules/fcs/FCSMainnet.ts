import { buildModule } from "@nomicfoundation/ignition-core";
import { storeConstructorArgs } from "../../../helper/store.args";
import { getChildFromSeed } from "../../../helper/wallet";
import { ADDRESS } from "../../../exports/address.config";

const seed = process.env.DEPLOYER_SEED;
if (!seed) throw new Error("Failed to import the seed string from .env");

const w0 = getChildFromSeed(seed, 0); // deployer

// frankencoin addresses
const id = process.env?.CHAINID || 1;
const ADDR = ADDRESS[Number(id) as keyof typeof ADDRESS];

export const config = {
  deployer: w0.address,
  ecosystem: ADDR,
};

export default buildModule("FCS", (m) => {
  let zchf = "";
  if ("frankencoin" in ADDR) {
    zchf = ADDR.frankencoin;
  } else {
    zchf = ADDR.ccipBridgedFrankencoin;
  }
  let fps1Governance = "";
  if ("equity" in ADDR) {
    fps1Governance = ADDR.equity;
  } else {
    fps1Governance = ADDR.ccipBridgedGovernance;
  }

  if (!zchf || !fps1Governance) {
    throw new Error("Missing required addresses for FCS deployment");
  }

  const governanceFactory = m.contract("GovernanceFactory");
  const fcs = m.contract("FCS", [governanceFactory, fps1Governance, zchf]);

  const argsFile = storeConstructorArgs(
    "FCS",
    ["GovernanceFactoryAddress", fps1Governance, zchf],
    true
  );
  console.log(
    `UPDATE: FCS constructor args stored for deployment at ${argsFile} with GovernanceFactory address`
  );
  storeConstructorArgs("GovernanceFactory", [], true);
  return {
    fcs,
    governanceFactory,
  };
});
