import { config } from "dotenv";
config();

import { ethers } from "ethers";
import ccipParams from "../deployment/parameters/paramsCCIP.json";
import { Frankencoin__factory, IRouterClient__factory } from "../../typechain";
import { getRpc } from "./rpcs";
import { ERC20__factory } from "../../typechain/factories/erc20";

async function main() {
  const alchemyKey = process.env.ALCHEMY_RPC_KEY ?? "";
  const sourceChainName = process.argv[2] ?? "";
  const targetChainName = process.argv[3] ?? "";
  const receiver = process.argv[4] ?? "";
  const amount = ethers.parseEther(process.argv[5] ?? "");
  const feeToken = process.argv[6] ?? "";
  const sourceProvider = new ethers.JsonRpcProvider(
    getRpc(sourceChainName, alchemyKey)
  );
  const sourceWallet = ethers.Wallet.fromPhrase(
    process.env.DEPLOYER_ACCOUNT_SEED ?? "",
    sourceProvider
  );

  const sourceParams = ccipParams.find(
    (param) => param.chainName.toLowerCase() === sourceChainName.toLowerCase()
  );
  const targetParams = ccipParams.find(
    (param) => param.chainName.toLowerCase() === targetChainName.toLowerCase()
  );

  let feeTokenAddress = ethers.ZeroAddress;
  if (feeToken.toLowerCase() === "link") {
    feeTokenAddress = sourceParams?.link ?? ethers.ZeroAddress;
  }

  const router = IRouterClient__factory.connect(
    sourceParams?.router ?? "",
    sourceWallet
  );

  const functionSelector = ethers.id("CCIP EVMExtraArgsV2").slice(0, 10);
  const extraArgs = ethers.AbiCoder.defaultAbiCoder().encode(
    ["uint256", "bool"],
    [0, true]
  );
  const encodedExtraArgs = functionSelector + extraArgs.slice(2);
  const message = {
    receiver: ethers.AbiCoder.defaultAbiCoder().encode(["address"], [receiver]), // Encode the receiver address
    data: "0x", // No additional data
    tokenAmounts: [
      {
        token: sourceParams?.zchf ?? "",
        amount,
      },
    ],
    feeToken: feeTokenAddress, // Use either LINK or native token for fees
    extraArgs: encodedExtraArgs, // Encoded extra arguments
  };
  const fee = await router.getFee(targetParams?.chainSelector ?? "", message);

  const zchfContract = Frankencoin__factory.connect(
    sourceParams?.zchf ?? "",
    sourceWallet
  );
  if (
    (await zchfContract.allowance(
      sourceWallet.address,
      sourceParams?.router ?? ""
    )) < amount
  ) {
    const approveTx = await zchfContract.approve(
      sourceParams?.router ?? "",
      amount
    );
    await approveTx.wait();
    console.log(
      `Approved router to spend ${amount} ZCHF with TX ${approveTx.hash}`
    );
  } else {
    console.log("Already enough approval for router. Skipping...");
  }

  if (feeTokenAddress !== ethers.ZeroAddress) {
    console.log(`Approving router on feetoken...`);
    const feeTokenContract = ERC20__factory.connect(
      feeTokenAddress,
      sourceWallet
    );
    if (
      (await feeTokenContract.allowance(
        sourceWallet.address,
        sourceParams?.router ?? ""
      )) < fee
    ) {
      const approvalTx = await feeTokenContract.approve(
        sourceParams?.router ?? "",
        fee
      );
      await approvalTx.wait();
      console.log("Approved router on fee token");
    } else {
      console.log("Enough allowance");
    }
  }

  console.log(
    `Transfering ${amount} ZCHF to ${receiver} on ${targetChainName} with ${fee} fee`
  );
  const sendTx = await router.ccipSend(
    targetParams?.chainSelector ?? "",
    message,
    { value: feeTokenAddress === ethers.ZeroAddress ? fee : 0 }
  );
  await sendTx.wait();
  console.log(`Initiated transfer with ${sendTx.hash}`);
}

main();
