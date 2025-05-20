import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import { getChildFromSeed } from "../../helper/wallet";
import { storeConstructorArgs } from "../../helper/store.args";
import { ADDRESS } from "../../exports/address.config";
import { Chain } from "viem";

const seed = process.env.DEPLOYER_ACCOUNT_SEED;
if (!seed) throw new Error("Failed to import the seed string from .env");

const w0 = getChildFromSeed(seed, 0); // deployer

// frankencoin addresses
const id = process.env?.CHAINID || 1;
const ADDR = ADDRESS[id as Chain["id"]];

export const config = {
  deployer: w0.address,
  ecosystem: ADDR,
};

console.log("Config Info");
console.log(config);

// ccip admin constructor args
export const ccipAdminArgs = [
  ADDR.tokenAdminRegistry,
  ADDR.frankenCoin,
];
storeConstructorArgs("CCIPAdmin", ccipAdminArgs, true);

console.log("CCIPAdmin Constructor Args");
console.log(ccipAdminArgs);

// token pool constructor args
export const tokenPoolArgs = [
  ADDR.frankenCoin,
  18,
  [],
  ADDR.rmnProxy,
  ADDR.router,
];
storeConstructorArgs("BurnMintTokenPool", tokenPoolArgs, true);

console.log("BurnMintTokenPool Construcotr Args");
console.log(tokenPoolArgs);

// governance sender
export const governanceSenderArgs = [ADDR.equity, ADDR.router, ADDR.linkToken];
storeConstructorArgs(
  "GovernanceSender",
  governanceSenderArgs,
  true
);
console.log("GovernanceSender Constructor Args");
console.log(governanceSenderArgs);

// leadrate sender
export const leadrateSenderArgs = [ADDR.savings, ADDR.router, ADDR.linkToken];
storeConstructorArgs("LeadrateSender", leadrateSenderArgs, true);
console.log("LeadrateSender Constructor Args");
console.log(leadrateSenderArgs);

// bridge accounting
export const bridgeAccountArgs = [
  ADDR.frankenCoin,
  ADDR.tokenAdminRegistry,
  ADDR.router,
];
storeConstructorArgs("BridgeAccounting", bridgeAccountArgs, true);
console.log("BridgeAccounting Constructor Args");
console.log(bridgeAccountArgs);

const CCIPPrepareModule = buildModule("CCIPPrepare", (m) => {
  const ccipAdmin = m.contract("CCIPAdmin", ccipAdminArgs);
  const tokenPool = m.contract("BurnMintTokenPool", tokenPoolArgs);
  m.call(tokenPool, "transferOwnership", [ccipAdmin]);

  const governanceSender = m.contract(
    "GovernanceSender",
    governanceSenderArgs
  );
  const leadrateSender = m.contract("LeadrateSender", leadrateSenderArgs);
  const bridgeAccounting = m.contract("BridgeAccounting", bridgeAccountArgs);
  const frankencoin = m.contractAt("Frankencoin", ADDR.frankenCoin);
  const minApplicationPeriod = m.staticCall(
    frankencoin,
    "MIN_APPLICATION_PERIOD"
  );
  const minFee = m.staticCall(frankencoin, "MIN_FEE");
  m.call(frankencoin, "suggestMinter", [
    bridgeAccounting,
    minApplicationPeriod,
    minFee,
    "Bridge Accounting",
  ], {id: "suggestBridgeAccounting"});
  m.call(frankencoin, "suggestMinter", [
    tokenPool,
    minApplicationPeriod,
    minFee,
    "CCIP TokenPool",
  ], {id: "suggestTokenPool"});

  console.log('')
  console.log("NEXT STEPS:")
  console.log(
    `Ping the Chainlink team to propose CCIPAdmin as admin for ZCHF`
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
