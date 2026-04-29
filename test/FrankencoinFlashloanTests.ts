import { expect } from "chai";
import { ethers } from "hardhat";
import {
  Equity,
  Frankencoin,
  FrankencoinFlashloan,
  MockFlashloanRecipient,
  ModuleRegistry,
} from "../typechain";
import { evm_increaseTime } from "./helper";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

// ── Mainnet addresses ────────────────────────────────────────────────────────

const ZCHF_ADDR = "0xB58E61C3098d85632Df34EecfB899A1Ed80921cB";
const ZCHF_WHALE = "0x9642b23Ed1E01Df1092B92641051881a322F5D4E";
const FORK_BLOCK = 24977371;

// ── Constants ────────────────────────────────────────────────────────────────

const DAY = 86400n;
const THIRTY_DAYS = 30n * DAY;
const PROPOSAL_FEE = ethers.parseEther("1000");
const LOAN_AMOUNT = ethers.parseEther("500000"); // 500k ZCHF

// ── Suite ────────────────────────────────────────────────────────────────────

describe("FrankencoinFlashloan", function () {
  let owner: HardhatEthersSigner;
  let alice: HardhatEthersSigner; // funds proposal fees
  let bob: HardhatEthersSigner; // permissionless accept caller
  let whale: HardhatEthersSigner; // impersonated ZCHF whale; FPS holder

  let zchf: Frankencoin;
  let equity: Equity;
  let registry: ModuleRegistry;
  let flashloan: FrankencoinFlashloan;
  let mock: MockFlashloanRecipient;

  // ── Global fork setup ──────────────────────────────────────────────────────

  before(async function () {
    [owner, alice, bob] = await ethers.getSigners();

    const alchemyKey = process.env.ALCHEMY_RPC_KEY;
    await ethers.provider.send("hardhat_reset", [
      {
        forking: {
          jsonRpcUrl: `https://eth-mainnet.g.alchemy.com/v2/${alchemyKey}`,
          blockNumber: FORK_BLOCK,
        },
      },
    ]);

    for (const s of [owner, alice, bob]) {
      await ethers.provider.send("hardhat_setBalance", [
        s.address,
        `0x${ethers.parseEther("10").toString(16)}`,
      ]);
    }

    await owner.sendTransaction({
      to: ZCHF_WHALE,
      value: ethers.parseEther("1"),
    });
    await ethers.provider.send("hardhat_impersonateAccount", [ZCHF_WHALE]);
    whale = await ethers.getSigner(ZCHF_WHALE);

    zchf = await ethers.getContractAt("Frankencoin", ZCHF_ADDR);
    equity = await ethers.getContractAt("Equity", await zchf.reserve());

    await zchf
      .connect(whale)
      .transfer(alice.address, ethers.parseEther("5000"));

    const investAmount = await zchf.balanceOf(ZCHF_WHALE);
    await equity.connect(whale).invest(investAmount, 0n);

    await evm_increaseTime(730n * DAY);

    const minFee = await zchf.MIN_FEE();
    const minPeriod = await zchf.MIN_APPLICATION_PERIOD();

    // Deploy ModuleRegistry and register it as the ZCHF minter
    registry = await ethers.deployContract("ModuleRegistry", [ZCHF_ADDR]);
    await zchf
      .connect(alice)
      .suggestMinter(
        await registry.getAddress(),
        minPeriod,
        minFee,
        "ModuleRegistry"
      );
    await evm_increaseTime(minPeriod + 1n);

    // Deploy FrankencoinFlashloan pointing at the registry
    flashloan = await ethers.deployContract("FrankencoinFlashloan", [
      await registry.getAddress(),
    ]);

    // Propose and accept FrankencoinFlashloan as a module in the registry
    const block = await ethers.provider.getBlock("latest");
    const moduleExpiry = BigInt(block!.timestamp) + THIRTY_DAYS + 3650n * DAY;
    await zchf
      .connect(alice)
      .approve(await registry.getAddress(), PROPOSAL_FEE);
    await registry
      .connect(alice)
      .propose(
        await flashloan.getAddress(),
        PROPOSAL_FEE,
        moduleExpiry,
        "FrankencoinFlashloan module"
      );
    await evm_increaseTime(THIRTY_DAYS + 1n);
    await registry.connect(bob).accept(await flashloan.getAddress());

    // Deploy the mock recipient wired to this flashloan contract
    mock = await ethers.deployContract("MockFlashloanRecipient", [
      await flashloan.getAddress(),
    ]);

    console.log("\n=== FrankencoinFlashloan fork setup ===");
    console.log("Block     :", FORK_BLOCK);
    console.log("Registry  :", await registry.getAddress());
    console.log("Flashloan :", await flashloan.getAddress());
    console.log("Mock      :", await mock.getAddress());
    console.log("ZCHF      :", ZCHF_ADDR);
    console.log(
      "Whale FPS :",
      ethers.formatEther(await equity.balanceOf(ZCHF_WHALE))
    );
  });

  after(async function () {
    await ethers.provider.send("hardhat_reset", []);
  });

  // ── Constructor ───────────────────────────────────────────────────────────

  describe("constructor", function () {
    it("registry reference is correct", async function () {
      expect(await flashloan.registry()).to.equal(await registry.getAddress());
    });

    it("zchf is derived from the registry", async function () {
      expect(await flashloan.zchf()).to.equal(ZCHF_ADDR);
    });

    it("flashloan contract is an active module in the registry", async function () {
      expect(await registry.isActive(await flashloan.getAddress())).to.be.true;
    });

    it("flashloan contract is NOT a direct ZCHF minter", async function () {
      expect(await zchf.isMinter(await flashloan.getAddress())).to.be.false;
    });

    it("mock recipient is wired to the flashloan contract", async function () {
      expect(await mock.flashloan()).to.equal(await flashloan.getAddress());
    });
  });

  // ── flashloan() guards ────────────────────────────────────────────────────

  describe("flashloan() guards", function () {
    it("reverts InvalidAmount when amount is zero", async function () {
      await expect(
        flashloan.connect(alice).flashloan(0, "0x")
      ).to.be.revertedWithCustomError(flashloan, "InvalidAmount");
    });

    it("reverts when caller does not implement the callback interface", async function () {
      // alice.address has no onFrankencoinFlashloan — call will revert
      await expect(flashloan.connect(alice).flashloan(LOAN_AMOUNT, "0x")).to.be
        .reverted;
    });
  });

  // ── Happy path ────────────────────────────────────────────────────────────

  describe("flashloan() — happy path via MockFlashloanRecipient", function () {
    it("emits Flashloan with correct recipient and amount", async function () {
      await expect(mock.connect(bob).trigger(LOAN_AMOUNT, "0x"))
        .to.emit(flashloan, "Flashloan")
        .withArgs(await mock.getAddress(), LOAN_AMOUNT);
    });

    it("mock's ZCHF balance is unchanged after the loan (net zero)", async function () {
      const balBefore = await zchf.balanceOf(await mock.getAddress());
      await mock.connect(bob).trigger(LOAN_AMOUNT, "0x");
      expect(await zchf.balanceOf(await mock.getAddress())).to.equal(balBefore);
    });

    it("emits FlashloanReceived from the mock callback", async function () {
      await expect(mock.connect(bob).trigger(LOAN_AMOUNT, "0xdeadbeef"))
        .to.emit(mock, "FlashloanReceived")
        .withArgs(await flashloan.getAddress(), LOAN_AMOUNT, "0xdeadbeef");
    });

    it("total ZCHF supply is unchanged after the loan", async function () {
      const supplyBefore = await zchf.totalSupply();
      await mock.connect(bob).trigger(LOAN_AMOUNT, "0x");
      expect(await zchf.totalSupply()).to.equal(supplyBefore);
    });

    it("loan can be taken multiple times in sequence", async function () {
      await expect(mock.connect(bob).trigger(LOAN_AMOUNT, "0x")).to.not.be
        .reverted;
      await expect(mock.connect(bob).trigger(LOAN_AMOUNT, "0x")).to.not.be
        .reverted;
    });
  });
});
