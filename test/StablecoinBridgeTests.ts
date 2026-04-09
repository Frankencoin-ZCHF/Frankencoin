import { expect } from "chai";
import { ethers } from "hardhat";
import { Frankencoin, StablecoinBridge, TestToken } from "../typechain";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { evm_increaseTime } from "./helper";

describe("StablecoinBridge", () => {
  let owner: HardhatEthersSigner;
  let alice: HardhatEthersSigner;
  let bob: HardhatEthersSigner;

  let zchf: Frankencoin;
  let bridge: StablecoinBridge;
  let bridgeAddr: string;

  // 18-decimal source token (same decimals as ZCHF)
  let xchf18: TestToken;
  let bridge18: StablecoinBridge;
  let bridge18Addr: string;

  // 6-decimal source token (different decimals)
  let xchf6: TestToken;
  let bridge6: StablecoinBridge;
  let bridge6Addr: string;

  const LIMIT = ethers.parseEther("100000"); // 100k ZCHF limit

  before(async () => {
    [owner, alice, bob] = await ethers.getSigners();

    const frankenCoinFactory = await ethers.getContractFactory("Frankencoin");
    zchf = await frankenCoinFactory.deploy(0); // 0 application period for testing

    const tokenFactory = await ethers.getContractFactory("TestToken");
    xchf18 = await tokenFactory.deploy("CryptoFranc18", "XCHF18", 18);
    xchf6 = await tokenFactory.deploy("CryptoFranc6", "XCHF6", 6);

    const bridgeFactory = await ethers.getContractFactory("StablecoinBridge");
    bridge18 = await bridgeFactory.deploy(
      await xchf18.getAddress(),
      await zchf.getAddress(),
      LIMIT
    );
    bridge18Addr = await bridge18.getAddress();

    bridge6 = await bridgeFactory.deploy(
      await xchf6.getAddress(),
      await zchf.getAddress(),
      LIMIT
    );
    bridge6Addr = await bridge6.getAddress();

    // Grant minting rights
    await zchf.initialize(bridge18Addr, "XCHF18 Bridge");
    await zchf.initialize(bridge6Addr, "XCHF6 Bridge");
  });

  describe("constructor", () => {
    it("should set immutables correctly for 18-decimal token", async () => {
      expect(await bridge18.chf()).to.equal(await xchf18.getAddress());
      expect(await bridge18.zchf()).to.equal(await zchf.getAddress());
      expect(await bridge18.limit()).to.equal(LIMIT);
      expect(await bridge18.minted()).to.equal(0);
      expect(await bridge18.decimalMultiplier()).to.equal(1);
    });

    it("should set decimalMultiplier correctly for 6-decimal token", async () => {
      expect(await bridge6.decimalMultiplier()).to.equal(10n ** 12n);
    });
  });

  describe("same decimals (18)", () => {
    const amount = ethers.parseEther("1000");

    before(async () => {
      await xchf18.mint(owner.address, amount);
      await xchf18.approve(bridge18Addr, amount);
    });

    it("mint: should transfer source tokens and mint ZCHF", async () => {
      const tx = bridge18.mint(amount);
      await expect(tx).to.changeTokenBalance(xchf18, owner, -amount);
      await expect(tx).to.changeTokenBalance(zchf, owner, amount);
      expect(await bridge18.minted()).to.equal(amount);
    });

    it("mint: should emit Mint event", async () => {
      await xchf18.mint(owner.address, amount);
      await xchf18.approve(bridge18Addr, amount);
      await expect(bridge18.mint(amount))
        .to.emit(bridge18, "Mint")
        .withArgs(owner.address, amount);
    });

    it("burn: should burn ZCHF and return source tokens", async () => {
      const burnAmount = ethers.parseEther("500");
      const tx = bridge18.burn(burnAmount);
      await expect(tx).to.changeTokenBalance(zchf, owner, -burnAmount);
      await expect(tx).to.changeTokenBalance(xchf18, owner, burnAmount);
    });

    it("burn: should emit Burn event", async () => {
      const burnAmount = ethers.parseEther("100");
      await expect(bridge18.burn(burnAmount))
        .to.emit(bridge18, "Burn")
        .withArgs(owner.address, burnAmount);
    });

    it("burnAndSend: should burn ZCHF and send source tokens to target", async () => {
      const burnAmount = ethers.parseEther("200");
      const tx = bridge18.burnAndSend(alice.address, burnAmount);
      await expect(tx).to.changeTokenBalance(zchf, owner, -burnAmount);
      await expect(tx).to.changeTokenBalance(xchf18, alice, burnAmount);
    });

    it("burnAndCredit: should burn ZCHF and credit target", async () => {
      const burnAmount = ethers.parseEther("100");
      await expect(bridge18.burnAndCredit(alice.address, burnAmount))
        .to.emit(bridge18, "Credit")
        .withArgs(alice.address, burnAmount);
      expect(await bridge18.credits(alice.address)).to.equal(burnAmount);
      expect(await bridge18.balanceOf(alice.address)).to.equal(burnAmount);
    });

    it("payoutCredit: should pay out credited amount", async () => {
      const credited = await bridge18.credits(alice.address);
      const tx = bridge18.payoutCredit(alice.address);
      await expect(tx).to.changeTokenBalance(xchf18, alice, credited);
      await expect(tx)
        .to.emit(bridge18, "Payout")
        .withArgs(alice.address, credited);
      expect(await bridge18.credits(alice.address)).to.equal(0);
    });
  });

  describe("different decimals (6 -> 18)", () => {
    const sourceAmount = 1000n * 10n ** 6n; // 1000 in 6 decimals
    const zchfAmount = ethers.parseEther("1000"); // 1000 in 18 decimals

    before(async () => {
      await xchf6.mint(owner.address, sourceAmount);
      await xchf6.approve(bridge6Addr, sourceAmount);
    });

    it("mint: should scale up source tokens to ZCHF decimals", async () => {
      const tx = bridge6.mint(sourceAmount);
      await expect(tx).to.changeTokenBalance(xchf6, owner, -BigInt(sourceAmount));
      await expect(tx).to.changeTokenBalance(zchf, owner, zchfAmount);
      expect(await bridge6.minted()).to.equal(zchfAmount);
    });

    it("mintTo: should mint to a different target", async () => {
      await xchf6.mint(owner.address, sourceAmount);
      await xchf6.approve(bridge6Addr, sourceAmount);
      const tx = bridge6.mintTo(alice.address, sourceAmount);
      await expect(tx).to.changeTokenBalance(xchf6, owner, -BigInt(sourceAmount));
      await expect(tx).to.changeTokenBalance(zchf, alice, zchfAmount);
    });

    it("burn: should scale down ZCHF to source token decimals", async () => {
      const tx = bridge6.burn(zchfAmount);
      await expect(tx).to.changeTokenBalance(zchf, owner, -zchfAmount);
      await expect(tx).to.changeTokenBalance(xchf6, owner, BigInt(sourceAmount));
    });

    it("burnAndSend: should send correct source token amount to target", async () => {
      await xchf6.mint(owner.address, sourceAmount);
      await xchf6.approve(bridge6Addr, sourceAmount);
      await bridge6.mint(sourceAmount);

      const tx = bridge6.burnAndSend(bob.address, zchfAmount);
      await expect(tx).to.changeTokenBalance(xchf6, bob, BigInt(sourceAmount));
    });

    it("burnAndCredit: should credit correct source token amount", async () => {
      await xchf6.mint(owner.address, sourceAmount);
      await xchf6.approve(bridge6Addr, sourceAmount);
      await bridge6.mint(sourceAmount);

      await bridge6.burnAndCredit(bob.address, zchfAmount);
      expect(await bridge6.credits(bob.address)).to.equal(sourceAmount);
    });

    it("payoutCredit: should pay out in source token decimals", async () => {
      const credited = await bridge6.credits(bob.address);
      const tx = bridge6.payoutCredit(bob.address);
      await expect(tx).to.changeTokenBalance(xchf6, bob, credited);
      expect(await bridge6.credits(bob.address)).to.equal(0);
    });

    it("burnAndCredit: should emit Credit event with source token amount", async () => {
      await xchf6.mint(owner.address, sourceAmount);
      await xchf6.approve(bridge6Addr, sourceAmount);
      await bridge6.mint(sourceAmount);

      await expect(bridge6.burnAndCredit(bob.address, zchfAmount))
        .to.emit(bridge6, "Credit")
        .withArgs(bob.address, sourceAmount);
      // clean up credit
      await bridge6.payoutCredit(bob.address);
    });
  });

  describe("dust prevention (6 -> 18)", () => {
    const multiplier = 10n ** 12n;

    before(async () => {
      // mint some source tokens so we have ZCHF to work with
      const sourceAmount = 1000n * 10n ** 6n;
      await xchf6.mint(owner.address, sourceAmount);
      await xchf6.approve(bridge6Addr, sourceAmount);
      await bridge6.mint(sourceAmount);
    });

    it("burn: should round down and only burn the aligned ZCHF amount", async () => {
      const dust = multiplier - 1n; // sub-unit dust in ZCHF terms
      const zchfWithDust = ethers.parseEther("10") + dust;
      const expectedChf = 10n * 10n ** 6n;
      const expectedZchfBurned = expectedChf * multiplier;

      const tx = bridge6.burn(zchfWithDust);
      // only the rounded amount of ZCHF is burned, not the dust
      await expect(tx).to.changeTokenBalance(zchf, owner, -expectedZchfBurned);
      await expect(tx).to.changeTokenBalance(xchf6, owner, expectedChf);
    });

    it("burnAndSend: should round down and only burn the aligned ZCHF amount", async () => {
      const dust = multiplier / 2n;
      const zchfWithDust = ethers.parseEther("5") + dust;
      const expectedChf = 5n * 10n ** 6n;
      const expectedZchfBurned = expectedChf * multiplier;

      const tx = bridge6.burnAndSend(alice.address, zchfWithDust);
      await expect(tx).to.changeTokenBalance(zchf, owner, -expectedZchfBurned);
      await expect(tx).to.changeTokenBalance(xchf6, alice, expectedChf);
    });

    it("burnAndCredit: should round down and only burn the aligned ZCHF amount", async () => {
      const dust = 1n;
      const zchfWithDust = ethers.parseEther("3") + dust;
      const expectedChf = 3n * 10n ** 6n;
      const expectedZchfBurned = expectedChf * multiplier;

      const mintedBefore = await bridge6.minted();
      await bridge6.burnAndCredit(alice.address, zchfWithDust);
      expect(await bridge6.minted()).to.equal(mintedBefore - expectedZchfBurned);
      expect(await bridge6.credits(alice.address)).to.equal(expectedChf);
    });
  });

  describe("limit enforcement", () => {
    it("should revert when minting exceeds limit", async () => {
      const overLimit = LIMIT + 1n;
      const sourceAmount6 = overLimit / 10n ** 12n + 1n; // enough to exceed in 6 decimals
      await xchf6.mint(owner.address, sourceAmount6);
      await xchf6.approve(bridge6Addr, sourceAmount6);
      await expect(bridge6.mint(sourceAmount6)).to.be.revertedWithCustomError(
        bridge6,
        "Limit"
      );
    });
  });

  describe("expiration", () => {
    it("should revert minting after horizon", async () => {
      await evm_increaseTime(53 * 7 * 24 * 60 * 60); // 53 weeks
      const amount = 100n * 10n ** 6n;
      await xchf6.mint(owner.address, amount);
      await xchf6.approve(bridge6Addr, amount);
      await expect(bridge6.mint(amount)).to.be.revertedWithCustomError(
        bridge6,
        "Expired"
      );
    });
  });

  describe("minted accounting", () => {
    let freshBridge: StablecoinBridge;
    let freshToken: TestToken;
    let freshZchf: Frankencoin;

    before(async () => {
      // Deploy fresh Frankencoin so we can use initialize
      const frankenCoinFactory = await ethers.getContractFactory("Frankencoin");
      freshZchf = await frankenCoinFactory.deploy(0);

      const tokenFactory = await ethers.getContractFactory("TestToken");
      freshToken = await tokenFactory.deploy("FreshFranc", "FCHF", 6);

      const bridgeFactory = await ethers.getContractFactory("StablecoinBridge");
      freshBridge = await bridgeFactory.deploy(
        await freshToken.getAddress(),
        await freshZchf.getAddress(),
        LIMIT
      );
      await freshZchf.initialize(await freshBridge.getAddress(), "Fresh Bridge");
    });

    it("minted should track net outstanding ZCHF", async () => {
      const sourceAmount = 500n * 10n ** 6n;
      const zchfAmount = ethers.parseEther("500");

      await freshToken.mint(owner.address, sourceAmount);
      await freshToken.approve(await freshBridge.getAddress(), sourceAmount);
      await freshBridge.mint(sourceAmount);
      expect(await freshBridge.minted()).to.equal(zchfAmount);

      await freshBridge.burn(zchfAmount / 2n);
      expect(await freshBridge.minted()).to.equal(zchfAmount / 2n);
    });

    it("burnAndCredit should not double-decrement minted", async () => {
      const mintedBefore = await freshBridge.minted();
      const burnAmount = ethers.parseEther("100");
      await freshBridge.burnAndCredit(alice.address, burnAmount);
      expect(await freshBridge.minted()).to.equal(mintedBefore - burnAmount);
    });
  });
});
