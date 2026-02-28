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
      expect(await fps2.price()).to.be.equal(await equity.price());
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
      ).to.be.revertedWith("slippage");
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

  describe("delegation", () => {
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

    it("should revert votesDelegated if helper did not delegate", async () => {
      await expect(
        fps2.votesDelegated(owner.address, [alice.address])
      ).to.be.revertedWithoutReason();
    });

    it("should emit Delegation event", async () => {
      await expect(fps2.connect(alice).delegateVoteTo(owner.address))
        .to.emit(fps2, "Delegation")
        .withArgs(alice.address, owner.address);
    });
  });

  describe("governance (1% quorum)", () => {
    it("checkQualified should pass for holder with >= 1% of votes", async () => {
      await equity.invest(floatToDec18(1000), 0);
      await zchf.approve(await fps2.getAddress(), floatToDec18(10_000));
      await fps2.invest(floatToDec18(10_000), 0);

      await evm_increaseTime(100);

      // Owner is sole holder -> 100% of votes -> should pass 1% check
      await fps2.checkQualified(owner.address, []);
    });

    it("checkQualified should revert for holder with < 1% of votes", async () => {
      await equity.invest(floatToDec18(1000), 0);

      // Owner invests a lot
      await zchf.approve(await fps2.getAddress(), floatToDec18(50_000));
      await fps2.invest(floatToDec18(50_000), 0);

      // Alice invests very little
      await zchf.connect(alice).approve(await fps2.getAddress(), 1);
      await fps2.connect(alice).invest(1, 0);

      await evm_increaseTime(100);

      await expect(
        fps2.checkQualified(alice.address, [])
      ).to.be.revertedWithCustomError(fps2, "NotQualified");
    });
  });

  describe("spread mechanism", () => {
    it("capacity should return fps.totalSupply() / 10", async () => {
      await equity.invest(floatToDec18(1000), 0);
      const fpsTotalSupply = await equity.totalSupply();
      expect(await fps2.capacity()).to.be.equal(fpsTotalSupply / 10n);
    });

    it("currentUsedCapacity should be 0 initially", async () => {
      expect(await fps2.currentUsedCapacity()).to.be.equal(0);
    });

    it("currentUsedCapacity should decay linearly over 30 days", async () => {
      // We need to sell to set usedCapacity. Set up the full lifecycle.
      await equity.invest(floatToDec18(1000), 0);
      await zchf.approve(await fps2.getAddress(), floatToDec18(50_000));
      await fps2.invest(floatToDec18(50_000), 0);

      // Wait 90 days so FPS2 can redeem
      await evm_increaseTime(90 * 86400 + 60);

      // Sell a small amount to set usedCapacity
      const sellAmount = floatToDec18(1);
      await fps2.redeem(owner.address, sellAmount);

      const usedAfterSell = await fps2.currentUsedCapacity();
      expect(usedAfterSell).to.be.greaterThan(0);

      // Wait 15 days -> should be roughly half
      await evm_increaseTime(15 * 86400);
      const usedAfterHalf = await fps2.currentUsedCapacity();
      expect(usedAfterHalf).to.be.approximately(usedAfterSell / 2n, usedAfterSell / 100n);

      // Wait another 15 days -> should be 0
      await evm_increaseTime(15 * 86400);
      expect(await fps2.currentUsedCapacity()).to.be.equal(0);
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

    it("calculateEffectiveProceeds should return 0 if exceeds capacity", async () => {
      await equity.invest(floatToDec18(1000), 0);
      await zchf.approve(await fps2.getAddress(), floatToDec18(50_000));
      await fps2.invest(floatToDec18(50_000), 0);

      // Try to sell more than capacity (10% of total FPS)
      const cap = await fps2.capacity();
      const effectiveProceeds = await fps2.calculateEffectiveProceeds(cap + 1n);
      expect(effectiveProceeds).to.be.equal(0);
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

    it("should send spread back to Equity", async () => {
      await evm_increaseTime(90 * 86400 + 60);

      const sellAmount = floatToDec18(1);
      const equityBalBefore = await zchf.balanceOf(await equity.getAddress());
      await fps2.redeem(owner.address, sellAmount);
      const equityBalAfter = await zchf.balanceOf(await equity.getAddress());

      // Equity should have received the spread (minus the underlying proceeds that left)
      // Net effect: equity lost underlying proceeds but got spread back
      // So the net loss to equity = effectiveProceeds (what user received)
      // This means equityBalAfter should be > equityBalBefore - underlyingProceeds
      // (i.e., the spread went back)
      const underlyingProceeds = await equity.calculateProceeds(sellAmount);
      const received = await zchf.balanceOf(owner.address); // just check equity balance increased from spread
      // Since the FPS redemption already moved ZCHF out, and then spread went back,
      // we just verify the equity balance didn't drop by the full underlying amount
      expect(equityBalBefore - equityBalAfter).to.be.lessThan(underlyingProceeds);
    });

    it("should revert when exceeding capacity", async () => {
      await evm_increaseTime(90 * 86400 + 60);

      const cap = await fps2.capacity();
      // Try to sell more than capacity
      await expect(
        fps2.redeem(owner.address, cap + 1n)
      ).to.be.revertedWithCustomError(fps2, "CapacityExceeded");
    });

    it("should update usedCapacity after sell", async () => {
      await evm_increaseTime(90 * 86400 + 60);

      expect(await fps2.currentUsedCapacity()).to.be.equal(0);

      const sellAmount = floatToDec18(1);
      await fps2.redeem(owner.address, sellAmount);

      expect(await fps2.currentUsedCapacity()).to.be.approximately(
        sellAmount,
        floatToDec18(0.01)
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
      const usedAfterSell = await fps2.currentUsedCapacity();
      expect(usedAfterSell).to.be.greaterThan(0);

      // Wait 30 days -> full recovery
      await evm_increaseTime(30 * 86400);
      expect(await fps2.currentUsedCapacity()).to.be.equal(0);

      // Should be able to sell again with near-full price
      await fps2.redeem(owner.address, floatToDec18(1));
      expect(await fps2.currentUsedCapacity()).to.be.greaterThan(0);
    });
  });

  describe("minter pre-announcement", () => {
    it("should record pre-announcement timestamp", async () => {
      const minter = alice.address;
      await fps2.preAnnounceMinter(minter);
      expect(await fps2.preAnnouncements(minter)).to.be.greaterThan(0);
    });

    it("should emit MinterPreAnnounced event", async () => {
      const minter = alice.address;
      await expect(fps2.preAnnounceMinter(minter)).to.emit(fps2, "MinterPreAnnounced");
    });

    it("should revert if minter already pre-announced", async () => {
      const minter = alice.address;
      await fps2.preAnnounceMinter(minter);
      await expect(
        fps2.preAnnounceMinter(minter)
      ).to.be.revertedWithCustomError(fps2, "AlreadyPreAnnounced");
    });

    it("anyone can pre-announce", async () => {
      const minter = bob.address;
      // Alice pre-announces
      await fps2.connect(alice).preAnnounceMinter(minter);
      expect(await fps2.preAnnouncements(minter)).to.be.greaterThan(0);
    });
  });

  describe("minter veto", () => {
    let minterAddress: string;

    beforeEach(async () => {
      // Seed equity so FPS2 can have voting power
      await equity.invest(floatToDec18(1000), 0);

      // Invest a large amount through FPS2 so it holds substantial FPS
      await zchf.approve(await fps2.getAddress(), floatToDec18(100_000));
      await fps2.invest(floatToDec18(100_000), 0);

      // Wait so FPS2 accumulates voting power in Equity
      await evm_increaseTime(90 * 86400 + 60);

      // Suggest a new minter through Frankencoin
      minterAddress = ethers.Wallet.createRandom().address;
      // We need to use the bridge to suggest a minter (since it's an approved minter)
      // Actually we need someone to call suggestMinter with a fee
      // Let's have owner suggest a minter
      const fee = floatToDec18(1000);
      await zchf.connect(alice).approve(await zchf.getAddress(), fee);
      await zchf.connect(alice).suggestMinter(minterAddress, 10 * 86400, fee, "test minter");
    });

    it("should allow veto of non-pre-announced minter", async () => {
      // FPS2 should be able to veto since it holds enough FPS
      // The veto is permissionless - anyone can call it
      await fps2.vetoMinter(minterAddress, [], "veto");

      // Minter should be denied
      expect(await zchf.minters(minterAddress)).to.be.equal(0);
    });

    it("should allow veto of recently pre-announced minter (< 3 months)", async () => {
      // Pre-announce the minter
      await fps2.preAnnounceMinter(minterAddress);

      // But only 0 seconds have passed, less than 90 days
      // Veto should still work
      await fps2.vetoMinter(minterAddress, [], "veto");
      expect(await zchf.minters(minterAddress)).to.be.equal(0);
    });

    it("should block veto of minter pre-announced >= 3 months ago", async () => {
      // Pre-announce the minter
      await fps2.preAnnounceMinter(minterAddress);

      // Wait 90+ days
      await evm_increaseTime(90 * 86400 + 60);

      // Need to re-suggest the minter since the old one might have expired
      const minterAddress2 = ethers.Wallet.createRandom().address;
      const fee = floatToDec18(1000);
      await zchf.connect(alice).approve(await zchf.getAddress(), fee);
      await zchf.connect(alice).suggestMinter(minterAddress2, 10 * 86400, fee, "test minter 2");

      // Pre-announce was for minterAddress, not minterAddress2
      // Let's pre-announce minterAddress2 and wait
      await fps2.preAnnounceMinter(minterAddress2);
      await evm_increaseTime(90 * 86400 + 60);

      // Now veto should be blocked
      await expect(
        fps2.vetoMinter(minterAddress2, [], "veto")
      ).to.be.revertedWithCustomError(fps2, "VetoBlocked");
    });

    it("should emit MinterVetoed event", async () => {
      await expect(fps2.vetoMinter(minterAddress, [], "veto"))
        .to.emit(fps2, "MinterVetoed");
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

      // 5. Sell some FPS2
      const sellAmount = fps2Balance / 10n;
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

      expect(await fps2.price()).to.be.equal(await equity.price());
    });
  });
});
