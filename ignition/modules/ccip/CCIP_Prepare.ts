import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import { getChildFromSeed } from "../../../helper/wallet";
import { storeConstructorArgs } from "../../../helper/store.args";
import { ADDRESS, ChainAddress } from "../../../exports/address.mainnet.config";

const seed = process.env.DEPLOYER_SEED;
if (!seed) throw new Error("Failed to import the seed string from .env");

const w0 = getChildFromSeed(seed, 0); // deployer

// frankencoin addresses
const id = process.env?.CHAINID || 1;
const ADDR = ADDRESS[Number(id)] as ChainAddress["1"];

export const config = {
  deployer: w0.address,
  ecosystem: ADDR,
};

console.log("Config Info");
console.log(config);

// ccip admin constructor args
export const ccipAdminArgs = [ADDR.ccipTokenAdminRegistry, ADDR.frankencoin];
storeConstructorArgs("CCIPAdmin", ccipAdminArgs, true);

console.log("CCIPAdmin Constructor Args");
console.log(ccipAdminArgs);

// token pool constructor args
export const tokenPoolArgs = [
  ADDR.frankencoin,
  18,
  [],
  ADDR.ccipRmnProxy,
  ADDR.ccipRouter,
];
storeConstructorArgs("BurnMintTokenPool", tokenPoolArgs, true);

console.log("BurnMintTokenPool Construcotr Args");
console.log(tokenPoolArgs);

// governance sender
export const governanceSenderArgs = [
  ADDR.equity,
  ADDR.ccipRouter,
  ADDR.linkToken,
];
storeConstructorArgs("GovernanceSender", governanceSenderArgs, true);
console.log("GovernanceSender Constructor Args");
console.log(governanceSenderArgs);

// leadrate sender
export const leadrateSenderArgs = [
  ADDR.savingsReferral,
  ADDR.ccipRouter,
  ADDR.linkToken,
];
storeConstructorArgs("LeadrateSender", leadrateSenderArgs, true);
console.log("LeadrateSender Constructor Args");
console.log(leadrateSenderArgs);

// bridge accounting
export const bridgeAccountArgs = [
  ADDR.frankencoin,
  ADDR.ccipTokenAdminRegistry,
  ADDR.ccipRouter,
];
storeConstructorArgs("BridgeAccounting", bridgeAccountArgs, true);
console.log("BridgeAccounting Constructor Args");
console.log(bridgeAccountArgs);

const CCIPPrepareModule = buildModule("CCIPPrepare", (m) => {
  const ccipAdmin = m.contract("CCIPAdmin", ccipAdminArgs);
  const tokenPool = m.contract("BurnMintTokenPool", tokenPoolArgs);
  m.call(tokenPool, "transferOwnership", [ccipAdmin]);

  const governanceSender = m.contract("GovernanceSender", governanceSenderArgs);
  const leadrateSender = m.contract("LeadrateSender", leadrateSenderArgs);
  const bridgeAccounting = m.contract("BridgeAccounting", bridgeAccountArgs);

  console.log("");
  console.log("NEXT STEPS:");
  console.log(
    `Ping the Chainlink team to propose CCIPAdmin as admin for ZCHF and then suggest the minters`
  );

  return {
    ccipAdmin,
    tokenPool,
    governanceSender,
    leadrateSender,
    bridgeAccounting,
  };
});

export default CCIPPrepareModule;
