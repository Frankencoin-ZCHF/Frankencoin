import { expect } from "chai";
import { floatToDec18 } from "../scripts/math";
import { ethers } from "hardhat";
import {
  Equity,
  Frankencoin,
  MintingHub,
  Position,
  PositionFactory,
  PositionRoller,
  Savings,
  TestToken,
} from "../typechain";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { evm_increaseTime } from "./helper";
import { float } from "hardhat/internal/core/params/argumentTypes";

describe("Savings Tests", () => {
  let owner: HardhatEthersSigner;
  let alice: HardhatEthersSigner;
  let bob: HardhatEthersSigner;

  let zchf: Frankencoin;
  let equity: Equity;
  let roller: PositionRoller;
  let savings: Savings;

  let positionFactory: PositionFactory;
  let mintingHub: MintingHub;

  let position: Position;
  let coin: TestToken;

  const getTimeStamp = async () => {
    const blockNumBefore = await ethers.provider.getBlockNumber();
    const blockBefore = await ethers.provider.getBlock(blockNumBefore);
    return blockBefore?.timestamp ?? null;
  };

  beforeEach(async () => {
    [owner, alice, bob] = await ethers.getSigners();

    const frankenCoinFactory = await ethers.getContractFactory("Frankencoin");
    zchf = await frankenCoinFactory.deploy(10 * 86400);

    const equityAddr = await zchf.reserve();
    equity = await ethers.getContractAt("Equity", equityAddr);

    const positionFactoryFactory = await ethers.getContractFactory(
      "PositionFactory"
    );
    positionFactory = await positionFactoryFactory.deploy();

    const savingsFactory = await ethers.getContractFactory("Savings");
    savings = await savingsFactory.deploy(zchf.getAddress(), 20000n);

    const rollerFactory = await ethers.getContractFactory("PositionRoller");
    roller = await rollerFactory.deploy(zchf.getAddress());

    const mintingHubFactory = await ethers.getContractFactory("MintingHub");
    mintingHub = await mintingHubFactory.deploy(
      await zchf.getAddress(),
      await savings.getAddress(),
      await roller.getAddress(),
      await positionFactory.getAddress()
    );

    // jump start ecosystem
    await zchf.initialize(owner.address, "owner");
    await zchf.initialize(await mintingHub.getAddress(), "mintingHub");
    await zchf.initialize(await savings.getAddress(), "savings");

    await zchf.mint(owner.address, floatToDec18(2_000_000));
    await zchf.transfer(alice.address, floatToDec18(100_000));
    await zchf.transfer(bob.address, floatToDec18(100_000));

    // jump start fps
    await equity.invest(floatToDec18(1000), 0);
    await equity.connect(alice).invest(floatToDec18(10_000), 0);
    await equity.connect(bob).invest(floatToDec18(10_000), 0);
    await equity.invest(floatToDec18(1_000_000), 0);

    // test coin
    const coinFactory = await ethers.getContractFactory("TestToken");
    coin = await coinFactory.deploy("Supercoin", "XCOIN", 18);
  });

  const amount = floatToDec18(1000);

  describe("Save some zchf", () => {
    it("no approval needed, minters power", async () => {
      const amount = floatToDec18(1000);
      await savings["save(uint192)"](amount);
    });

    it("simple save", async () => {
      await zchf.approve(savings.getAddress(), amount); // not needed if registered as minter
      await savings["save(uint192)"](amount);
      const r = await savings.savings(owner.address);
      expect(r.saved).to.be.equal(amount);
    });

    it("multi save", async () => {
      await zchf.approve(savings.getAddress(), amount * 3n);
      await savings["save(uint192)"](amount);
      await savings["save(uint192)"](amount);
      await savings["save(uint192)"](amount);
      const r = await savings.savings(owner.address);
      expect(r.saved).to.be.equal(amount * 3n);
    });

    it("premature attempt to withdraw", async () => {
      await zchf.approve(savings.getAddress(), amount);
      await savings["save(uint192)"](amount);
      const w = savings.withdraw(owner.address, amount);
      await expect(w).to.be.revertedWithCustomError(savings, "FundsLocked");

      savings.connect(owner).refreshMyBalance();

      const w2 = savings.withdraw(owner.address, amount);
      await expect(w2).to.be.revertedWithCustomError(savings, "FundsLocked");
    });

    it("any interests after 365days", async () => {
      const i0 = await zchf.balanceOf(owner.address);
      const amount = floatToDec18(10_000);
      await zchf.approve(savings.getAddress(), amount);
      await savings["save(uint192)"](amount);
      await evm_increaseTime(365 * 86_400);
      await savings.withdraw(owner.address, 2n * amount); // as much as possible, 2x amount is enough
      /* \__ Will cause an Error, if not registered as minter. __/
        savings addr: 0xc351628EB244ec633d5f21fBD6621e1a683B1181
        equity addr: 0x1301d297043f564235EA41560f61681253BbD48B

        Error: VM Exception while processing transaction: reverted with custom error 'ERC20InsufficientAllowance("0x1301d297043f564235EA41560f61681253BbD48B", 0, 192328779807204464738)'
        at Frankencoin.permit (contracts/utils/ERC20PermitLight.sol:21)
        at Frankencoin.transferFrom (contracts/erc20/ERC20.sol:123)
        at Savings.refresh (contracts/Savings.sol:68)
        at Savings.withdraw (contracts/Savings.sol:109)

        The SC "Savings" is not a "minter" aka "no minter superpower". So it CAN NOT withdraw any zchf without approval, 
        this will cause an error while trying to "transferFrom" the equity some interests.
      */
      const i1 = await zchf.balanceOf(owner.address);
      expect(i1).to.be.greaterThan(i0);
    });

    it("correct interest after 365days (excl. 3days)", async () => {
      const i0 = await zchf.balanceOf(owner.address);
      const amount = floatToDec18(10_000);
      await zchf.approve(savings.getAddress(), amount);
      await savings["save(uint192)"](amount);
      const t0 = await getTimeStamp();

      await evm_increaseTime(365 * 86_400);

      await savings.withdraw(owner.address, 2n * amount);
      const t1 = await getTimeStamp();
      const i1 = await zchf.balanceOf(owner.address);
      const iDiff = i1 - i0;
      const tDiff = t1! - t0!;
      const toCheck =
        (floatToDec18(10_000) * 20000n * (BigInt(tDiff) - 3n * 86_400n)) /
        (365n * 86_400n * 1_000_000n);
      expect(iDiff).to.be.equal(toCheck);
    });

    it("correct interest after 1000days (excl. 14days)", async () => {
      const b0 = await zchf.balanceOf(owner.address);
      const amount = floatToDec18(10_000);
      await zchf.approve(savings.getAddress(), amount);
      await savings["save(uint192)"](amount);
      const t0 = await getTimeStamp();

      await evm_increaseTime(1000 * 86_400);

      await savings.withdraw(owner.address, 2n * amount);
      const t1 = await getTimeStamp();
      const b1 = await zchf.balanceOf(owner.address);
      const bDiff = b1 - b0;
      const tDiff = t1! - t0!;
      const toCheck =
        (floatToDec18(10_000) * 20000n * (BigInt(tDiff) - 3n * 86_400n)) /
        (365n * 86_400n * 1_000_000n);
      expect(bDiff).to.be.equal(toCheck);
    });

    it("approx. interest after 2x saves", async () => {
      const b0 = await zchf.balanceOf(owner.address);
      const amount = floatToDec18(10_000);
      await zchf.approve(savings.getAddress(), 2n * amount);

      await savings["save(uint192)"](amount);
      const t0 = await getTimeStamp();
      await evm_increaseTime(200 * 86_400);

      await savings["save(uint192)"](amount);
      const t1 = await getTimeStamp();
      await evm_increaseTime(200 * 86_400);

      await savings.withdraw(owner.address, 10n * amount);
      const t2 = await getTimeStamp();
      const b1 = await zchf.balanceOf(owner.address);
      const bDiff = b1 - b0;
      const tDiff0 = t1! - t0!;
      const tDiff1 = t2! - t1!;
      const toCheck0 =
        (floatToDec18(10_000) * 20000n * (BigInt(tDiff0) - 3n * 86_400n)) /
        (365n * 86_400n * 1_000_000n);
      const toCheck1 =
        ((floatToDec18(10_000) + toCheck0) *
          20000n *
          (BigInt(tDiff1) - 0n * 86_400n)) /
        (365n * 86_400n * 1_000_000n);
      const toCheck2 =
        (floatToDec18(10_000) * 20000n * (BigInt(tDiff1) - 3n * 86_400n)) /
        (365n * 86_400n * 1_000_000n);
      expect(bDiff).to.be.approximately(
        toCheck0 + toCheck1 + toCheck2,
        1_000_000_000n
      );
    });

    it("refresh my balance", async () => {
      const amount = floatToDec18(10_000);
      await zchf.approve(savings.getAddress(), amount);
      await savings["save(uint192)"](amount);
      const t0 = await getTimeStamp();

      await evm_increaseTime(365 * 86_400);

      await savings.refreshMyBalance();
      const t1 = await getTimeStamp();
      const tDiff = t1! - t0!;
      const toCheck =
        (floatToDec18(10_000) * 20000n * (BigInt(tDiff) - 3n * 86_400n)) /
        (365n * 86_400n * 1_000_000n);

      const r = await savings.savings(owner.address);
      expect(r.saved).to.be.equal(amount + toCheck);
    });

    it("refresh balance", async () => {
      const amount = floatToDec18(10_000);
      await zchf.approve(savings.getAddress(), amount);
      await savings["save(uint192)"](amount);
      const t0 = await getTimeStamp();

      await evm_increaseTime(365 * 86_400);

      await savings.refreshBalance(owner.address);
      const t1 = await getTimeStamp();
      const tDiff = t1! - t0!;
      const toCheck =
        (floatToDec18(10_000) * 20000n * (BigInt(tDiff) - 3n * 86_400n)) /
        (365n * 86_400n * 1_000_000n);

      const r = await savings.savings(owner.address);
      expect(r.saved).to.be.equal(amount + toCheck);
    });

    it("withdraw partial", async () => {
      const amount = floatToDec18(10_000);
      await zchf.approve(savings.getAddress(), amount);
      await savings["save(uint192)"](amount);
      const t0 = await getTimeStamp();

      await evm_increaseTime(365 * 86_400);

      await savings.withdraw(owner.address, amount / 10n);
      const t1 = await getTimeStamp();
      const tDiff = t1! - t0!;
      const toCheck =
        (floatToDec18(10_000) * 20000n * (BigInt(tDiff) - 3n * 86_400n)) /
        (365n * 86_400n * 1_000_000n);

      const r = await savings.savings(owner.address);
      expect(r.saved).to.be.equal((amount * 9n) / 10n + toCheck);
    });

    it("withdraw savings", async () => {
      await savings["save(uint192)"](4n * amount);
      const account = await savings.savings(owner.address);
      expect(account.saved).to.be.eq(4n * amount);
      const ticks = await savings.currentTicks();
      const timeLeft =
        (account.ticks - ticks) / (await savings.currentRatePPM());
      await evm_increaseTime(timeLeft - 1n); // when executing the next transaction, timer will be increased by 1 seconds
      const account2 = await savings.savings(owner.address);
      expect(account2.saved).to.be.eq(4n * amount);
      await savings.withdraw(owner.address, amount);
      await savings.refreshBalance(owner.address);
      await evm_increaseTime(1234);
      const oldBalance = (await savings.savings(owner.address)).saved;
      const oldReserve = await zchf.balanceOf(await zchf.reserve());
      const oldUserTicks = (await savings.savings(owner.address)).ticks;
      const oldSystemTicks = await savings.currentTicks();
      await savings.refreshBalance(owner.address);
      const newBalance = (await savings.savings(owner.address)).saved;
      const newReserve = await zchf.balanceOf(await zchf.reserve());
      const newUserTicks = (await savings.savings(owner.address)).ticks;
      const newSystemTicks = await savings.currentTicks();
      expect(newUserTicks).to.be.eq(newSystemTicks);
      expect(newBalance - oldBalance).to.be.eq(oldReserve - newReserve);
      expect(newBalance - oldBalance).to.be.eq(
        ((newUserTicks - oldUserTicks) * oldBalance) /
          1000000n /
          365n /
          24n /
          3600n
      );
      await savings.withdraw(owner.address, 10n * amount);
      await expect((await savings.savings(owner.address)).saved).to.be.eq(0n);
    });
  });
});
