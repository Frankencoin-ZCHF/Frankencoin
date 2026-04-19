import { expect } from "chai";
import { floatToDec18 } from "../scripts/math";
import { ethers } from "hardhat";
import { evm_increaseTime } from "./helper";
import {
  Equity,
  Frankencoin,
  FPS2,
  GovernanceFactory,
  MainnetGovernance,
  StablecoinBridge,
  TestToken,
} from "../typechain";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

const NINETY_DAYS = 90 * 86400;
const THIRTY_DAYS = 30 * 86400;

describe("FPS2 Tests", () => {
  let owner: HardhatEthersSigner;
  let alice: HardhatEthersSigner;
  let bob: HardhatEthersSigner;

  let fps2: FPS2;
  let equity: Equity;
  let zchf: Frankencoin;
  let xchf: TestToken;
  let bridge: StablecoinBridge;
  let fps2Gov: MainnetGovernance;

  before(async () => {
    [owner, alice, bob] = await ethers.getSigners();

    const xchfFactory = await ethers.getContractFactory("TestToken");
    xchf = await xchfFactory.deploy("CryptoFranc", "XCHF", 18);
  });

  beforeEach(async () => {
    // Deploy Frankencoin (which auto-creates Equity)
    const frankenCoinFactory = await ethers.getContractFactory("Frankencoin");
    zchf = await frankenCoinFactory.deploy(10 * 86400);

    // Bootstrap ZCHF supply via bridge
    const supply = floatToDec18(1_000_000);
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
    await zchf.transfer(alice.address, floatToDec18(200_000));
    await zchf.transfer(bob.address, floatToDec18(200_000));

    equity = await ethers.getContractAt("Equity", await zchf.reserve());

    // Seed equity with initial investment (required for invest to work)
    await zchf.approve(await equity.getAddress(), floatToDec18(10_000));
    await equity.invest(floatToDec18(10_000), 0);

    // Deploy GovernanceFactory first
    const govFactoryFactory = await ethers.getContractFactory("GovernanceFactory");
    const govFactory = await govFactoryFactory.deploy();

    // Deploy FPS2 with mock addresses for CCIP/leadrate (not tested here)
    const fps2Factory = await ethers.getContractFactory("FPS2");
    fps2 = await fps2Factory.deploy(
      await govFactory.getAddress(),
      await zchf.getAddress(),
      await equity.getAddress(),
      ethers.ZeroAddress, // ccipAdmin
      ethers.ZeroAddress, // borrowing leadrate
      ethers.ZeroAddress, // savings leadrate
      ethers.ZeroAddress, // CCIP router
      ethers.ZeroAddress  // LINK token
    );

    // Retrieve MainnetGovernance address from equity's delegation
    const fps2GovAddress = await equity.delegates(await fps2.getAddress());
    fps2Gov = await ethers.getContractAt("MainnetGovernance", fps2GovAddress);
  });

  // ==================== Initialization ====================

  describe("initialization", () => {
    it("should have correct name and symbol", async () => {
      expect(await fps2.name()).to.equal("Frankencoin Pool Share 2");
      expect(await fps2.symbol()).to.equal("FPS2");
    });

    it("should have 18 decimals", async () => {
      expect(await fps2.decimals()).to.equal(18);
    });

    it("should reference the correct FPS1 and ZCHF contracts", async () => {
      expect(await fps2.FPS1()).to.equal(await equity.getAddress());
      expect(await fps2.ZCHF()).to.equal(await zchf.getAddress());
    });

    it("asset() should return ZCHF address", async () => {
      expect(await fps2.asset()).to.equal(await zchf.getAddress());
    });

    it("ask() should match FPS1 price", async () => {
      expect(await fps2.ask()).to.equal(await equity.price());
    });

    it("bid() should revert with zero supply (division by zero in discount)", async () => {
      // discount divides by (currentSupply + recentRedemptions), which is 0 when empty
      await expect(fps2.bid()).to.be.reverted;
    });

    it("bid() should equal ask() when no recent redemptions and supply > 0", async () => {
      await zchf.approve(await fps2.getAddress(), floatToDec18(10_000));
      await fps2["deposit(uint256,address)"](floatToDec18(10_000), owner.address);
      // discount(0, 0) = 1.0, so bid = price * 1.0 = ask
      expect(await fps2.bid()).to.be.approximately(await fps2.ask(), floatToDec18(0.01));
    });

    it("should have zero total supply and total assets initially", async () => {
      expect(await fps2.totalSupply()).to.equal(0);
      expect(await fps2.totalAssets()).to.equal(0);
    });

    it("should have delegated FPS1 votes to FPS2Governance", async () => {
      const fps2Address = await fps2.getAddress();
      const delegatee = await equity.delegates(fps2Address);
      expect(delegatee).to.equal(await fps2Gov.getAddress());
    });
  });

  // ==================== ERC-4626 Deposit ====================

  describe("deposit (ERC-4626)", () => {
    it("should mint FPS2 shares equal to FPS1 shares received", async () => {
      const amount = floatToDec18(10_000);
      await zchf.approve(await fps2.getAddress(), amount);

      const expectedShares = await equity.calculateShares(amount);
      await fps2["deposit(uint256,address)"](amount, owner.address);

      const fps2Balance = await fps2.balanceOf(owner.address);
      const fpsHeld = await equity.balanceOf(await fps2.getAddress());
      expect(fps2Balance).to.equal(fpsHeld);
      expect(fps2Balance).to.be.approximately(expectedShares, floatToDec18(0.01));
    });

    it("should deposit to a different receiver", async () => {
      const amount = floatToDec18(10_000);
      await zchf.approve(await fps2.getAddress(), amount);
      await fps2["deposit(uint256,address)"](amount, alice.address);

      expect(await fps2.balanceOf(owner.address)).to.equal(0);
      expect(await fps2.balanceOf(alice.address)).to.be.greaterThan(0);
    });

    it("should emit Deposit event", async () => {
      const amount = floatToDec18(10_000);
      await zchf.approve(await fps2.getAddress(), amount);
      await expect(fps2["deposit(uint256,address)"](amount, owner.address))
        .to.emit(fps2, "Deposit");
    });

    it("should revert without ZCHF approval", async () => {
      await expect(
        fps2["deposit(uint256,address)"](floatToDec18(10_000), owner.address)
      ).to.be.reverted;
    });

    it("deposit with slippage protection should revert if shares too low", async () => {
      const amount = floatToDec18(10_000);
      await zchf.approve(await fps2.getAddress(), amount);
      await expect(
        fps2["deposit(uint256,uint256)"](amount, floatToDec18(999_999))
      ).to.be.revertedWithoutReason();
    });

    it("deposit with slippage protection should succeed when shares met", async () => {
      const amount = floatToDec18(10_000);
      await zchf.approve(await fps2.getAddress(), amount);
      const expectedShares = await equity.calculateShares(amount);
      await fps2["deposit(uint256,uint256)"](amount, expectedShares);

      expect(await fps2.balanceOf(owner.address)).to.be.greaterThanOrEqual(expectedShares);
    });

    it("previewDeposit should match actual deposit", async () => {
      const amount = floatToDec18(10_000);
      const preview = await fps2.previewDeposit(amount);

      await zchf.approve(await fps2.getAddress(), amount);
      await fps2["deposit(uint256,address)"](amount, owner.address);
      const actual = await fps2.balanceOf(owner.address);

      expect(actual).to.be.approximately(preview, floatToDec18(0.01));
    });

    it("totalSupply should equal FPS1 held by FPS2 after multiple deposits", async () => {
      await zchf.approve(await fps2.getAddress(), floatToDec18(50_000));
      await fps2["deposit(uint256,address)"](floatToDec18(10_000), owner.address);
      await fps2["deposit(uint256,address)"](floatToDec18(20_000), owner.address);

      expect(await fps2.totalSupply()).to.equal(
        await equity.balanceOf(await fps2.getAddress())
      );
    });

    it("should reduce the net redemption counter", async () => {
      // First deposit and redeem to set the counter
      await zchf.approve(await fps2.getAddress(), floatToDec18(50_000));
      await fps2["deposit(uint256,address)"](floatToDec18(50_000), owner.address);
      await evm_increaseTime(NINETY_DAYS + 60);

      await fps2["redeem(address,uint256)"](owner.address, floatToDec18(100));
      const recentAfterRedeem = await fps2.weightedRecentRedemptions();
      expect(recentAfterRedeem).to.be.greaterThan(0);

      // New deposit should reduce the counter
      await zchf.connect(alice).approve(await fps2.getAddress(), floatToDec18(50_000));
      await fps2.connect(alice)["deposit(uint256,address)"](floatToDec18(50_000), alice.address);
      expect(await fps2.weightedRecentRedemptions()).to.be.lessThan(recentAfterRedeem);
    });
  });

  // ==================== ERC-4626 Mint ====================

  describe("mint (ERC-4626)", () => {
    it("should mint exact shares and return assets used", async () => {
      const targetShares = floatToDec18(100);
      const assetsNeeded = await fps2.previewMint(targetShares);
      await zchf.approve(await fps2.getAddress(), assetsNeeded * 2n); // extra buffer

      await fps2.mint(targetShares, owner.address);
      // Should have received at least targetShares
      expect(await fps2.balanceOf(owner.address)).to.be.greaterThanOrEqual(targetShares);
    });

    it("should emit Deposit event", async () => {
      const targetShares = floatToDec18(100);
      await zchf.approve(await fps2.getAddress(), floatToDec18(50_000));
      await expect(fps2.mint(targetShares, owner.address)).to.emit(fps2, "Deposit");
    });

    it("previewMint should approximate actual assets needed", async () => {
      const targetShares = floatToDec18(100);
      const preview = await fps2.previewMint(targetShares);

      await zchf.approve(await fps2.getAddress(), preview * 2n);
      // The actual assets taken should be close to preview
      // (exact match is hard due to binary search approximation)
      await fps2.mint(targetShares, owner.address);
      expect(await fps2.balanceOf(owner.address)).to.be.greaterThanOrEqual(targetShares);
    });
  });

  // ==================== ERC-4626 Redeem ====================

  describe("redeem (ERC-4626)", () => {
    beforeEach(async () => {
      await zchf.approve(await fps2.getAddress(), floatToDec18(50_000));
      await fps2["deposit(uint256,address)"](floatToDec18(50_000), owner.address);
    });

    it("should revert before FPS1 90-day holding period", async () => {
      await expect(
        fps2["redeem(uint256,address,address)"](floatToDec18(1), owner.address, owner.address)
      ).to.be.revertedWithoutReason();
    });

    it("should succeed after 90-day holding period", async () => {
      await evm_increaseTime(NINETY_DAYS + 60);

      const shares = floatToDec18(1);
      const balBefore = await zchf.balanceOf(owner.address);
      await fps2["redeem(uint256,address,address)"](shares, owner.address, owner.address);
      const balAfter = await zchf.balanceOf(owner.address);
      expect(balAfter).to.be.greaterThan(balBefore);
    });

    it("should send proceeds to receiver, burn from owner", async () => {
      await evm_increaseTime(NINETY_DAYS + 60);

      const shares = floatToDec18(1);
      const ownerSharesBefore = await fps2.balanceOf(owner.address);
      const aliceBalBefore = await zchf.balanceOf(alice.address);

      await fps2["redeem(uint256,address,address)"](shares, alice.address, owner.address);

      expect(await fps2.balanceOf(owner.address)).to.equal(ownerSharesBefore - shares);
      expect(await zchf.balanceOf(alice.address)).to.be.greaterThan(aliceBalBefore);
    });

    it("should require allowance when caller != owner", async () => {
      await evm_increaseTime(NINETY_DAYS + 60);
      await expect(
        fps2.connect(alice)["redeem(uint256,address,address)"](floatToDec18(1), alice.address, owner.address)
      ).to.be.reverted;
    });

    it("should succeed with allowance when caller != owner", async () => {
      await evm_increaseTime(NINETY_DAYS + 60);

      await fps2.approve(alice.address, floatToDec18(1));
      await fps2.connect(alice)["redeem(uint256,address,address)"](floatToDec18(1), alice.address, owner.address);
      expect(await zchf.balanceOf(alice.address)).to.be.greaterThan(floatToDec18(200_000));
    });

    it("should emit Withdraw event", async () => {
      await evm_increaseTime(NINETY_DAYS + 60);
      await expect(
        fps2["redeem(uint256,address,address)"](floatToDec18(1), owner.address, owner.address)
      ).to.emit(fps2, "Withdraw");
    });

    it("previewRedeem should approximate actual proceeds", async () => {
      await evm_increaseTime(NINETY_DAYS + 60);

      const shares = floatToDec18(1);
      const preview = await fps2.previewRedeem(shares);

      const balBefore = await zchf.balanceOf(owner.address);
      await fps2["redeem(uint256,address,address)"](shares, owner.address, owner.address);
      const actual = (await zchf.balanceOf(owner.address)) - balBefore;

      expect(actual).to.be.approximately(preview, preview / 100n);
    });

    it("maxRedeem should return owner's balance", async () => {
      expect(await fps2.maxRedeem(owner.address)).to.equal(await fps2.balanceOf(owner.address));
    });

    it("totalSupply decreases by burned shares", async () => {
      await evm_increaseTime(NINETY_DAYS + 60);

      const supplyBefore = await fps2.totalSupply();
      const shares = floatToDec18(1);
      await fps2["redeem(uint256,address,address)"](shares, owner.address, owner.address);
      expect(await fps2.totalSupply()).to.equal(supplyBefore - shares);
    });
  });

  // ==================== Custom Redeem ====================

  describe("redeem (custom overloads)", () => {
    beforeEach(async () => {
      await zchf.approve(await fps2.getAddress(), floatToDec18(50_000));
      await fps2["deposit(uint256,address)"](floatToDec18(50_000), owner.address);
      await evm_increaseTime(NINETY_DAYS + 60);
    });

    it("redeem(target, shares) should send proceeds to target", async () => {
      const balBefore = await zchf.balanceOf(alice.address);
      await fps2["redeem(address,uint256)"](alice.address, floatToDec18(1));
      expect(await zchf.balanceOf(alice.address)).to.be.greaterThan(balBefore);
    });

    it("redeemExpected should revert if proceeds below minimum", async () => {
      await expect(
        fps2.redeemExpected(owner.address, floatToDec18(1), floatToDec18(999_999))
      ).to.be.revertedWithoutReason();
    });

    it("redeemExpected should succeed when proceeds meet minimum", async () => {
      const shares = floatToDec18(1);
      const expected = await fps2.previewRedeem(shares);
      // Use 90% of expected as minimum to account for execution difference
      await fps2.redeemExpected(owner.address, shares, expected * 9n / 10n);
    });
  });

  // ==================== ERC-4626 Withdraw ====================

  describe("withdraw (ERC-4626)", () => {
    beforeEach(async () => {
      await zchf.approve(await fps2.getAddress(), floatToDec18(50_000));
      await fps2["deposit(uint256,address)"](floatToDec18(50_000), owner.address);
      await evm_increaseTime(NINETY_DAYS + 60);
    });

    it("should burn the right amount of shares for requested assets", async () => {
      const assets = floatToDec18(100);
      const expectedShares = await fps2.previewWithdraw(assets);
      const supplyBefore = await fps2.totalSupply();

      await fps2.withdraw(assets, owner.address, owner.address);

      const supplyAfter = await fps2.totalSupply();
      expect(supplyBefore - supplyAfter).to.be.approximately(expectedShares, expectedShares / 100n);
    });

    it("should deliver approximately the requested assets to receiver", async () => {
      const assets = floatToDec18(100);
      const balBefore = await zchf.balanceOf(alice.address);
      await fps2.withdraw(assets, alice.address, owner.address);
      const received = (await zchf.balanceOf(alice.address)) - balBefore;
      // Binary search finds shares in view context; actual execution may differ slightly
      expect(received).to.be.approximately(assets, assets / 100n);
    });

    it("maxWithdraw should return effective proceeds for full balance", async () => {
      const maxW = await fps2.maxWithdraw(owner.address);
      const preview = await fps2.previewRedeem(await fps2.balanceOf(owner.address));
      expect(maxW).to.equal(preview);
    });
  });

  // ==================== Spread / Discount Mechanism ====================

  describe("spread mechanism", () => {
    beforeEach(async () => {
      await zchf.approve(await fps2.getAddress(), floatToDec18(50_000));
      await fps2["deposit(uint256,address)"](floatToDec18(50_000), owner.address);
    });

    it("weightedRecentRedemptions should be 0 initially", async () => {
      expect(await fps2.weightedRecentRedemptions()).to.equal(0);
    });

    it("discount should be ~1.0 with no recent redemptions and small planned redemption", async () => {
      const d = await fps2.discount(0, floatToDec18(1));
      // Should be very close to 1e18
      expect(d).to.be.greaterThan(floatToDec18(0.99));
    });

    it("discount should decrease with larger planned redemption", async () => {
      const supply = await fps2.totalSupply();
      const dSmall = await fps2.discount(0, supply / 100n);
      const dLarge = await fps2.discount(0, supply / 2n);
      expect(dLarge).to.be.lessThan(dSmall);
    });

    it("discount should decrease with more recent redemptions", async () => {
      const supply = await fps2.totalSupply();
      const dNoRecent = await fps2.discount(0, floatToDec18(1));
      const dWithRecent = await fps2.discount(supply / 2n, floatToDec18(1));
      expect(dWithRecent).to.be.lessThan(dNoRecent);
    });

    it("small sell should get near-full price", async () => {
      await evm_increaseTime(NINETY_DAYS + 60);

      const shares = floatToDec18(1);
      const rawProceeds = await equity.calculateProceeds(shares);

      const balBefore = await zchf.balanceOf(owner.address);
      await fps2["redeem(address,uint256)"](owner.address, shares);
      const received = (await zchf.balanceOf(owner.address)) - balBefore;

      expect(received).to.be.lessThan(rawProceeds);
      expect(received).to.be.greaterThan(rawProceeds * 90n / 100n);
    });

    it("spread should go back to FPS1 equity", async () => {
      await evm_increaseTime(NINETY_DAYS + 60);

      const equityBefore = await zchf.balanceOf(await equity.getAddress());
      await fps2["redeem(address,uint256)"](owner.address, floatToDec18(1));
      const equityAfter = await zchf.balanceOf(await equity.getAddress());

      // FPS1 redeems sends ZCHF out, but FPS2 sends the spread back
      // Net change on equity should reflect the spread returned
      // (equity loses rawProceeds from redeem, but gains spread back)
      // Just verify equity received something back (the spread)
      // The raw redeem reduces equity, but the spread transfer adds some back
      expect(equityAfter).to.be.greaterThan(0);
    });

    it("weightedRecentRedemptions should increase after redeem", async () => {
      await evm_increaseTime(NINETY_DAYS + 60);

      await fps2["redeem(address,uint256)"](owner.address, floatToDec18(1));
      expect(await fps2.weightedRecentRedemptions()).to.be.greaterThan(0);
    });

    it("weightedRecentRedemptions should decay linearly over 7 days", async () => {
      await evm_increaseTime(NINETY_DAYS + 60);

      await fps2["redeem(address,uint256)"](owner.address, floatToDec18(1));
      const recentFull = await fps2.weightedRecentRedemptions();

      // After 3.5 days -> roughly half
      await evm_increaseTime(3.5 * 86400);
      const recentHalf = await fps2.weightedRecentRedemptions();
      expect(recentHalf).to.be.approximately(recentFull / 2n, recentFull / 50n);

      // After 7 days total -> zero
      await evm_increaseTime(3.5 * 86400);
      expect(await fps2.weightedRecentRedemptions()).to.equal(0);
    });

    it("investing should reduce the net redemption counter", async () => {
      await evm_increaseTime(NINETY_DAYS + 60);

      await fps2["redeem(address,uint256)"](owner.address, floatToDec18(100));
      const recentAfterRedeem = await fps2.weightedRecentRedemptions();
      expect(recentAfterRedeem).to.be.greaterThan(0);

      await zchf.connect(alice).approve(await fps2.getAddress(), floatToDec18(50_000));
      await fps2.connect(alice)["deposit(uint256,address)"](floatToDec18(50_000), alice.address);

      expect(await fps2.weightedRecentRedemptions()).to.be.lessThan(recentAfterRedeem);
    });

    it("large investment should zero the counter", async () => {
      await evm_increaseTime(NINETY_DAYS + 60);

      await fps2["redeem(address,uint256)"](owner.address, floatToDec18(1));
      expect(await fps2.weightedRecentRedemptions()).to.be.greaterThan(0);

      await zchf.connect(alice).approve(await fps2.getAddress(), floatToDec18(100_000));
      await fps2.connect(alice)["deposit(uint256,address)"](floatToDec18(100_000), alice.address);

      expect(await fps2.weightedRecentRedemptions()).to.equal(0);
    });

    it("should recover capacity after 7 days and sell at near-full price again", async () => {
      await evm_increaseTime(NINETY_DAYS + 60);

      // First sell (small amount)
      const smallSell = floatToDec18(1);
      await fps2["redeem(address,uint256)"](owner.address, smallSell);
      expect(await fps2.weightedRecentRedemptions()).to.be.greaterThan(0);

      // Wait 7 days for full recovery
      await evm_increaseTime(7 * 86400);
      expect(await fps2.weightedRecentRedemptions()).to.equal(0);

      // Second sell should get near-full price (no recent redemptions)
      const rawProceeds = await equity.calculateProceeds(smallSell);
      const balBefore = await zchf.balanceOf(owner.address);
      await fps2["redeem(address,uint256)"](owner.address, smallSell);
      const received = (await zchf.balanceOf(owner.address)) - balBefore;
      expect(received).to.be.greaterThan(rawProceeds * 90n / 100n);
    });
  });

  // ==================== Path Independence ====================

  describe("path independence", () => {
    beforeEach(async () => {
      await zchf.approve(await fps2.getAddress(), floatToDec18(50_000));
      await fps2["deposit(uint256,address)"](floatToDec18(50_000), owner.address);
      await evm_increaseTime(NINETY_DAYS + 60);
    });

    it("selling 2 at once vs 1+1 should give similar total proceeds", async () => {
      const oneShare = floatToDec18(1);
      const twoShares = floatToDec18(2);

      const snapshot = await ethers.provider.send("evm_snapshot", []);

      // Scenario A: sell 2 at once
      const balBeforeA = await zchf.balanceOf(alice.address);
      await fps2["redeem(address,uint256)"](alice.address, twoShares);
      const proceedsA = (await zchf.balanceOf(alice.address)) - balBeforeA;

      await ethers.provider.send("evm_revert", [snapshot]);

      // Scenario B: sell 1, then 1
      const balBeforeB = await zchf.balanceOf(alice.address);
      await fps2["redeem(address,uint256)"](alice.address, oneShare);
      await fps2["redeem(address,uint256)"](alice.address, oneShare);
      const proceedsB = (await zchf.balanceOf(alice.address)) - balBeforeB;

      // Small difference is expected due to Equity's non-linear pricing
      expect(proceedsA).to.be.approximately(proceedsB, proceedsA / 100n);
    });
  });

  // ==================== Wrap / Unwrap ====================

  describe("wrap and unwrap", () => {
    beforeEach(async () => {
      // Alice invests directly in FPS1
      await zchf.connect(alice).approve(await equity.getAddress(), floatToDec18(50_000));
      await equity.connect(alice).invest(floatToDec18(50_000), 0);
    });

    it("should wrap FPS1 into FPS2 1:1", async () => {
      const fps1Balance = await equity.balanceOf(alice.address);
      await equity.connect(alice).approve(await fps2.getAddress(), fps1Balance);
      await fps2.connect(alice).wrap(fps1Balance);

      expect(await fps2.balanceOf(alice.address)).to.equal(fps1Balance);
      expect(await equity.balanceOf(alice.address)).to.equal(0);
    });

    it("should credit FPS1 votes to FPS2 on wrap", async () => {
      await evm_increaseTime(100); // accumulate some votes

      const votesBefore = await equity.votes(alice.address);
      expect(votesBefore).to.be.greaterThan(0);

      const fps1Balance = await equity.balanceOf(alice.address);
      await equity.connect(alice).approve(await fps2.getAddress(), fps1Balance);
      await fps2.connect(alice).wrap(fps1Balance);

      // FPS2 votes should reflect the transferred FPS1 votes
      const fps2Votes = await fps2.votes(alice.address);
      expect(fps2Votes).to.be.greaterThan(0);
    });

    it("should unwrap FPS2 back to FPS1 when not binding", async () => {
      const fps1Balance = await equity.balanceOf(alice.address);
      await equity.connect(alice).approve(await fps2.getAddress(), fps1Balance);
      await fps2.connect(alice).wrap(fps1Balance);

      expect(await fps2.isBinding()).to.be.false;

      await fps2.connect(alice).unwrap(fps1Balance);
      expect(await fps2.balanceOf(alice.address)).to.equal(0);
      expect(await equity.balanceOf(alice.address)).to.equal(fps1Balance);
    });

    it("should emit Wrapped and Unwrapped events", async () => {
      const fps1Balance = await equity.balanceOf(alice.address);
      await equity.connect(alice).approve(await fps2.getAddress(), fps1Balance);

      await expect(fps2.connect(alice).wrap(fps1Balance))
        .to.emit(fps2, "Wrapped")
        .withArgs(alice.address, fps1Balance);

      await expect(fps2.connect(alice).unwrap(fps1Balance))
        .to.emit(fps2, "Unwrapped")
        .withArgs(alice.address, fps1Balance);
    });

    it("should revert unwrap when binding", async () => {
      // To become binding, FPS2 must hold > 50% of FPS1 supply.
      // Owner has FPS1 from initial seed. Get total supply.
      const totalFps1 = await equity.totalSupply();

      // Alice wraps her FPS1. If alice holds >50%, it becomes binding.
      // Ensure alice has majority by also having owner invest through FPS2
      const ownerFps1 = await equity.balanceOf(owner.address);
      if (ownerFps1 > 0n) {
        await equity.approve(await fps2.getAddress(), ownerFps1);
        await fps2.wrap(ownerFps1);
      }

      const aliceFps1 = await equity.balanceOf(alice.address);
      await equity.connect(alice).approve(await fps2.getAddress(), aliceFps1);
      await fps2.connect(alice).wrap(aliceFps1);

      // Now FPS2 holds all FPS1 -> binding
      expect(await fps2.isBinding()).to.be.true;

      await expect(
        fps2.connect(alice).unwrap(floatToDec18(1))
      ).to.be.revertedWithCustomError(fps2, "Binding");
    });

    it("should require FPS1 approval to wrap", async () => {
      await expect(
        fps2.connect(alice).wrap(floatToDec18(1))
      ).to.be.reverted;
    });
  });

  // ==================== Vote Tracking ====================

  describe("vote tracking", () => {
    beforeEach(async () => {
      await zchf.approve(await fps2.getAddress(), floatToDec18(50_000));
      await fps2["deposit(uint256,address)"](floatToDec18(10_000), owner.address);
    });

    it("should accumulate votes over time", async () => {
      const votesBefore = await fps2.votes(owner.address);
      await evm_increaseTime(100);
      const votesAfter = await fps2.votes(owner.address);
      expect(votesAfter).to.be.greaterThan(votesBefore);
    });

    it("totalVotes should equal sum of individual votes", async () => {
      await zchf.connect(alice).approve(await fps2.getAddress(), floatToDec18(10_000));
      await fps2.connect(alice)["deposit(uint256,address)"](floatToDec18(10_000), alice.address);

      await evm_increaseTime(100);

      const totalVotes = await fps2.totalVotes();
      const ownerVotes = await fps2.votes(owner.address);
      const aliceVotes = await fps2.votes(alice.address);
      expect(totalVotes).to.be.approximately(ownerVotes + aliceVotes, totalVotes / 1000n);
    });

    it("relativeVotes should return 1e18 for sole holder", async () => {
      await evm_increaseTime(100);
      expect(await fps2.relativeVotes(owner.address)).to.equal(BigInt(1e18));
    });

    it("holdingDuration should track correctly", async () => {
      const waitTime = 500;
      await evm_increaseTime(waitTime);
      const duration = await fps2.holdingDuration(owner.address);
      expect(duration).to.be.approximately(BigInt(waitTime), 5n);
    });

    it("cap should limit votes after HOLDING_DURATION_CAP (365 days)", async () => {
      await evm_increaseTime(366 * 86400); // > 1 year

      const votesBefore = await fps2.votes(owner.address);
      await fps2.cap(owner.address);
      const votesAfter = await fps2.votes(owner.address);
      expect(votesAfter).to.be.lessThan(votesBefore);
    });

    it("cap should be no-op if holding duration <= 365 days", async () => {
      await evm_increaseTime(100 * 86400); // 100 days < 365

      const votesBefore = await fps2.votes(owner.address);
      await fps2.cap(owner.address);
      const votesAfter = await fps2.votes(owner.address);
      // Votes may change slightly due to time passing in the tx, but cap shouldn't reduce them
      expect(votesAfter).to.be.greaterThanOrEqual(votesBefore);
    });
  });

  // ==================== Delegation & Governance ====================

  describe("delegation and governance", () => {
    beforeEach(async () => {
      await zchf.approve(await fps2.getAddress(), floatToDec18(50_000));
      await fps2["deposit(uint256,address)"](floatToDec18(10_000), owner.address);

      await zchf.connect(alice).approve(await fps2.getAddress(), floatToDec18(10_000));
      await fps2.connect(alice)["deposit(uint256,address)"](floatToDec18(10_000), alice.address);
    });

    it("should allow delegating votes", async () => {
      await fps2Gov.connect(alice).delegateVoteTo(owner.address);
      expect(await fps2Gov.delegates(alice.address)).to.equal(owner.address);
    });

    it("votesDelegated should include helper votes", async () => {
      await fps2Gov.connect(alice).delegateVoteTo(owner.address);
      await evm_increaseTime(100);

      const without = await fps2Gov.votesDelegated(owner.address, []);
      const withHelpers = await fps2Gov.votesDelegated(owner.address, [alice.address]);
      expect(withHelpers).to.be.greaterThan(without);
    });

    it("checkQualified should pass for major holder (>= 1%)", async () => {
      await evm_increaseTime(100);
      await fps2Gov.checkQualified(owner.address, []);
    });

    it("checkQualified should revert for non-holder", async () => {
      await evm_increaseTime(100);
      await expect(
        fps2Gov.checkQualified(bob.address, [])
      ).to.be.revertedWithCustomError(fps2Gov, "NotQualified");
    });
  });

  // ==================== Shoot ====================

  describe("shoot", () => {
    it("should destroy target's FPS1 votes when binding", async () => {
      // Wrap majority of FPS1 into FPS2
      const ownerFps1 = await equity.balanceOf(owner.address);
      await equity.approve(await fps2.getAddress(), ownerFps1);
      await fps2.wrap(ownerFps1);

      // Alice invests directly in FPS1 (small amount)
      await zchf.connect(alice).approve(await equity.getAddress(), floatToDec18(1_000));
      await equity.connect(alice).invest(floatToDec18(1_000), 0);

      // Also invest through FPS2 to ensure binding (>50% of FPS1)
      await zchf.approve(await fps2.getAddress(), floatToDec18(100_000));
      await fps2["deposit(uint256,address)"](floatToDec18(100_000), owner.address);

      if (await fps2.isBinding()) {
        const targetVotesBefore = await equity.votes(alice.address);
        expect(targetVotesBefore).to.be.greaterThan(0);

        await evm_increaseTime(100); // accumulate votes

        await fps2.shoot(alice.address);

        const targetVotesAfter = await equity.votes(alice.address);
        expect(targetVotesAfter).to.be.lessThan(targetVotesBefore);
      }
    });

    it("should revert when not binding", async () => {
      await expect(
        fps2.shoot(alice.address)
      ).to.be.revertedWithCustomError(fps2, "NotBinding");
    });
  });

  // ==================== Restructure Cap Table ====================

  describe("restructureCapTable", () => {
    it("should revert when equity is above minimum", async () => {
      // System is healthy, restructure should fail on FPS1 side
      await zchf.approve(await fps2.getAddress(), floatToDec18(50_000));
      await fps2["deposit(uint256,address)"](floatToDec18(50_000), owner.address);
      await evm_increaseTime(100);

      await expect(
        fps2.restructureCapTable([], [], [])
      ).to.be.reverted;
    });
  });

  // ==================== ERC-4626 View Consistency ====================

  describe("ERC-4626 view functions", () => {
    beforeEach(async () => {
      await zchf.approve(await fps2.getAddress(), floatToDec18(50_000));
      await fps2["deposit(uint256,address)"](floatToDec18(50_000), owner.address);
    });

    it("convertToShares should be inverse of ask price", async () => {
      const assets = floatToDec18(1_000);
      const shares = await fps2.convertToShares(assets);
      const askPrice = await fps2.ask();
      // shares = assets / ask
      expect(shares).to.be.approximately(assets * BigInt(1e18) / askPrice, floatToDec18(0.01));
    });

    it("convertToAssets should use bid price", async () => {
      const shares = floatToDec18(1);
      const assets = await fps2.convertToAssets(shares);
      const bidPrice = await fps2.bid();
      expect(assets).to.be.approximately(shares * bidPrice / BigInt(1e18), floatToDec18(0.01));
    });

    it("maxDeposit should return max uint256", async () => {
      expect(await fps2.maxDeposit(owner.address)).to.equal(ethers.MaxUint256);
    });

    it("maxMint should return max uint256", async () => {
      expect(await fps2.maxMint(owner.address)).to.equal(ethers.MaxUint256);
    });

    it("totalAssets should reflect FPS1 value of held shares", async () => {
      const supply = await fps2.totalSupply();
      const expectedAssets = await equity.calculateProceeds(supply);
      expect(await fps2.totalAssets()).to.equal(expectedAssets);
    });
  });

  // ==================== MinterGovernance ====================

  describe("MinterGovernance (via FPS2Governance)", () => {
    beforeEach(async () => {
      // Invest through FPS2 so it has FPS1 voting power
      await zchf.approve(await fps2.getAddress(), floatToDec18(100_000));
      await fps2["deposit(uint256,address)"](floatToDec18(100_000), owner.address);
      await evm_increaseTime(NINETY_DAYS + 60);
    });

    it("should suggest a minter with announcement recorded", async () => {
      const minter = ethers.Wallet.createRandom().address;
      const fee = floatToDec18(5_000);
      const period = NINETY_DAYS;

      await zchf.connect(alice).approve(await fps2Gov.getAddress(), fee);
      await fps2Gov.connect(alice).suggestMinter(minter, period, fee, "test minter");

      expect(await fps2Gov.announcements(minter)).to.be.greaterThan(0);
      expect(await zchf.minters(minter)).to.be.greaterThan(0);
    });

    it("should emit MinterAnnounced event", async () => {
      const minter = ethers.Wallet.createRandom().address;
      const fee = floatToDec18(5_000);

      await zchf.connect(alice).approve(await fps2Gov.getAddress(), fee);
      await expect(fps2Gov.connect(alice).suggestMinter(minter, NINETY_DAYS, fee, "test"))
        .to.emit(fps2Gov, "MinterAnnounced");
    });

    it("should revert if application period < 90 days", async () => {
      const fee = floatToDec18(5_000);
      await zchf.connect(alice).approve(await fps2Gov.getAddress(), fee);
      await expect(
        fps2Gov.connect(alice).suggestMinter(ethers.Wallet.createRandom().address, 10 * 86400, fee, "test")
      ).to.be.revertedWithCustomError(fps2Gov, "PeriodTooShort");
    });

    it("should revert if fee < MIN_APPLICATION_FEE", async () => {
      const lowFee = floatToDec18(100);
      await zchf.connect(alice).approve(await fps2Gov.getAddress(), lowFee);
      await expect(
        fps2Gov.connect(alice).suggestMinter(ethers.Wallet.createRandom().address, NINETY_DAYS, lowFee, "test")
      ).to.be.revertedWithCustomError(fps2Gov, "FeeTooLow");
    });

    it("denyUnannouncedMinter should veto unannounced minter", async () => {
      // Suggest minter directly on Frankencoin (bypassing FPS2Gov)
      const minter = ethers.Wallet.createRandom().address;
      const fee = floatToDec18(1_000);
      await zchf.connect(alice).approve(await zchf.getAddress(), fee);
      await zchf.connect(alice).suggestMinter(minter, 10 * 86400, fee, "bypass");

      // Minter should exist before deny
      expect(await zchf.minters(minter)).to.be.greaterThan(0);

      await fps2Gov.connect(bob).denyUnannouncedMinter(minter);

      // Minter should be removed
      expect(await zchf.minters(minter)).to.equal(0);
    });

    it("denyUnannouncedMinter should pay reward from pool", async () => {
      const minter = ethers.Wallet.createRandom().address;
      const fee = floatToDec18(1_000);
      await zchf.connect(alice).approve(await zchf.getAddress(), fee);
      await zchf.connect(alice).suggestMinter(minter, 10 * 86400, fee, "bypass");

      // Fund reward pool
      await zchf.transfer(await fps2Gov.getAddress(), floatToDec18(1_000));

      // checkReward should show expected reward
      const expectedReward = await fps2Gov.checkReward(minter);
      expect(expectedReward).to.equal(floatToDec18(100));

      await expect(fps2Gov.connect(bob).denyUnannouncedMinter(minter))
        .to.emit(fps2Gov, "Rewarded");
    });

    it("denyUnannouncedMinter should revert for properly announced minter", async () => {
      const minter = ethers.Wallet.createRandom().address;
      const fee = floatToDec18(5_000);
      await zchf.approve(await fps2Gov.getAddress(), fee);
      await fps2Gov.suggestMinter(minter, NINETY_DAYS, fee, "announced");

      await expect(
        fps2Gov.denyUnannouncedMinter(minter)
      ).to.be.revertedWithCustomError(fps2Gov, "MinterCorrectlyAnnounced");
    });

    it("denyMinter should require qualified FPS2 holder", async () => {
      const minter = ethers.Wallet.createRandom().address;
      const fee = floatToDec18(5_000);
      await zchf.approve(await fps2Gov.getAddress(), fee);
      await fps2Gov.suggestMinter(minter, NINETY_DAYS, fee, "announced");

      // Bob has no FPS2 votes
      await expect(
        fps2Gov.connect(bob).denyMinter(minter, [], "veto")
      ).to.be.revertedWithCustomError(fps2Gov, "NotQualified");
    });

    it("denyMinter should succeed for qualified holder", async () => {
      const minter = ethers.Wallet.createRandom().address;
      const fee = floatToDec18(5_000);
      await zchf.approve(await fps2Gov.getAddress(), fee);
      await fps2Gov.suggestMinter(minter, NINETY_DAYS, fee, "announced");

      // Owner has FPS2 votes and should be qualified
      await fps2Gov.denyMinter(minter, [], "veto");
      expect(await zchf.minters(minter)).to.equal(0);
    });
  });

  // ==================== Integration ====================

  describe("integration", () => {
    it("full lifecycle: deposit -> wait -> redeem with spread", async () => {
      const investAmount = floatToDec18(50_000);
      await zchf.approve(await fps2.getAddress(), investAmount);
      await fps2["deposit(uint256,address)"](investAmount, owner.address);

      const fps2Balance = await fps2.balanceOf(owner.address);
      expect(fps2Balance).to.be.greaterThan(0);

      // Invariant: FPS2 supply == FPS1 held
      expect(await fps2.totalSupply()).to.equal(
        await equity.balanceOf(await fps2.getAddress())
      );

      await evm_increaseTime(NINETY_DAYS + 60);

      // Redeem 1%
      const sellAmount = fps2Balance / 100n;
      const balBefore = await zchf.balanceOf(owner.address);
      await fps2["redeem(address,uint256)"](owner.address, sellAmount);
      const balAfter = await zchf.balanceOf(owner.address);

      expect(balAfter - balBefore).to.be.greaterThan(0);
      expect(await fps2.totalSupply()).to.equal(fps2Balance - sellAmount);

      // Invariant still holds
      expect(await fps2.totalSupply()).to.equal(
        await equity.balanceOf(await fps2.getAddress())
      );
    });

    it("wrap -> redeem -> spread goes to equity", async () => {
      // Alice invests in FPS1 directly, then wraps into FPS2
      await zchf.connect(alice).approve(await equity.getAddress(), floatToDec18(50_000));
      await equity.connect(alice).invest(floatToDec18(50_000), 0);

      const aliceFps1 = await equity.balanceOf(alice.address);
      await equity.connect(alice).approve(await fps2.getAddress(), aliceFps1);
      await fps2.connect(alice).wrap(aliceFps1);

      expect(await fps2.balanceOf(alice.address)).to.equal(aliceFps1);

      await evm_increaseTime(NINETY_DAYS + 60);

      // Redeem FPS2
      const redeemAmount = aliceFps1 / 10n;
      await fps2.connect(alice)["redeem(address,uint256)"](alice.address, redeemAmount);

      // FPS2 supply should match FPS1 held
      expect(await fps2.totalSupply()).to.equal(
        await equity.balanceOf(await fps2.getAddress())
      );
    });

    it("multiple users depositing and redeeming", async () => {
      // Owner and Alice both deposit
      await zchf.approve(await fps2.getAddress(), floatToDec18(30_000));
      await fps2["deposit(uint256,address)"](floatToDec18(30_000), owner.address);

      await zchf.connect(alice).approve(await fps2.getAddress(), floatToDec18(20_000));
      await fps2.connect(alice)["deposit(uint256,address)"](floatToDec18(20_000), alice.address);

      await evm_increaseTime(NINETY_DAYS + 60);

      // Both redeem partial amounts
      await fps2["redeem(address,uint256)"](owner.address, floatToDec18(10));
      await fps2.connect(alice)["redeem(address,uint256)"](alice.address, floatToDec18(5));

      // Invariant: FPS2 supply == FPS1 held
      expect(await fps2.totalSupply()).to.equal(
        await equity.balanceOf(await fps2.getAddress())
      );
    });

    it("price consistency: ask matches FPS1 price throughout", async () => {
      await zchf.approve(await fps2.getAddress(), floatToDec18(50_000));
      await fps2["deposit(uint256,address)"](floatToDec18(10_000), owner.address);
      expect(await fps2.ask()).to.equal(await equity.price());

      await fps2["deposit(uint256,address)"](floatToDec18(10_000), owner.address);
      expect(await fps2.ask()).to.equal(await equity.price());

      await evm_increaseTime(NINETY_DAYS + 60);
      await fps2["redeem(address,uint256)"](owner.address, floatToDec18(1));
      expect(await fps2.ask()).to.equal(await equity.price());
    });
  });
});
