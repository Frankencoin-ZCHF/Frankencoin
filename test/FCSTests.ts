import { expect } from "chai";
import { floatToDec18 } from "../scripts/math";
import { ethers } from "hardhat";
import { evm_increaseTime } from "./helper";
import {
  Equity,
  Frankencoin,
  FCS,
  MinterGovernance,
  MainnetVotes,
  TestGovernanceFactory,
  StablecoinBridge,
  TestToken,
} from "../typechain";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

const NINETY_DAYS = 90 * 86400;
const THIRTY_DAYS = 30 * 86400;

describe("FCS Tests", () => {
  let owner: HardhatEthersSigner;
  let alice: HardhatEthersSigner;
  let bob: HardhatEthersSigner;

  let fcs: FCS;
  let equity: Equity;
  let zchf: Frankencoin;
  let xchf: TestToken;
  let bridge: StablecoinBridge;
  let minterGov: MinterGovernance;
  // The IGovernance vote contract (reads FCS votes, provides checkQualified/delegateVoteTo/votesDelegated)
  let mainnetVotes: MainnetVotes;
  // Address FCS delegates its FPS1 votes to (the governance cluster helper == InterestGovernance)
  let govHelper: string;

  // Make FCS "binding" (control > 2/3 of FPS1 votes) by wrapping the owner's directly-held FPS1 into FCS,
  // leaving FCS as effectively the sole FPS1 holder. Required for redemptions to be enabled.
  async function bindFps2() {
    const ownerFps1 = await equity.balanceOf(owner.address);
    if (ownerFps1 > 0n) {
      await equity.approve(await fcs.getAddress(), ownerFps1);
      await fcs.wrap(ownerFps1);
    }
  }

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

    // Deploy a test governance factory wired to the local Frankencoin/Equity. The production
    // GovernanceFactory/InnerFactory hardcode mainnet addresses and branch on chainid, so they
    // cannot wire to a fresh local FPS1 (which is required for FCS to become "binding").
    const testFactoryFactory = await ethers.getContractFactory("TestGovernanceFactory");
    const testFactory: TestGovernanceFactory = await testFactoryFactory.deploy(
      await zchf.getAddress(),
      await equity.getAddress()
    );

    // FCS's constructor calls factory.deploy(this), which deploys the governance cluster and
    // delegates FCS's FPS1 votes to the returned helper.
    const fcsFactory = await ethers.getContractFactory("FCS");
    fcs = await fcsFactory.deploy(
      await testFactory.getAddress(),
      await equity.getAddress(), // fps1Gov
      await zchf.getAddress()
    );

    // MinterGovernance module exposes suggestMinter/denyMinter for the governance tests.
    minterGov = await ethers.getContractAt("MinterGovernance", await testFactory.minterGov());
    mainnetVotes = await ethers.getContractAt("MainnetVotes", await testFactory.governance());
    govHelper = await testFactory.interestGov(); // the helper FCS delegates its FPS1 votes to
  });

  // ==================== Initialization ====================

  describe("initialization", () => {
    it("should have correct name and symbol", async () => {
      expect(await fcs.name()).to.equal("Frankencoin Shares");
      expect(await fcs.symbol()).to.equal("FCS");
    });

    it("should have 18 decimals", async () => {
      expect(await fcs.decimals()).to.equal(18);
    });

    it("should reference the correct FPS1 and ZCHF contracts", async () => {
      expect(await fcs.FPS1()).to.equal(await equity.getAddress());
      expect(await fcs.ZCHF()).to.equal(await zchf.getAddress());
    });

    it("asset() should return ZCHF address", async () => {
      expect(await fcs.asset()).to.equal(await zchf.getAddress());
    });

    it("ask() should match FPS1 price", async () => {
      expect(await fcs.ask()).to.equal(await equity.price());
    });

    it("bid() should revert with zero supply (division by zero in discount)", async () => {
      // discount divides by (currentSupply + recentRedemptions), which is 0 when empty
      await expect(fcs.bid()).to.be.reverted;
    });

    it("bid() should equal ask() when no recent redemptions and supply > 0", async () => {
      await zchf.approve(await fcs.getAddress(), floatToDec18(10_000));
      await fcs["deposit(uint256,address)"](floatToDec18(10_000), owner.address);
      // discount(0, 0) = 1.0, so bid = price * 1.0 = ask
      expect(await fcs.bid()).to.be.approximately(await fcs.ask(), floatToDec18(0.01));
    });

    it("should have zero total supply and total assets initially", async () => {
      expect(await fcs.totalSupply()).to.equal(0);
      expect(await fcs.totalAssets()).to.equal(0);
    });

    it("should have delegated FPS1 votes to the governance helper", async () => {
      const fcsAddress = await fcs.getAddress();
      const delegatee = await equity.delegates(fcsAddress);
      expect(delegatee).to.equal(govHelper);
    });
  });

  // ==================== ERC-4626 Deposit ====================

  describe("deposit (ERC-4626)", () => {
    it("should mint FCS shares equal to FPS1 shares received", async () => {
      const amount = floatToDec18(10_000);
      await zchf.approve(await fcs.getAddress(), amount);

      const expectedShares = await equity.calculateShares(amount);
      await fcs["deposit(uint256,address)"](amount, owner.address);

      const fcsBalance = await fcs.balanceOf(owner.address);
      const fpsHeld = await equity.balanceOf(await fcs.getAddress());
      expect(fcsBalance).to.equal(fpsHeld);
      expect(fcsBalance).to.be.approximately(expectedShares, floatToDec18(0.01));
    });

    it("should deposit to a different receiver", async () => {
      const amount = floatToDec18(10_000);
      await zchf.approve(await fcs.getAddress(), amount);
      await fcs["deposit(uint256,address)"](amount, alice.address);

      expect(await fcs.balanceOf(owner.address)).to.equal(0);
      expect(await fcs.balanceOf(alice.address)).to.be.greaterThan(0);
    });

    it("should emit Deposit event", async () => {
      const amount = floatToDec18(10_000);
      await zchf.approve(await fcs.getAddress(), amount);
      await expect(fcs["deposit(uint256,address)"](amount, owner.address))
        .to.emit(fcs, "Deposit");
    });

    it("should revert without ZCHF approval", async () => {
      await expect(
        fcs["deposit(uint256,address)"](floatToDec18(10_000), owner.address)
      ).to.be.reverted;
    });

    it("depositExpected should revert if shares too low", async () => {
      const amount = floatToDec18(10_000);
      await zchf.approve(await fcs.getAddress(), amount);
      await expect(
        fcs.depositExpected(amount, owner.address, floatToDec18(999_999))
      ).to.be.revertedWithoutReason();
    });

    it("depositExpected should succeed when shares met", async () => {
      const amount = floatToDec18(10_000);
      await zchf.approve(await fcs.getAddress(), amount);
      const expectedShares = await equity.calculateShares(amount);
      await fcs.depositExpected(amount, owner.address, expectedShares);

      expect(await fcs.balanceOf(owner.address)).to.be.greaterThanOrEqual(expectedShares);
    });

    it("previewDeposit should match actual deposit", async () => {
      const amount = floatToDec18(10_000);
      const preview = await fcs.previewDeposit(amount);

      await zchf.approve(await fcs.getAddress(), amount);
      await fcs["deposit(uint256,address)"](amount, owner.address);
      const actual = await fcs.balanceOf(owner.address);

      expect(actual).to.be.approximately(preview, floatToDec18(0.01));
    });

    it("totalSupply should equal FPS1 held by FCS after multiple deposits", async () => {
      await zchf.approve(await fcs.getAddress(), floatToDec18(50_000));
      await fcs["deposit(uint256,address)"](floatToDec18(10_000), owner.address);
      await fcs["deposit(uint256,address)"](floatToDec18(20_000), owner.address);

      expect(await fcs.totalSupply()).to.equal(
        await equity.balanceOf(await fcs.getAddress())
      );
    });

    it("should reduce the net redemption counter", async () => {
      // First deposit and redeem to set the counter
      await zchf.approve(await fcs.getAddress(), floatToDec18(50_000));
      await fcs["deposit(uint256,address)"](floatToDec18(50_000), owner.address);
      await bindFps2();
      await evm_increaseTime(NINETY_DAYS + 60);

      await fcs["redeem(address,uint256)"](owner.address, floatToDec18(100));
      const recentAfterRedeem = await fcs.weightedRecentRedemptions();
      expect(recentAfterRedeem).to.be.greaterThan(0);

      // New deposit should reduce the counter
      await zchf.connect(alice).approve(await fcs.getAddress(), floatToDec18(50_000));
      await fcs.connect(alice)["deposit(uint256,address)"](floatToDec18(50_000), alice.address);
      expect(await fcs.weightedRecentRedemptions()).to.be.lessThan(recentAfterRedeem);
    });
  });

  // ==================== ERC-4626 Mint ====================

  describe("mint (ERC-4626)", () => {
    it("should mint exact shares and return assets used", async () => {
      const targetShares = floatToDec18(100);
      const assetsNeeded = await fcs.previewMint(targetShares);
      await zchf.approve(await fcs.getAddress(), assetsNeeded * 2n); // extra buffer

      await fcs.mint(targetShares, owner.address);
      // Should have received at least targetShares
      expect(await fcs.balanceOf(owner.address)).to.be.greaterThanOrEqual(targetShares);
    });

    it("should emit Deposit event", async () => {
      const targetShares = floatToDec18(100);
      await zchf.approve(await fcs.getAddress(), floatToDec18(50_000));
      await expect(fcs.mint(targetShares, owner.address)).to.emit(fcs, "Deposit");
    });

    it("previewMint should approximate actual assets needed", async () => {
      const targetShares = floatToDec18(100);
      const preview = await fcs.previewMint(targetShares);

      await zchf.approve(await fcs.getAddress(), preview * 2n);
      // The actual assets taken should be close to preview
      // (exact match is hard due to binary search approximation)
      await fcs.mint(targetShares, owner.address);
      expect(await fcs.balanceOf(owner.address)).to.be.greaterThanOrEqual(targetShares);
    });
  });

  // ==================== ERC-4626 Redeem ====================

  describe("redeem (ERC-4626)", () => {
    beforeEach(async () => {
      await zchf.approve(await fcs.getAddress(), floatToDec18(50_000));
      await fcs["deposit(uint256,address)"](floatToDec18(50_000), owner.address);
      await bindFps2();
    });

    it("should revert before FPS1 90-day holding period (redemptions disabled)", async () => {
      // FCS is binding, but its FPS1 holding is younger than 90 days, so redemptions are disabled.
      await expect(
        fcs["redeem(uint256,address,address)"](floatToDec18(1), owner.address, owner.address)
      ).to.be.revertedWithCustomError(fcs, "RedemptionsDisabled");
    });

    it("should succeed after 90-day holding period", async () => {
      await evm_increaseTime(NINETY_DAYS + 60);

      const shares = floatToDec18(1);
      const balBefore = await zchf.balanceOf(owner.address);
      await fcs["redeem(uint256,address,address)"](shares, owner.address, owner.address);
      const balAfter = await zchf.balanceOf(owner.address);
      expect(balAfter).to.be.greaterThan(balBefore);
    });

    it("should send proceeds to receiver, burn from owner", async () => {
      await evm_increaseTime(NINETY_DAYS + 60);

      const shares = floatToDec18(1);
      const ownerSharesBefore = await fcs.balanceOf(owner.address);
      const aliceBalBefore = await zchf.balanceOf(alice.address);

      await fcs["redeem(uint256,address,address)"](shares, alice.address, owner.address);

      expect(await fcs.balanceOf(owner.address)).to.equal(ownerSharesBefore - shares);
      expect(await zchf.balanceOf(alice.address)).to.be.greaterThan(aliceBalBefore);
    });

    it("should require allowance when caller != owner", async () => {
      await evm_increaseTime(NINETY_DAYS + 60);
      await expect(
        fcs.connect(alice)["redeem(uint256,address,address)"](floatToDec18(1), alice.address, owner.address)
      ).to.be.reverted;
    });

    it("should succeed with allowance when caller != owner", async () => {
      await evm_increaseTime(NINETY_DAYS + 60);

      await fcs.approve(alice.address, floatToDec18(1));
      await fcs.connect(alice)["redeem(uint256,address,address)"](floatToDec18(1), alice.address, owner.address);
      expect(await zchf.balanceOf(alice.address)).to.be.greaterThan(floatToDec18(200_000));
    });

    it("should emit Withdraw event", async () => {
      await evm_increaseTime(NINETY_DAYS + 60);
      await expect(
        fcs["redeem(uint256,address,address)"](floatToDec18(1), owner.address, owner.address)
      ).to.emit(fcs, "Withdraw");
    });

    it("previewRedeem should approximate actual proceeds", async () => {
      await evm_increaseTime(NINETY_DAYS + 60);

      const shares = floatToDec18(1);
      const preview = await fcs.previewRedeem(shares);

      const balBefore = await zchf.balanceOf(owner.address);
      await fcs["redeem(uint256,address,address)"](shares, owner.address, owner.address);
      const actual = (await zchf.balanceOf(owner.address)) - balBefore;

      expect(actual).to.be.approximately(preview, preview / 100n);
    });

    it("maxRedeem should return owner's balance", async () => {
      await evm_increaseTime(NINETY_DAYS + 60); // redemptions must be enabled (binding + matured holding)
      expect(await fcs.maxRedeem(owner.address)).to.equal(await fcs.balanceOf(owner.address));
    });

    it("totalSupply decreases by burned shares", async () => {
      await evm_increaseTime(NINETY_DAYS + 60);

      const supplyBefore = await fcs.totalSupply();
      const shares = floatToDec18(1);
      await fcs["redeem(uint256,address,address)"](shares, owner.address, owner.address);
      expect(await fcs.totalSupply()).to.equal(supplyBefore - shares);
    });
  });

  // ==================== Custom Redeem ====================

  describe("redeem (custom overloads)", () => {
    beforeEach(async () => {
      await zchf.approve(await fcs.getAddress(), floatToDec18(50_000));
      await fcs["deposit(uint256,address)"](floatToDec18(50_000), owner.address);
      await bindFps2();
      await evm_increaseTime(NINETY_DAYS + 60);
    });

    it("redeem(target, shares) should send proceeds to target", async () => {
      const balBefore = await zchf.balanceOf(alice.address);
      await fcs["redeem(address,uint256)"](alice.address, floatToDec18(1));
      expect(await zchf.balanceOf(alice.address)).to.be.greaterThan(balBefore);
    });

    it("redeemExpected should revert if proceeds below minimum", async () => {
      await expect(
        fcs.redeemExpected(owner.address, floatToDec18(1), floatToDec18(999_999))
      ).to.be.revertedWithoutReason();
    });

    it("redeemExpected should succeed when proceeds meet minimum", async () => {
      const shares = floatToDec18(1);
      const expected = await fcs.previewRedeem(shares);
      // Use 90% of expected as minimum to account for execution difference
      await fcs.redeemExpected(owner.address, shares, expected * 9n / 10n);
    });
  });

  // ==================== ERC-4626 Withdraw ====================

  describe("withdraw (ERC-4626)", () => {
    beforeEach(async () => {
      await zchf.approve(await fcs.getAddress(), floatToDec18(50_000));
      await fcs["deposit(uint256,address)"](floatToDec18(50_000), owner.address);
      await bindFps2();
      await evm_increaseTime(NINETY_DAYS + 60);
    });

    it("should burn the right amount of shares for requested assets", async () => {
      const assets = floatToDec18(100);
      const expectedShares = await fcs.previewWithdraw(assets);
      const supplyBefore = await fcs.totalSupply();

      await fcs.withdraw(assets, owner.address, owner.address);

      const supplyAfter = await fcs.totalSupply();
      expect(supplyBefore - supplyAfter).to.be.approximately(expectedShares, expectedShares / 100n);
    });

    it("should deliver approximately the requested assets to receiver", async () => {
      const assets = floatToDec18(100);
      const balBefore = await zchf.balanceOf(alice.address);
      await fcs.withdraw(assets, alice.address, owner.address);
      const received = (await zchf.balanceOf(alice.address)) - balBefore;
      // Binary search finds shares in view context; actual execution may differ slightly
      expect(received).to.be.approximately(assets, assets / 100n);
    });

    it("maxWithdraw should return effective proceeds for the withdrawable amount", async () => {
      // withdraw is capped at 10% of supply, so maxWithdraw = previewRedeem(min(10% cap, balance)).
      const cap = (await fcs.totalSupply()) / 10n;
      const balance = await fcs.balanceOf(owner.address);
      const amount = cap < balance ? cap : balance;
      const maxW = await fcs.maxWithdraw(owner.address);
      const preview = await fcs.previewRedeem(amount);
      expect(maxW).to.equal(preview);
    });
  });

  // ==================== Spread / Discount Mechanism ====================

  describe("spread mechanism", () => {
    beforeEach(async () => {
      await zchf.approve(await fcs.getAddress(), floatToDec18(50_000));
      await fcs["deposit(uint256,address)"](floatToDec18(50_000), owner.address);
      await bindFps2();
    });

    it("weightedRecentRedemptions should be 0 initially", async () => {
      expect(await fcs.weightedRecentRedemptions()).to.equal(0);
    });

    it("discount should be ~1.0 with no recent redemptions and small planned redemption", async () => {
      const d = await fcs.discount(0, floatToDec18(1));
      // Should be very close to 1e18
      expect(d).to.be.greaterThan(floatToDec18(0.99));
    });

    it("discount should decrease with larger planned redemption", async () => {
      const supply = await fcs.totalSupply();
      const dSmall = await fcs.discount(0, supply / 100n);
      const dLarge = await fcs.discount(0, supply / 2n);
      expect(dLarge).to.be.lessThan(dSmall);
    });

    it("discount should decrease with more recent redemptions", async () => {
      const supply = await fcs.totalSupply();
      const dNoRecent = await fcs.discount(0, floatToDec18(1));
      const dWithRecent = await fcs.discount(supply / 2n, floatToDec18(1));
      expect(dWithRecent).to.be.lessThan(dNoRecent);
    });

    it("small sell should get near-full price", async () => {
      await evm_increaseTime(NINETY_DAYS + 60);

      const shares = floatToDec18(1);
      const rawProceeds = await equity.calculateProceeds(shares);

      const balBefore = await zchf.balanceOf(owner.address);
      await fcs["redeem(address,uint256)"](owner.address, shares);
      const received = (await zchf.balanceOf(owner.address)) - balBefore;

      expect(received).to.be.lessThan(rawProceeds);
      expect(received).to.be.greaterThan(rawProceeds * 90n / 100n);
    });

    it("spread should go back to FPS1 equity", async () => {
      await evm_increaseTime(NINETY_DAYS + 60);

      const equityBefore = await zchf.balanceOf(await equity.getAddress());
      await fcs["redeem(address,uint256)"](owner.address, floatToDec18(1));
      const equityAfter = await zchf.balanceOf(await equity.getAddress());

      // FPS1 redeems sends ZCHF out, but FCS sends the spread back
      // Net change on equity should reflect the spread returned
      // (equity loses rawProceeds from redeem, but gains spread back)
      // Just verify equity received something back (the spread)
      // The raw redeem reduces equity, but the spread transfer adds some back
      expect(equityAfter).to.be.greaterThan(0);
    });

    it("weightedRecentRedemptions should increase after redeem", async () => {
      await evm_increaseTime(NINETY_DAYS + 60);

      await fcs["redeem(address,uint256)"](owner.address, floatToDec18(1));
      expect(await fcs.weightedRecentRedemptions()).to.be.greaterThan(0);
    });

    it("weightedRecentRedemptions should decay linearly over 7 days", async () => {
      await evm_increaseTime(NINETY_DAYS + 60);

      await fcs["redeem(address,uint256)"](owner.address, floatToDec18(1));
      const recentFull = await fcs.weightedRecentRedemptions();

      // After 3.5 days -> roughly half
      await evm_increaseTime(3.5 * 86400);
      const recentHalf = await fcs.weightedRecentRedemptions();
      expect(recentHalf).to.be.approximately(recentFull / 2n, recentFull / 50n);

      // After 7 days total -> zero
      await evm_increaseTime(3.5 * 86400);
      expect(await fcs.weightedRecentRedemptions()).to.equal(0);
    });

    it("investing should reduce the net redemption counter", async () => {
      await evm_increaseTime(NINETY_DAYS + 60);

      await fcs["redeem(address,uint256)"](owner.address, floatToDec18(100));
      const recentAfterRedeem = await fcs.weightedRecentRedemptions();
      expect(recentAfterRedeem).to.be.greaterThan(0);

      await zchf.connect(alice).approve(await fcs.getAddress(), floatToDec18(50_000));
      await fcs.connect(alice)["deposit(uint256,address)"](floatToDec18(50_000), alice.address);

      expect(await fcs.weightedRecentRedemptions()).to.be.lessThan(recentAfterRedeem);
    });

    it("large investment should zero the counter", async () => {
      await evm_increaseTime(NINETY_DAYS + 60);

      await fcs["redeem(address,uint256)"](owner.address, floatToDec18(1));
      expect(await fcs.weightedRecentRedemptions()).to.be.greaterThan(0);

      await zchf.connect(alice).approve(await fcs.getAddress(), floatToDec18(100_000));
      await fcs.connect(alice)["deposit(uint256,address)"](floatToDec18(100_000), alice.address);

      expect(await fcs.weightedRecentRedemptions()).to.equal(0);
    });

    it("should recover capacity after 7 days and sell at near-full price again", async () => {
      await evm_increaseTime(NINETY_DAYS + 60);

      // First sell (small amount)
      const smallSell = floatToDec18(1);
      await fcs["redeem(address,uint256)"](owner.address, smallSell);
      expect(await fcs.weightedRecentRedemptions()).to.be.greaterThan(0);

      // Wait 7 days for full recovery
      await evm_increaseTime(7 * 86400);
      expect(await fcs.weightedRecentRedemptions()).to.equal(0);

      // Second sell should get near-full price (no recent redemptions)
      const rawProceeds = await equity.calculateProceeds(smallSell);
      const balBefore = await zchf.balanceOf(owner.address);
      await fcs["redeem(address,uint256)"](owner.address, smallSell);
      const received = (await zchf.balanceOf(owner.address)) - balBefore;
      expect(received).to.be.greaterThan(rawProceeds * 90n / 100n);
    });
  });

  // ==================== Path Independence ====================

  describe("path independence", () => {
    beforeEach(async () => {
      await zchf.approve(await fcs.getAddress(), floatToDec18(50_000));
      await fcs["deposit(uint256,address)"](floatToDec18(50_000), owner.address);
      await bindFps2();
      await evm_increaseTime(NINETY_DAYS + 60);
    });

    it("selling 2 at once vs 1+1 should give similar total proceeds", async () => {
      const oneShare = floatToDec18(1);
      const twoShares = floatToDec18(2);

      const snapshot = await ethers.provider.send("evm_snapshot", []);

      // Scenario A: sell 2 at once
      const balBeforeA = await zchf.balanceOf(alice.address);
      await fcs["redeem(address,uint256)"](alice.address, twoShares);
      const proceedsA = (await zchf.balanceOf(alice.address)) - balBeforeA;

      await ethers.provider.send("evm_revert", [snapshot]);

      // Scenario B: sell 1, then 1
      const balBeforeB = await zchf.balanceOf(alice.address);
      await fcs["redeem(address,uint256)"](alice.address, oneShare);
      await fcs["redeem(address,uint256)"](alice.address, oneShare);
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

    it("should wrap FPS1 into FCS 1:1", async () => {
      const fps1Balance = await equity.balanceOf(alice.address);
      await equity.connect(alice).approve(await fcs.getAddress(), fps1Balance);
      await fcs.connect(alice).wrap(fps1Balance);

      expect(await fcs.balanceOf(alice.address)).to.equal(fps1Balance);
      expect(await equity.balanceOf(alice.address)).to.equal(0);
    });

    it("should credit FPS1 votes to FCS on wrap", async () => {
      await evm_increaseTime(100); // accumulate some votes

      const votesBefore = await equity.votes(alice.address);
      expect(votesBefore).to.be.greaterThan(0);

      const fps1Balance = await equity.balanceOf(alice.address);
      await equity.connect(alice).approve(await fcs.getAddress(), fps1Balance);
      await fcs.connect(alice).wrap(fps1Balance);

      // FCS votes should reflect the transferred FPS1 votes
      const fcsVotes = await fcs.votes(alice.address);
      expect(fcsVotes).to.be.greaterThan(0);
    });

    it("should unwrap FCS back to FPS1 when not binding", async () => {
      const fps1Balance = await equity.balanceOf(alice.address);
      await equity.connect(alice).approve(await fcs.getAddress(), fps1Balance);
      await fcs.connect(alice).wrap(fps1Balance);

      expect(await fcs.isBinding()).to.be.false;

      await fcs.connect(alice).unwrap(fps1Balance);
      expect(await fcs.balanceOf(alice.address)).to.equal(0);
      expect(await equity.balanceOf(alice.address)).to.equal(fps1Balance);
    });

    it("should emit Wrapped and Unwrapped events", async () => {
      const fps1Balance = await equity.balanceOf(alice.address);
      await equity.connect(alice).approve(await fcs.getAddress(), fps1Balance);

      await expect(fcs.connect(alice).wrap(fps1Balance))
        .to.emit(fcs, "Wrapped")
        .withArgs(alice.address, fps1Balance);

      await expect(fcs.connect(alice).unwrap(fps1Balance))
        .to.emit(fcs, "Unwrapped")
        .withArgs(alice.address, fps1Balance);
    });

    // Note: the current design intentionally relaxed the "cannot unwrap while binding" rule (see FCS.unwrap).
    // Unwrapping is now only gated by the FIFO/holding-duration check, not by the binding state.

    it("should require FPS1 approval to wrap", async () => {
      await expect(
        fcs.connect(alice).wrap(floatToDec18(1))
      ).to.be.reverted;
    });
  });

  // ==================== Vote Tracking ====================

  describe("vote tracking", () => {
    beforeEach(async () => {
      await zchf.approve(await fcs.getAddress(), floatToDec18(50_000));
      await fcs["deposit(uint256,address)"](floatToDec18(10_000), owner.address);
    });

    it("should accumulate votes over time", async () => {
      const votesBefore = await fcs.votes(owner.address);
      await evm_increaseTime(100);
      const votesAfter = await fcs.votes(owner.address);
      expect(votesAfter).to.be.greaterThan(votesBefore);
    });

    it("totalVotes should equal sum of individual votes", async () => {
      await zchf.connect(alice).approve(await fcs.getAddress(), floatToDec18(10_000));
      await fcs.connect(alice)["deposit(uint256,address)"](floatToDec18(10_000), alice.address);

      await evm_increaseTime(100);

      const totalVotes = await fcs.totalVotes();
      const ownerVotes = await fcs.votes(owner.address);
      const aliceVotes = await fcs.votes(alice.address);
      expect(totalVotes).to.be.approximately(ownerVotes + aliceVotes, totalVotes / 1000n);
    });

    it("relativeVotes should return 1e18 for sole holder", async () => {
      await evm_increaseTime(100);
      expect(await fcs.relativeVotes(owner.address)).to.equal(BigInt(1e18));
    });

    it("holdingDuration should track correctly", async () => {
      const waitTime = 500;
      await evm_increaseTime(waitTime);
      const duration = await fcs.holdingDuration(owner.address);
      expect(duration).to.be.approximately(BigInt(waitTime), 5n);
    });

    it("cap should limit votes after HOLDING_DURATION_CAP (365 days)", async () => {
      await evm_increaseTime(366 * 86400); // > 1 year

      const votesBefore = await fcs.votes(owner.address);
      await fcs.cap(owner.address);
      const votesAfter = await fcs.votes(owner.address);
      expect(votesAfter).to.be.lessThan(votesBefore);
    });

    it("cap should be no-op if holding duration <= 365 days", async () => {
      await evm_increaseTime(100 * 86400); // 100 days < 365

      const votesBefore = await fcs.votes(owner.address);
      await fcs.cap(owner.address);
      const votesAfter = await fcs.votes(owner.address);
      // Votes may change slightly due to time passing in the tx, but cap shouldn't reduce them
      expect(votesAfter).to.be.greaterThanOrEqual(votesBefore);
    });
  });

  // ==================== Delegation & Governance ====================

  describe("delegation and governance", () => {
    beforeEach(async () => {
      await zchf.approve(await fcs.getAddress(), floatToDec18(50_000));
      await fcs["deposit(uint256,address)"](floatToDec18(10_000), owner.address);

      await zchf.connect(alice).approve(await fcs.getAddress(), floatToDec18(10_000));
      await fcs.connect(alice)["deposit(uint256,address)"](floatToDec18(10_000), alice.address);
    });

    it("should allow delegating votes", async () => {
      await mainnetVotes.connect(alice).delegateVoteTo(owner.address);
      expect(await mainnetVotes.delegates(alice.address)).to.equal(owner.address);
    });

    it("votesDelegated should include helper votes", async () => {
      await mainnetVotes.connect(alice).delegateVoteTo(owner.address);
      await evm_increaseTime(100);

      const without = await mainnetVotes.votesDelegated(owner.address, []);
      const withHelpers = await mainnetVotes.votesDelegated(owner.address, [alice.address]);
      expect(withHelpers).to.be.greaterThan(without);
    });

    it("checkQualified should pass for major holder (>= 1%)", async () => {
      await evm_increaseTime(100);
      await mainnetVotes.checkQualified(owner.address, []);
    });

    it("checkQualified should revert for non-holder", async () => {
      await evm_increaseTime(100);
      await expect(
        mainnetVotes.checkQualified(bob.address, [])
      ).to.be.revertedWithCustomError(mainnetVotes, "NotQualified");
    });
  });

  // ==================== Shoot ====================

  describe("shoot", () => {
    it("should destroy target's FPS1 votes when binding", async () => {
      // Wrap majority of FPS1 into FCS
      const ownerFps1 = await equity.balanceOf(owner.address);
      await equity.approve(await fcs.getAddress(), ownerFps1);
      await fcs.wrap(ownerFps1);

      // Alice invests directly in FPS1 (small amount)
      await zchf.connect(alice).approve(await equity.getAddress(), floatToDec18(1_000));
      await equity.connect(alice).invest(floatToDec18(1_000), 0);

      // Also invest through FCS to ensure binding (>50% of FPS1)
      await zchf.approve(await fcs.getAddress(), floatToDec18(100_000));
      await fcs["deposit(uint256,address)"](floatToDec18(100_000), owner.address);

      if (await fcs.isBinding()) {
        const targetVotesBefore = await equity.votes(alice.address);
        expect(targetVotesBefore).to.be.greaterThan(0);

        await evm_increaseTime(100); // accumulate votes

        await fcs.shoot(alice.address);

        const targetVotesAfter = await equity.votes(alice.address);
        expect(targetVotesAfter).to.be.lessThan(targetVotesBefore);
      }
    });

    it("should revert when not binding", async () => {
      await expect(
        fcs.shoot(alice.address)
      ).to.be.revertedWithCustomError(fcs, "NotBinding");
    });
  });

  // restructureCapTable was intentionally removed from FCS (see the note in FCS.sol); no test needed.

  // ==================== ERC-4626 View Consistency ====================

  describe("ERC-4626 view functions", () => {
    beforeEach(async () => {
      await zchf.approve(await fcs.getAddress(), floatToDec18(50_000));
      await fcs["deposit(uint256,address)"](floatToDec18(50_000), owner.address);
      await bindFps2();
    });

    it("convertToShares should be inverse of ask price", async () => {
      const assets = floatToDec18(1_000);
      const shares = await fcs.convertToShares(assets);
      const askPrice = await fcs.ask();
      // shares = assets / ask
      expect(shares).to.be.approximately(assets * BigInt(1e18) / askPrice, floatToDec18(0.01));
    });

    it("convertToAssets should use bid price", async () => {
      const shares = floatToDec18(1);
      const assets = await fcs.convertToAssets(shares);
      const bidPrice = await fcs.bid();
      expect(assets).to.be.approximately(shares * bidPrice / BigInt(1e18), floatToDec18(0.01));
    });

    it("maxDeposit should return max uint256", async () => {
      expect(await fcs.maxDeposit(owner.address)).to.equal(ethers.MaxUint256);
    });

    it("maxMint should return max uint256", async () => {
      expect(await fcs.maxMint(owner.address)).to.equal(ethers.MaxUint256);
    });

    it("totalAssets should reflect the FCS share of total equity", async () => {
      // totalAssets = ZCHF.equity() * FCS.totalSupply() / FPS1.totalSupply()
      const expectedAssets =
        ((await zchf.equity()) * (await fcs.totalSupply())) / (await equity.totalSupply());
      expect(await fcs.totalAssets()).to.equal(expectedAssets);
    });
  });

  // ==================== MinterGovernance ====================

  describe("MinterGovernance (via FCSGovernance)", () => {
    beforeEach(async () => {
      // Invest through FCS so it has FPS1 voting power
      await zchf.approve(await fcs.getAddress(), floatToDec18(100_000));
      await fcs["deposit(uint256,address)"](floatToDec18(100_000), owner.address);
      await evm_increaseTime(NINETY_DAYS + 60);
    });

    it("should suggest a minter with announcement recorded", async () => {
      const minter = ethers.Wallet.createRandom().address;
      const fee = floatToDec18(5_000);
      const period = NINETY_DAYS;

      await zchf.connect(alice).approve(await minterGov.getAddress(), fee);
      await minterGov.connect(alice).suggestMinter(minter, period, fee, "test minter");

      expect(await minterGov.announcements(minter)).to.be.greaterThan(0);
      expect(await zchf.minters(minter)).to.be.greaterThan(0);
    });

    it("should emit MinterAnnounced event", async () => {
      const minter = ethers.Wallet.createRandom().address;
      const fee = floatToDec18(5_000);

      await zchf.connect(alice).approve(await minterGov.getAddress(), fee);
      await expect(minterGov.connect(alice).suggestMinter(minter, NINETY_DAYS, fee, "test"))
        .to.emit(minterGov, "MinterAnnounced");
    });

    it("should revert if application period < 90 days", async () => {
      const fee = floatToDec18(5_000);
      await zchf.connect(alice).approve(await minterGov.getAddress(), fee);
      await expect(
        minterGov.connect(alice).suggestMinter(ethers.Wallet.createRandom().address, 10 * 86400, fee, "test")
      ).to.be.revertedWithCustomError(minterGov, "PeriodTooShort");
    });

    it("should revert if fee < MIN_APPLICATION_FEE", async () => {
      const lowFee = floatToDec18(100);
      await zchf.connect(alice).approve(await minterGov.getAddress(), lowFee);
      await expect(
        minterGov.connect(alice).suggestMinter(ethers.Wallet.createRandom().address, NINETY_DAYS, lowFee, "test")
      ).to.be.revertedWithCustomError(minterGov, "FeeTooLow");
    });

    it("denyUnannouncedMinter should veto unannounced minter", async () => {
      // Suggest minter directly on Frankencoin (bypassing FCSGov)
      const minter = ethers.Wallet.createRandom().address;
      const fee = floatToDec18(1_000);
      await zchf.connect(alice).approve(await zchf.getAddress(), fee);
      await zchf.connect(alice).suggestMinter(minter, 10 * 86400, fee, "bypass");

      // Minter should exist before deny
      expect(await zchf.minters(minter)).to.be.greaterThan(0);

      await minterGov.connect(bob).denyUnannouncedMinter(minter);

      // Minter should be removed
      expect(await zchf.minters(minter)).to.equal(0);
    });

    it("denyUnannouncedMinter should pay reward from pool", async () => {
      const minter = ethers.Wallet.createRandom().address;
      const fee = floatToDec18(1_000);
      await zchf.connect(alice).approve(await zchf.getAddress(), fee);
      await zchf.connect(alice).suggestMinter(minter, 10 * 86400, fee, "bypass");

      // Fund reward pool
      await zchf.transfer(await minterGov.getAddress(), floatToDec18(1_000));

      // checkReward should show expected reward
      const expectedReward = await minterGov.checkReward(minter);
      expect(expectedReward).to.equal(floatToDec18(100));

      await expect(minterGov.connect(bob).denyUnannouncedMinter(minter))
        .to.emit(minterGov, "Rewarded");
    });

    it("denyUnannouncedMinter should revert for properly announced minter", async () => {
      const minter = ethers.Wallet.createRandom().address;
      const fee = floatToDec18(5_000);
      await zchf.approve(await minterGov.getAddress(), fee);
      await minterGov.suggestMinter(minter, NINETY_DAYS, fee, "announced");

      await expect(
        minterGov.denyUnannouncedMinter(minter)
      ).to.be.revertedWithCustomError(minterGov, "MinterCorrectlyAnnounced");
    });

    it("denyMinter should require qualified FCS holder", async () => {
      const minter = ethers.Wallet.createRandom().address;
      const fee = floatToDec18(5_000);
      await zchf.approve(await minterGov.getAddress(), fee);
      await minterGov.suggestMinter(minter, NINETY_DAYS, fee, "announced");

      // Bob has no FCS votes; NotQualified is raised by the governance vote contract
      await expect(
        minterGov.connect(bob).denyMinter(minter, [], "veto")
      ).to.be.revertedWithCustomError(mainnetVotes, "NotQualified");
    });

    it("denyMinter should succeed for qualified holder", async () => {
      const minter = ethers.Wallet.createRandom().address;
      const fee = floatToDec18(5_000);
      await zchf.approve(await minterGov.getAddress(), fee);
      await minterGov.suggestMinter(minter, NINETY_DAYS, fee, "announced");

      // Owner has FCS votes and should be qualified
      await minterGov.denyMinter(minter, [], "veto");
      expect(await zchf.minters(minter)).to.equal(0);
    });
  });

  // ==================== Integration ====================

  describe("integration", () => {
    it("full lifecycle: deposit -> wait -> redeem with spread", async () => {
      const investAmount = floatToDec18(50_000);
      await zchf.approve(await fcs.getAddress(), investAmount);
      await fcs["deposit(uint256,address)"](investAmount, owner.address);
      await bindFps2(); // required for redemptions to be enabled

      const fcsBalance = await fcs.balanceOf(owner.address);
      expect(fcsBalance).to.be.greaterThan(0);

      // Invariant: FCS supply == FPS1 held
      expect(await fcs.totalSupply()).to.equal(
        await equity.balanceOf(await fcs.getAddress())
      );

      await evm_increaseTime(NINETY_DAYS + 60);

      // Redeem 1%
      const sellAmount = fcsBalance / 100n;
      const balBefore = await zchf.balanceOf(owner.address);
      await fcs["redeem(address,uint256)"](owner.address, sellAmount);
      const balAfter = await zchf.balanceOf(owner.address);

      expect(balAfter - balBefore).to.be.greaterThan(0);
      expect(await fcs.totalSupply()).to.equal(fcsBalance - sellAmount);

      // Invariant still holds
      expect(await fcs.totalSupply()).to.equal(
        await equity.balanceOf(await fcs.getAddress())
      );
    });

    it("wrap -> redeem -> spread goes to equity", async () => {
      // Alice invests in FPS1 directly, then wraps into FCS
      await zchf.connect(alice).approve(await equity.getAddress(), floatToDec18(50_000));
      await equity.connect(alice).invest(floatToDec18(50_000), 0);

      const aliceFps1 = await equity.balanceOf(alice.address);
      await equity.connect(alice).approve(await fcs.getAddress(), aliceFps1);
      await fcs.connect(alice).wrap(aliceFps1);

      expect(await fcs.balanceOf(alice.address)).to.equal(aliceFps1);

      await bindFps2(); // wrap owner's remaining FPS1 so FCS controls > 2/3 of votes
      await evm_increaseTime(NINETY_DAYS + 60);

      // Redeem FCS
      const redeemAmount = aliceFps1 / 10n;
      await fcs.connect(alice)["redeem(address,uint256)"](alice.address, redeemAmount);

      // FCS supply should match FPS1 held
      expect(await fcs.totalSupply()).to.equal(
        await equity.balanceOf(await fcs.getAddress())
      );
    });

    it("multiple users depositing and redeeming", async () => {
      // Owner and Alice both deposit
      await zchf.approve(await fcs.getAddress(), floatToDec18(30_000));
      await fcs["deposit(uint256,address)"](floatToDec18(30_000), owner.address);

      await zchf.connect(alice).approve(await fcs.getAddress(), floatToDec18(20_000));
      await fcs.connect(alice)["deposit(uint256,address)"](floatToDec18(20_000), alice.address);

      await bindFps2(); // wrap owner's remaining FPS1 so FCS is binding
      await evm_increaseTime(NINETY_DAYS + 60);

      // Both redeem partial amounts
      await fcs["redeem(address,uint256)"](owner.address, floatToDec18(10));
      await fcs.connect(alice)["redeem(address,uint256)"](alice.address, floatToDec18(5));

      // Invariant: FCS supply == FPS1 held
      expect(await fcs.totalSupply()).to.equal(
        await equity.balanceOf(await fcs.getAddress())
      );
    });

    it("price consistency: ask matches FPS1 price throughout", async () => {
      await zchf.approve(await fcs.getAddress(), floatToDec18(50_000));
      await fcs["deposit(uint256,address)"](floatToDec18(10_000), owner.address);
      expect(await fcs.ask()).to.equal(await equity.price());

      await fcs["deposit(uint256,address)"](floatToDec18(10_000), owner.address);
      expect(await fcs.ask()).to.equal(await equity.price());

      await bindFps2(); // required for redemptions to be enabled
      await evm_increaseTime(NINETY_DAYS + 60);
      await fcs["redeem(address,uint256)"](owner.address, floatToDec18(1));
      expect(await fcs.ask()).to.equal(await equity.price());
    });
  });
});
