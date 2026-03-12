import { expect } from "chai";
import { floatToDec18 } from "../scripts/math";
import { ethers } from "hardhat";
import { evm_increaseTime } from "./helper";
import {
  Equity,
  Frankencoin,
  FPS2,
  StablecoinBridge,
  TestToken,
} from "../typechain";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

describe("FPS2 Tests", () => {
  let owner: HardhatEthersSigner;
  let alice: HardhatEthersSigner;
  let bob: HardhatEthersSigner;

  let fps2: FPS2;
  let equity: Equity;
  let zchf: Frankencoin;
  let xchf: TestToken;
  let bridge: StablecoinBridge;

  before(async () => {
    [owner, alice, bob] = await ethers.getSigners();

    const xchfFactory = await ethers.getContractFactory("TestToken");
    xchf = await xchfFactory.deploy("CryptoFranc", "XCHF", 18);
  });

  beforeEach(async () => {
    const frankenCoinFactory = await ethers.getContractFactory("Frankencoin");
    zchf = await frankenCoinFactory.deploy(10 * 86400);

    let supply = floatToDec18(1_000_000);
    const bridgeFactory = await ethers.getContractFactory("StablecoinBridge");
    bridge = await bridgeFactory.deploy(
      await xchf.getAddress(),
      await zchf.getAddress(),
      floatToDec18(100_000_000_000)
    );
    await zchf.initialize(await bridge.getAddress(), "");

    await xchf.mint(owner.address, supply);
    await xchf.approve(await bridge.getAddress(), supply);
    await bridge.mint(supply);
    await zchf.transfer(alice.address, floatToDec18(100_000));
    await zchf.transfer(bob.address, floatToDec18(100_000));
    equity = await ethers.getContractAt("Equity", await zchf.reserve());

    const fps2Factory = await ethers.getContractFactory("FPS2");
    fps2 = await fps2Factory.deploy(await zchf.getAddress());
  });

  describe("basic initialization", () => {
    it("should have correct name", async () => {
      expect(await fps2.name()).to.be.equal("Frankencoin Pool Share 2");
    });
    it("should have correct symbol", async () => {
      expect(await fps2.symbol()).to.be.equal("FPS2");
    });
    it("should have 18 decimals", async () => {
      expect(await fps2.decimals()).to.be.equal(18);
    });
    it("should reference the correct Equity contract", async () => {
      expect(await fps2.fps()).to.be.equal(await equity.getAddress());
    });
    it("should reference the correct Frankencoin contract", async () => {
      expect(await fps2.zchf()).to.be.equal(await zchf.getAddress());
    });
    it("should have initial price matching FPS", async () => {
      expect(await fps2.ask()).to.be.equal(await equity.price());
    });
  });

  describe("investment", () => {
    it("should mint FPS2 1:1 with FPS received from Equity.invest", async () => {
      // First, someone needs to seed equity with the initial 1000 ZCHF
      await equity.invest(floatToDec18(1000), 0);

      const investAmount = floatToDec18(10_000);
      await zchf.approve(await fps2.getAddress(), investAmount);

      const expectedFps = await equity.calculateShares(investAmount);
      const tx = await fps2.invest(investAmount, 0);

      const fps2Balance = await fps2.balanceOf(owner.address);
      const fpsHeld = await equity.balanceOf(await fps2.getAddress());

      expect(fps2Balance).to.be.equal(fpsHeld);
      expect(fps2Balance).to.be.approximately(expectedFps, floatToDec18(0.01));
    });

    it("should revert if expected shares exceed actual (slippage protection)", async () => {
      await equity.invest(floatToDec18(1000), 0);
      const investAmount = floatToDec18(10_000);
      await zchf.approve(await fps2.getAddress(), investAmount);

      await expect(
        fps2.invest(investAmount, floatToDec18(999_999))
      ).to.be.revertedWithoutReason();
    });

    it("should require ZCHF approval", async () => {
      await equity.invest(floatToDec18(1000), 0);
      // No approval given
      await expect(fps2.invest(floatToDec18(10_000), 0)).to.be.reverted;
    });

    it("should emit Trade event", async () => {
      await equity.invest(floatToDec18(1000), 0);
      const investAmount = floatToDec18(10_000);
      await zchf.approve(await fps2.getAddress(), investAmount);

      await expect(fps2.invest(investAmount, 0)).to.emit(fps2, "Trade");
    });

    it("FPS2 totalSupply should equal FPS held by FPS2", async () => {
      await equity.invest(floatToDec18(1000), 0);

      // Multiple investments
      await zchf.approve(await fps2.getAddress(), floatToDec18(50_000));
      await fps2.invest(floatToDec18(10_000), 0);
      await fps2.invest(floatToDec18(20_000), 0);

      expect(await fps2.totalSupply()).to.be.equal(
        await equity.balanceOf(await fps2.getAddress())
      );
    });
  });

  describe("vote tracking", () => {
    beforeEach(async () => {
      await equity.invest(floatToDec18(1000), 0);
      await zchf.approve(await fps2.getAddress(), floatToDec18(50_000));
      await fps2.invest(floatToDec18(10_000), 0);
    });

    it("should accumulate votes over time", async () => {
      const votesBefore = await fps2.votes(owner.address);
      await evm_increaseTime(100);
      const votesAfter = await fps2.votes(owner.address);
      expect(votesAfter).to.be.greaterThan(votesBefore);
    });

    it("should correctly track total votes", async () => {
      const totalVotes = await fps2.totalVotes();
      const ownerVotes = await fps2.votes(owner.address);
      expect(totalVotes).to.be.equal(ownerVotes);
    });

    it("should preserve vote totals on transfer", async () => {
      // Alice also invests
      await zchf.connect(alice).approve(await fps2.getAddress(), floatToDec18(10_000));
      await fps2.connect(alice).invest(floatToDec18(10_000), 0);

      await evm_increaseTime(100);

      // Transfer some FPS2 from owner to alice
      const transferAmount = floatToDec18(1);
      await fps2.transfer(alice.address, transferAmount);

      const totalVotes = await fps2.totalVotes();
      const ownerVotes = await fps2.votes(owner.address);
      const aliceVotes = await fps2.votes(alice.address);

      // Total should equal sum (within rounding)
      expect(totalVotes).to.be.approximately(
        ownerVotes + aliceVotes,
        totalVotes / 1000n // small rounding tolerance
      );
    });

    it("relativeVotes should return correct percentage", async () => {
      await evm_increaseTime(100);
      const relVotes = await fps2.relativeVotes(owner.address);
      expect(relVotes).to.be.equal(BigInt(1e18)); // 100% when sole holder
    });

    it("holdingDuration should return correct seconds", async () => {
      const waitTime = 500;
      await evm_increaseTime(waitTime);
      const duration = await fps2.holdingDuration(owner.address);
      expect(duration).to.be.approximately(BigInt(waitTime), 5n);
    });
  });

  describe("delegation and governance (inherited from Governance, 2% quorum)", () => {
    beforeEach(async () => {
      await equity.invest(floatToDec18(1000), 0);
      await zchf.approve(await fps2.getAddress(), floatToDec18(50_000));
      await fps2.invest(floatToDec18(10_000), 0);

      await zchf.connect(alice).approve(await fps2.getAddress(), floatToDec18(10_000));
      await fps2.connect(alice).invest(floatToDec18(10_000), 0);
    });

    it("should allow delegating votes", async () => {
      await fps2.connect(alice).delegateVoteTo(owner.address);
      expect(await fps2.delegates(alice.address)).to.be.equal(owner.address);
    });

    it("should correctly compute votesDelegated with helpers", async () => {
      await fps2.connect(alice).delegateVoteTo(owner.address);
      await evm_increaseTime(100);

      const withoutHelpers = await fps2.votesDelegated(owner.address, []);
      const withHelpers = await fps2.votesDelegated(owner.address, [alice.address]);
      expect(withHelpers).to.be.greaterThan(withoutHelpers);
    });

    it("checkQualified should pass for holder with >= 2% of votes", async () => {
      await evm_increaseTime(100);
      // Owner is a major holder -> should pass 2% check
      await fps2.checkQualified(owner.address, []);
    });

    it("checkQualified should revert for holder with < 2% of votes", async () => {
      // Bob has no FPS2 at all
      await evm_increaseTime(100);

      await expect(
        fps2.checkQualified(bob.address, [])
      ).to.be.revertedWithCustomError(fps2, "NotQualified");
    });
  });

  describe("spread mechanism", () => {
    it("weightedRecentRedemptions should be 0 initially", async () => {
      expect(await fps2.weightedRecentRedemptions()).to.be.equal(0);
    });

    it("weightedRecentRedemptions should decay linearly over 30 days", async () => {
      // We need to sell to set recentlyRedeemed. Set up the full lifecycle.
      await equity.invest(floatToDec18(1000), 0);
      await zchf.approve(await fps2.getAddress(), floatToDec18(50_000));
      await fps2.invest(floatToDec18(50_000), 0);

      // Wait 90 days so FPS2 can redeem
      await evm_increaseTime(90 * 86400 + 60);

      // Sell a small amount to set recentlyRedeemed
      const sellAmount = floatToDec18(1);
      await fps2.redeem(owner.address, sellAmount);

      const recentAfterSell = await fps2.weightedRecentRedemptions();
      expect(recentAfterSell).to.be.greaterThan(0);

      // Wait 15 days -> should be roughly half
      await evm_increaseTime(15 * 86400);
      const recentAfterHalf = await fps2.weightedRecentRedemptions();
      expect(recentAfterHalf).to.be.approximately(recentAfterSell / 2n, recentAfterSell / 100n);

      // Wait another 15 days -> should be 0
      await evm_increaseTime(15 * 86400);
      expect(await fps2.weightedRecentRedemptions()).to.be.equal(0);
    });

    it("calculateEffectiveProceeds should return less than underlying proceeds", async () => {
      await equity.invest(floatToDec18(1000), 0);
      await zchf.approve(await fps2.getAddress(), floatToDec18(50_000));
      await fps2.invest(floatToDec18(50_000), 0);

      const sellAmount = floatToDec18(1);
      const underlyingProceeds = await equity.calculateProceeds(sellAmount);
      const effectiveProceeds = await fps2.calculateEffectiveProceeds(sellAmount);

      // Effective should be slightly less than underlying (due to spread)
      expect(effectiveProceeds).to.be.lessThan(underlyingProceeds);
      // But close to it for a small sell
      expect(effectiveProceeds).to.be.greaterThan(underlyingProceeds * 9n / 10n);
    });

    it("calculateEffectiveProceeds should be capped when underlying proceeds exceed capacity", async () => {
      await equity.invest(floatToDec18(1000), 0);
      await zchf.approve(await fps2.getAddress(), floatToDec18(50_000));
      await fps2.invest(floatToDec18(50_000), 0);

      // Selling all FPS2 shares: underlying proceeds far exceed 10% of equity capital
      const allShares = await fps2.totalSupply();
      const underlyingProceeds = await equity.calculateProceeds(allShares);
      const equityCapital = await zchf.equity();
      const cap = equityCapital / 10n;
      // Underlying proceeds should exceed the cap
      expect(underlyingProceeds).to.be.greaterThan(cap);
      const effectiveProceeds = await fps2.calculateEffectiveProceeds(allShares);
      // Should get partial proceeds: cap² / (2 * cap) = cap / 2
      expect(effectiveProceeds).to.be.greaterThan(0);
      expect(effectiveProceeds).to.be.approximately(cap / 2n, cap / 100n);
    });
  });

  describe("path independence", () => {
    it("selling 2 FPS2 at once vs 1+1 should give similar total proceeds", async () => {
      // Setup: invest, wait 90 days, then use snapshots to compare
      // both scenarios from the exact same blockchain state
      await equity.invest(floatToDec18(1000), 0);
      await zchf.approve(await fps2.getAddress(), floatToDec18(50_000));
      await fps2.invest(floatToDec18(50_000), 0);
      await evm_increaseTime(90 * 86400 + 60);

      const oneShare = floatToDec18(1);
      const twoShares = floatToDec18(2);

      // Take snapshot before any redemption
      const snapshot = await ethers.provider.send("evm_snapshot", []);

      // Scenario A: sell 2 at once
      const balBeforeA = await zchf.balanceOf(alice.address);
      await fps2.redeem(alice.address, twoShares);
      const proceedsA = (await zchf.balanceOf(alice.address)) - balBeforeA;

      // Revert to snapshot for a clean comparison
      await ethers.provider.send("evm_revert", [snapshot]);

      // Scenario B: sell 1, then 1 (from the exact same state)
      const balBeforeB = await zchf.balanceOf(alice.address);
      await fps2.redeem(alice.address, oneShare);
      await fps2.redeem(alice.address, oneShare);
      const proceedsB = (await zchf.balanceOf(alice.address)) - balBeforeB;

      // The ZCHF-based spread formula is path-independent in ZCHF space.
      // However, Equity's own non-linear pricing means the underlying proceeds
      // for 2 shares != 2 * proceeds for 1 share, causing a small difference.
      const tolerance = proceedsA / 100n; // 1%
      expect(proceedsA).to.be.approximately(proceedsB, tolerance);
    });
  });

  describe("redemption", () => {
    beforeEach(async () => {
      // Seed equity and invest in FPS2
      await equity.invest(floatToDec18(1000), 0);
      await zchf.approve(await fps2.getAddress(), floatToDec18(50_000));
      await fps2.invest(floatToDec18(50_000), 0);
    });

    it("should revert during warm-up period (canRedeem fails on Equity)", async () => {
      // FPS2 just received FPS, holding duration < 90 days
      await expect(
        fps2.redeem(owner.address, floatToDec18(1))
      ).to.be.revertedWithoutReason();
    });

    it("should succeed after warm-up period", async () => {
      await evm_increaseTime(90 * 86400 + 60);

      const sellAmount = floatToDec18(1);
      const balBefore = await zchf.balanceOf(owner.address);
      await fps2.redeem(owner.address, sellAmount);
      const balAfter = await zchf.balanceOf(owner.address);

      expect(balAfter).to.be.greaterThan(balBefore);
    });

    it("should apply spread correctly (small sell gets near full price)", async () => {
      await evm_increaseTime(90 * 86400 + 60);

      const sellAmount = floatToDec18(1);
      const underlyingProceeds = await equity.calculateProceeds(sellAmount);

      const balBefore = await zchf.balanceOf(owner.address);
      await fps2.redeem(owner.address, sellAmount);
      const balAfter = await zchf.balanceOf(owner.address);
      const received = balAfter - balBefore;

      // Small sell relative to capacity -> close to full price
      expect(received).to.be.lessThan(underlyingProceeds);
      expect(received).to.be.greaterThan(underlyingProceeds * 90n / 100n);
    });

    it("should keep spread in FPS2 (not send back to Equity)", async () => {
      await evm_increaseTime(90 * 86400 + 60);

      const sellAmount = floatToDec18(1);
      const underlyingProceeds = await equity.calculateProceeds(sellAmount);
      const effectiveProceeds = await fps2.calculateEffectiveProceeds(sellAmount);
      const expectedSpread = underlyingProceeds - effectiveProceeds;
      expect(expectedSpread).to.be.greaterThan(0);

      await fps2.redeem(owner.address, sellAmount);
      const fps2Bal = await zchf.balanceOf(await fps2.getAddress());

      // FPS2 should retain the spread as a ZCHF surplus
      expect(fps2Bal).to.be.approximately(expectedSpread, expectedSpread / 100n);
    });

    it("should return partial proceeds when volume exceeds capacity (no revert)", async () => {
      await evm_increaseTime(90 * 86400 + 60);

      // Sell all shares — proceeds exceed capacity but user gets partial amount
      const allShares = await fps2.balanceOf(owner.address);
      const balBefore = await zchf.balanceOf(owner.address);
      await fps2.redeem(owner.address, allShares);
      const balAfter = await zchf.balanceOf(owner.address);

      // User gets the integral over the positive price curve, not 0
      expect(balAfter - balBefore).to.be.greaterThan(0);
    });

    it("should update weightedRecentRedemptions in ZCHF after sell", async () => {
      await evm_increaseTime(90 * 86400 + 60);

      expect(await fps2.weightedRecentRedemptions()).to.be.equal(0);

      const sellAmount = floatToDec18(1);
      const underlyingProceeds = await equity.calculateProceeds(sellAmount);
      await fps2.redeem(owner.address, sellAmount);

      // Should track the raw ZCHF proceeds to keep (equity + recent) constant
      expect(await fps2.weightedRecentRedemptions()).to.be.approximately(
        underlyingProceeds,
        underlyingProceeds / 100n
      );
    });

    it("redeemExpected should revert if proceeds too low", async () => {
      await evm_increaseTime(90 * 86400 + 60);

      const sellAmount = floatToDec18(1);
      await expect(
        fps2.redeemExpected(owner.address, sellAmount, floatToDec18(999_999))
      ).to.be.revertedWithoutReason();
    });

    it("should emit Trade event with effective proceeds", async () => {
      await evm_increaseTime(90 * 86400 + 60);

      const sellAmount = floatToDec18(1);
      await expect(fps2.redeem(owner.address, sellAmount)).to.emit(fps2, "Trade");
    });

    it("FPS2 totalSupply decreases by shares burned", async () => {
      await evm_increaseTime(90 * 86400 + 60);

      const supplyBefore = await fps2.totalSupply();
      const sellAmount = floatToDec18(1);
      await fps2.redeem(owner.address, sellAmount);
      const supplyAfter = await fps2.totalSupply();

      expect(supplyBefore - supplyAfter).to.be.equal(sellAmount);
    });

    it("should recover capacity over 30 days", async () => {
      await evm_increaseTime(90 * 86400 + 60);

      // Sell to use some capacity
      await fps2.redeem(owner.address, floatToDec18(1));
      const recentAfterSell = await fps2.weightedRecentRedemptions();
      expect(recentAfterSell).to.be.greaterThan(0);

      // Wait 30 days -> full recovery
      await evm_increaseTime(30 * 86400);
      expect(await fps2.weightedRecentRedemptions()).to.be.equal(0);

      // Should be able to sell again with near-full price
      await fps2.redeem(owner.address, floatToDec18(1));
      expect(await fps2.weightedRecentRedemptions()).to.be.greaterThan(0);
    });

    it("investing should reduce the net redemption counter", async () => {
      await evm_increaseTime(90 * 86400 + 60);

      // Sell to set the redemption counter
      await fps2.redeem(owner.address, floatToDec18(1));
      const recentAfterSell = await fps2.weightedRecentRedemptions();
      expect(recentAfterSell).to.be.greaterThan(0);

      // Invest some ZCHF -> should reduce the counter
      const investAmount = recentAfterSell / 2n;
      await zchf.connect(alice).approve(await fps2.getAddress(), investAmount);
      await fps2.connect(alice).invest(investAmount, 0);

      const recentAfterInvest = await fps2.weightedRecentRedemptions();
      expect(recentAfterInvest).to.be.approximately(
        recentAfterSell - investAmount,
        recentAfterSell / 100n
      );
    });

    it("investing more than recent redemptions should zero the counter", async () => {
      await evm_increaseTime(90 * 86400 + 60);

      // Sell to set the redemption counter
      await fps2.redeem(owner.address, floatToDec18(1));
      expect(await fps2.weightedRecentRedemptions()).to.be.greaterThan(0);

      // Invest more than was recently redeemed
      const bigInvestment = floatToDec18(10_000);
      await zchf.connect(alice).approve(await fps2.getAddress(), bigInvestment);
      await fps2.connect(alice).invest(bigInvestment, 0);

      expect(await fps2.weightedRecentRedemptions()).to.be.equal(0);
    });
  });

  describe("minter suggestion via FPS2", () => {
    beforeEach(async () => {
      // Seed equity so FPS2 can have voting power
      await equity.invest(floatToDec18(1000), 0);

      // Invest a large amount through FPS2 so it holds substantial FPS
      await zchf.approve(await fps2.getAddress(), floatToDec18(100_000));
      await fps2.invest(floatToDec18(100_000), 0);

      // Wait so FPS2 accumulates voting power in Equity
      await evm_increaseTime(90 * 86400 + 60);
    });

    it("should record announcement and forward to Frankencoin", async () => {
      const minter = ethers.Wallet.createRandom().address;
      const fee = floatToDec18(1000);
      const period = 90 * 86400; // 90 days

      await zchf.connect(alice).approve(await fps2.getAddress(), fee);
      await fps2.connect(alice).suggestMinter(minter, period, fee, "test minter");

      // Should be recorded in FPS2 announcements
      expect(await fps2.announcements(minter)).to.be.greaterThan(0);

      // Should also be registered on Frankencoin
      expect(await zchf.minters(minter)).to.be.greaterThan(0);
    });

    it("should emit MinterAnnounced event", async () => {
      const minter = ethers.Wallet.createRandom().address;
      const fee = floatToDec18(1000);
      const period = 90 * 86400;

      await zchf.connect(alice).approve(await fps2.getAddress(), fee);
      await expect(fps2.connect(alice).suggestMinter(minter, period, fee, "test"))
        .to.emit(fps2, "MinterAnnounced");
    });

    it("should revert if application period < 90 days", async () => {
      const minter = ethers.Wallet.createRandom().address;
      const fee = floatToDec18(1000);
      const shortPeriod = 10 * 86400; // only 10 days

      await zchf.connect(alice).approve(await fps2.getAddress(), fee);
      await expect(
        fps2.connect(alice).suggestMinter(minter, shortPeriod, fee, "test")
      ).to.be.revertedWithCustomError(fps2, "PeriodTooShort");
    });

    it("anyone can suggest a minter through FPS2", async () => {
      const minter = ethers.Wallet.createRandom().address;
      const fee = floatToDec18(1000);
      const period = 90 * 86400;

      await zchf.connect(bob).approve(await fps2.getAddress(), fee);
      await fps2.connect(bob).suggestMinter(minter, period, fee, "test");

      expect(await fps2.announcements(minter)).to.be.greaterThan(0);
    });
  });

  describe("minter veto (denyMinter)", () => {
    let minterAddress: string;

    beforeEach(async () => {
      // Seed equity so FPS2 can have voting power
      await equity.invest(floatToDec18(1000), 0);

      // Invest a large amount through FPS2 so it holds substantial FPS
      await zchf.approve(await fps2.getAddress(), floatToDec18(100_000));
      await fps2.invest(floatToDec18(100_000), 0);

      // Wait so FPS2 accumulates voting power in Equity
      await evm_increaseTime(90 * 86400 + 60);

      // Suggest a new minter directly through Frankencoin (bypassing FPS2)
      minterAddress = ethers.Wallet.createRandom().address;
      const fee = floatToDec18(1000);
      await zchf.connect(alice).approve(await zchf.getAddress(), fee);
      await zchf.connect(alice).suggestMinter(minterAddress, 10 * 86400, fee, "test minter");
    });

    it("should veto minter not announced through FPS2", async () => {
      // Minter was suggested directly on Frankencoin, not through FPS2
      await fps2.denyMinter(minterAddress, []);

      // Minter should be denied
      expect(await zchf.minters(minterAddress)).to.be.equal(0);
    });

    it("should block veto of minter announced through FPS2", async () => {
      // Suggest a new minter through FPS2 (which records announcement)
      const minter2 = ethers.Wallet.createRandom().address;
      const fee = floatToDec18(1000);
      await zchf.connect(alice).approve(await fps2.getAddress(), fee);
      await fps2.connect(alice).suggestMinter(minter2, 90 * 86400, fee, "properly announced");

      // Trying to veto through FPS2 should be blocked since it was announced
      await expect(
        fps2.denyMinter(minter2, [])
      ).to.be.revertedWithCustomError(fps2, "MinterCorrectlyAnnounced");
    });

    it("should emit MinterVetoed event", async () => {
      await expect(fps2.denyMinter(minterAddress, []))
        .to.emit(fps2, "MinterVetoed");
    });

    it("anyone can trigger the veto", async () => {
      // Bob (who has no FPS2) can trigger the veto
      await fps2.connect(bob).denyMinter(minterAddress, []);
      expect(await zchf.minters(minterAddress)).to.be.equal(0);
    });
  });

  describe("integration", () => {
    it("full lifecycle: invest -> wait -> sell with spread", async () => {
      // 1. Seed equity
      await equity.invest(floatToDec18(1000), 0);

      // 2. Invest in FPS2
      const investAmount = floatToDec18(50_000);
      await zchf.approve(await fps2.getAddress(), investAmount);
      const shares = await fps2.invest(investAmount, 0);

      // 3. Verify FPS2 balance
      const fps2Balance = await fps2.balanceOf(owner.address);
      expect(fps2Balance).to.be.greaterThan(0);
      expect(fps2Balance).to.be.equal(await equity.balanceOf(await fps2.getAddress()));

      // 4. Wait 90 days
      await evm_increaseTime(90 * 86400 + 60);

      // 5. Sell a small portion of FPS2 (1% to stay well within capacity)
      const sellAmount = fps2Balance / 100n;
      const balBefore = await zchf.balanceOf(owner.address);
      await fps2.redeem(owner.address, sellAmount);
      const balAfter = await zchf.balanceOf(owner.address);

      // 6. Verify user received ZCHF
      expect(balAfter - balBefore).to.be.greaterThan(0);

      // 7. Verify FPS2 supply decreased
      expect(await fps2.totalSupply()).to.be.equal(fps2Balance - sellAmount);

      // 8. Verify invariant: FPS2 totalSupply <= FPS held by FPS2
      expect(await fps2.totalSupply()).to.be.equal(
        await equity.balanceOf(await fps2.getAddress())
      );
    });

    it("price consistency: FPS2 price matches FPS price", async () => {
      await equity.invest(floatToDec18(1000), 0);
      await zchf.approve(await fps2.getAddress(), floatToDec18(10_000));
      await fps2.invest(floatToDec18(10_000), 0);

      expect(await fps2.ask()).to.be.equal(await equity.price());
    });
  });
});
