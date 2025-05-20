import { config } from "dotenv";
config();

import { ethers } from "ethers";
import fs from "fs/promises";
import ccipParams from "../deployment/parameters/paramsCCIP.json";
import {
  BridgedGovernance__factory,
  GovernanceSender__factory,
} from "../../typechain";
import { getRpc } from "./rpcs";

async function main() {
  const alchemyKey = process.env.ALCHEMY_RPC_KEY ?? "";
  const sourceChainName = "sepolia";
  const senderAddress = process.argv[2] ?? "";
  const targetChainName = process.argv[3] ?? "";
  const targetAddress = process.argv[4] ?? "";
  const voters = process.argv[5].split(",");
  const sourceProvider = new ethers.JsonRpcProvider(
    getRpc(sourceChainName, alchemyKey)
  );

  console.log(`Sending votes to ${targetChainName}`);
  const sourceWallet = ethers.Wallet.fromPhrase(
    process.env.DEPLOYER_ACCOUNT_SEED ?? "",
    sourceProvider
  );

  const targetParams = ccipParams.find(
    (param) => param.chainName.toLowerCase() === targetChainName.toLowerCase()
  );

  console.log(`Using GovernanceSender ${senderAddress}`);

  console.log(
    `Using BridgedGovernance (${targetAddress}) on ${targetChainName} `
  );

  const governanceSender = GovernanceSender__factory.connect(
    senderAddress,
    sourceWallet
  );

  const fee = await governanceSender["getCCIPFee(uint64,address,address[],bool)"](
    targetParams?.chainSelector ?? '',
    targetAddress,
    voters,
    true
  )

  console.log(`Fee: ${fee.toString()} in native`);
  const tx = await governanceSender["pushVotes(uint64,address,address[])"](
    targetParams?.chainSelector ?? '',
    targetAddress,
    voters,
    {
      value: fee,
    }
  )
  console.log(`Sent transaction ${tx.hash}`);
  const receipt = await tx.wait();
  if(!receipt) {
    throw new Error("Transaction failed");
  }
  console.log(`Transaction confirmed on ${receipt.blockNumber}`);
}

main();
