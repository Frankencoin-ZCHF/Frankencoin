import { ethers } from "hardhat";
import * as helper from "@nomicfoundation/hardhat-network-helpers";
import { Equity, IBasicFrankencoin } from "../typechain";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

/**
 * Fork test: invests real ZCHF into the live Equity (FPS) contract on mainnet,
 * at the current block, and reports the resulting price impact in percent.
 * No bootstrapping - this is the real, currently outstanding equity/supply.
 */
describe("Equity Price Impact (mainnet fork)", () => {
  const ZCHF_ADDR = "0xB58E61C3098d85632Df34EecfB899A1Ed80921cB";
  const ZCHF_WHALE = "0x9642b23Ed1E01Df1092B92641051881a322F5D4E";

  let owner: HardhatEthersSigner;
  let whale: HardhatEthersSigner;
  let zchf: IBasicFrankencoin;
  let equity: Equity;
  let baseline: helper.SnapshotRestorer;

  function toFloat(x: bigint): number {
    return Number(ethers.formatUnits(x, 18));
  }

  before(async () => {
    const alchemyKey = process.env.ALCHEMY_RPC_KEY;
    await ethers.provider.send("hardhat_reset", [
      { forking: { jsonRpcUrl: `https://eth-mainnet.g.alchemy.com/v2/${alchemyKey}` } },
    ]);

    [owner] = await ethers.getSigners();

    zchf = (await ethers.getContractAt(
      "IBasicFrankencoin",
      ZCHF_ADDR
    )) as unknown as IBasicFrankencoin;
    equity = (await ethers.getContractAt(
      "Equity",
      await zchf.reserve()
    )) as unknown as Equity;

    await owner.sendTransaction({ to: ZCHF_WHALE, value: ethers.parseEther("1") });
    await ethers.provider.send("hardhat_impersonateAccount", [ZCHF_WHALE]);
    whale = await ethers.getSigner(ZCHF_WHALE);

    baseline = await helper.takeSnapshot();
  });

  it("shows the FPS price impact (in %) for a range of investments", async () => {
    const equityBefore = await zchf.balanceOf(await equity.getAddress());
    const whaleBalance = await zchf.balanceOf(ZCHF_WHALE);
    // Sized as fractions of what the whale actually holds, so this stays
    // meaningful regardless of chain state at the time the fork is taken.
    const fractionsPct = [1, 5, 10, 25, 50, 75, 100];

    const rows: Record<string, string>[] = [];

    for (const pct of fractionsPct) {
      const investAmount = (whaleBalance * BigInt(pct)) / 100n;

      const priceBefore = await equity.price();
      const expectedShares = await equity.calculateShares(investAmount);
      await equity.connect(whale).invest(investAmount, expectedShares);
      const priceAfter = await equity.price();

      const priceBeforeF = toFloat(priceBefore);
      const priceAfterF = toFloat(priceAfter);
      const changePct = ((priceAfterF - priceBeforeF) / priceBeforeF) * 100;
      const shareOfEquityPct = (toFloat(investAmount) / toFloat(equityBefore)) * 100;

      rows.push({
        "Invested (ZCHF)": toFloat(investAmount).toFixed(2),
        "% of current equity": `${shareOfEquityPct.toFixed(4)}%`,
        "Price before": priceBeforeF.toFixed(6),
        "Price after": priceAfterF.toFixed(6),
        "Price increase": `${changePct.toFixed(6)}%`,
      });

      // Isolate each row: revert back to the real, unmodified fork state.
      await baseline.restore();
    }

    console.log(`Current block: ${await ethers.provider.getBlockNumber()}`);
    console.log(`Current equity: ${toFloat(equityBefore).toFixed(2)} ZCHF`);
    console.log(`Whale balance used for investing: ${toFloat(whaleBalance).toFixed(2)} ZCHF`);
    console.table(rows);
  });

  it("shows the diminishing price impact of repeatedly investing the same amount", async () => {
    const whaleBalance = await zchf.balanceOf(ZCHF_WHALE);
    const steps = 8;
    const stepAmount = whaleBalance / BigInt(steps * 2); // leave headroom, stay within whale's real balance

    const rows: Record<string, string>[] = [];

    for (let i = 1; i <= steps; i++) {
      const priceBefore = await equity.price();
      const expectedShares = await equity.calculateShares(stepAmount);
      await equity.connect(whale).invest(stepAmount, expectedShares);
      const priceAfter = await equity.price();

      const priceBeforeF = toFloat(priceBefore);
      const priceAfterF = toFloat(priceAfter);
      const changePct = ((priceAfterF - priceBeforeF) / priceBeforeF) * 100;

      rows.push({
        Step: `#${i}`,
        "Invested this step (ZCHF)": toFloat(stepAmount).toFixed(2),
        "Price before": priceBeforeF.toFixed(6),
        "Price after": priceAfterF.toFixed(6),
        "Price increase": `${changePct.toFixed(6)}%`,
      });
    }

    console.table(rows);

    // Leave the fork state as found for any tests that might run after this one.
    await baseline.restore();
  });
});
