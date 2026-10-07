import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import { getChildFromSeed } from "../../../helper/wallet";
import { storeConstructorArgs } from "../../../helper/store.args";
import { mainnet } from "viem/chains";
import { getAddress } from "viem";

// Enso router (immutable swap target of LeverageGeneric). The tests discover it from the
// `tx.to` of an Enso route quote (routingStrategy=router); override via ENSO_ROUTER if it changes.
const ENSO_ROUTER = getAddress(
  process.env.ENSO_ROUTER ?? "0xF75584eF6673aD213a685a1B58Cc0330B8eA22Cf"
);

export const config = {
  chainId: mainnet.id,
  ensoRouter: ENSO_ROUTER,
};

console.log("Config Info");
console.log(config);

// constructor args
export const args = [ENSO_ROUTER];
storeConstructorArgs("LeverageGeneric", args, true);

console.log("Constructor Args");
console.log(args);

// buildModule
const LeverageGenericModule = buildModule("LeverageGenericModule", (m) => {
  const leverage = m.contract("LeverageGeneric", args);
  return { leverage };
});

export default LeverageGenericModule;
