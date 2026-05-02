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

    it("should revert when source token has more decimals than ZCHF", async () => {
      const tokenFactory = await ethers.getContractFactory("TestToken");
      const xchf24 = await tokenFactory.deploy("CryptoFranc24", "XCHF24", 24);
      const bridgeFactory = await ethers.getContractFactory("StablecoinBridge");
      // 18 - 24 underflows in the constructor, triggering a Solidity 0.8 arithmetic panic
      await expect(
        bridgeFactory.deploy(await xchf24.getAddress(), await zchf.getAddress(), LIMIT)
      ).to.be.revertedWithPanic(0x11);
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

  describe("permissioning", () => {
    it("payoutCredit: anyone can trigger payout for a credited address", async () => {
      // alice (unrelated to the credit holder) calls payoutCredit on bob's behalf;
      // the source tokens must land on bob regardless of who paid the gas.
      const sourceAmount = 100n * 10n ** 6n;
      const zchfAmount = ethers.parseEther("100");

      await xchf6.mint(owner.address, sourceAmount);
      await xchf6.approve(bridge6Addr, sourceAmount);
      await bridge6.mint(sourceAmount);
      await bridge6.burnAndCredit(bob.address, zchfAmount);
      expect(await bridge6.credits(bob.address)).to.equal(sourceAmount);

      const tx = bridge6.connect(alice).payoutCredit(bob.address);
      await expect(tx).to.changeTokenBalance(xchf6, bob, sourceAmount);
      await expect(tx).to.emit(bridge6, "Payout").withArgs(bob.address, sourceAmount);
      expect(await bridge6.credits(bob.address)).to.equal(0);
    });
  });

  describe("credit accumulation", () => {
    it("burnAndCredit: should add to existing credit balance", async () => {
      const sourceAmount = 200n * 10n ** 6n;

      // two separate burnAndCredit calls in source-token base units
      const firstSource = 70n * 10n ** 6n;
      const secondSource = 130n * 10n ** 6n;
      const firstZchf = firstSource * 10n ** 12n;
      const secondZchf = secondSource * 10n ** 12n;

      await xchf6.mint(owner.address, sourceAmount);
      await xchf6.approve(bridge6Addr, sourceAmount);
      await bridge6.mint(sourceAmount);

      const before = await bridge6.credits(bob.address);
      await bridge6.burnAndCredit(bob.address, firstZchf);
      await bridge6.burnAndCredit(bob.address, secondZchf);
      expect(await bridge6.credits(bob.address)).to.equal(before + firstSource + secondSource);

      // payout drains the full accumulated balance in a single call
      const total = before + firstSource + secondSource;
      await expect(bridge6.payoutCredit(bob.address))
        .to.emit(bridge6, "Payout")
        .withArgs(bob.address, total);
      expect(await bridge6.credits(bob.address)).to.equal(0);
    });
  });

  describe("sub-unit burn (6 -> 18)", () => {
    it("burn: zchfAmount below decimalMultiplier is a silent no-op", async () => {
      // Below one source-token unit there is nothing to redeem. The bridge rounds chfAmount
      // to zero and burns zero ZCHF. Asserting this fixes the behavior so a future change
      // away from "round down" is caught explicitly.
      const subUnit = 10n ** 12n - 1n;
      const mintedBefore = await bridge6.minted();
      const tx = bridge6.burn(subUnit);
      await expect(tx).to.changeTokenBalance(zchf, owner, 0);
      await expect(tx).to.changeTokenBalance(xchf6, owner, 0);
      expect(await bridge6.minted()).to.equal(mintedBefore);
    });

    it("burnAndCredit: sub-unit amount adds nothing to the credit", async () => {
      const subUnit = 10n ** 12n - 1n;
      const before = await bridge6.credits(alice.address);
      const mintedBefore = await bridge6.minted();
      await bridge6.burnAndCredit(alice.address, subUnit);
      expect(await bridge6.credits(alice.address)).to.equal(before);
      expect(await bridge6.minted()).to.equal(mintedBefore);
    });
  });

  describe("limit enforcement", () => {
    it("should revert with (zchfAmount, limit) when minting exceeds limit", async () => {
      const overLimit = LIMIT + 1n;
      const sourceAmount6 = overLimit / 10n ** 12n + 1n; // enough to exceed in 6 decimals
      const zchfAmount = sourceAmount6 * 10n ** 12n;
      await xchf6.mint(owner.address, sourceAmount6);
      await xchf6.approve(bridge6Addr, sourceAmount6);
      await expect(bridge6.mint(sourceAmount6))
        .to.be.revertedWithCustomError(bridge6, "Limit")
        .withArgs(zchfAmount, LIMIT);
    });
  });

  describe("expiration", () => {
    // After this block all subsequent tests run with the clock advanced past horizon.
    // Tests that need a fresh bridge (see "minted accounting") deploy after this point
    // and get a new horizon relative to the advanced timestamp.

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

    // The horizon is intentionally one-sided: redemptions of already-minted ZCHF must
    // remain possible after expiration so holders are never trapped.
    it("burn: should still work after horizon", async () => {
      const zchfAmount = ethers.parseEther("10");
      const expectedChf = 10n * 10n ** 6n;
      const tx = bridge6.burn(zchfAmount);
      await expect(tx).to.changeTokenBalance(zchf, owner, -zchfAmount);
      await expect(tx).to.changeTokenBalance(xchf6, owner, expectedChf);
    });

    it("burnAndSend: should still work after horizon", async () => {
      const zchfAmount = ethers.parseEther("5");
      const expectedChf = 5n * 10n ** 6n;
      const tx = bridge6.burnAndSend(alice.address, zchfAmount);
      await expect(tx).to.changeTokenBalance(zchf, owner, -zchfAmount);
      await expect(tx).to.changeTokenBalance(xchf6, alice, expectedChf);
    });

    it("burnAndCredit: should still work after horizon", async () => {
      const zchfAmount = ethers.parseEther("3");
      const expectedChf = 3n * 10n ** 6n;
      const before = await bridge6.credits(alice.address);
      await bridge6.burnAndCredit(alice.address, zchfAmount);
      expect(await bridge6.credits(alice.address)).to.equal(before + expectedChf);
    });

    it("payoutCredit: should still work after horizon", async () => {
      const credited = await bridge6.credits(alice.address);
      expect(credited).to.be.greaterThan(0n);
      const tx = bridge6.payoutCredit(alice.address);
      await expect(tx).to.changeTokenBalance(xchf6, alice, credited);
      expect(await bridge6.credits(alice.address)).to.equal(0);
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
