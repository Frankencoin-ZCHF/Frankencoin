import { expect } from "chai";
import { floatToDec18, dec18ToFloat, DECIMALS } from "../scripts/math";
import { ethers } from "hardhat";
import { evm_increaseTime, evm_increaseTimeTo } from "./helper";
import {
  Equity,
  Frankencoin,
  MintingHub,
  Position,
  Savings,
  PositionRoller,
  StablecoinBridge,
  TestToken,
} from "../typechain";
import { PositionExpirationTest, PositionRollingTest } from "../typechain/test";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { time } from "@nomicfoundation/hardhat-network-helpers";


describe("Position Tests", () => {
  let owner: HardhatEthersSigner;
  let alice: HardhatEthersSigner;
  let bob: HardhatEthersSigner;
  let charles: HardhatEthersSigner;
  
  let zchf: Frankencoin;
  let mintingHub: MintingHub;
  let bridge: StablecoinBridge;
  let savings: Savings;
  let roller: PositionRoller;
  let equity: Equity;
  let mockVOL: TestToken;
  let mockXCHF: TestToken;

  let limit: bigint;

  before(async () => {
    [owner, alice, bob, charles] = await ethers.getSigners();
    // create contracts
    const frankenCoinFactory = await ethers.getContractFactory("Frankencoin");
    zchf = await frankenCoinFactory.deploy(10 * 86400);
    equity = await ethers.getContractAt("Equity", await zchf.reserve());

    const positionFactoryFactory = await ethers.getContractFactory(
      "PositionFactory"
    );
    const positionFactory = await positionFactoryFactory.deploy();

    const savingsFactory = await ethers.getContractFactory("Savings");
    savings = await savingsFactory.deploy(zchf.getAddress(), 0n);

    const rollerFactory = await ethers.getContractFactory("PositionRoller");
    roller = await rollerFactory.deploy(zchf.getAddress());

    const mintingHubFactory = await ethers.getContractFactory("MintingHub");
    mintingHub = await mintingHubFactory.deploy(
      await zchf.getAddress(),
      await savings.getAddress(),
      await roller.getAddress(),
      await positionFactory.getAddress()
    );

    // mocktoken
    const testTokenFactory = await ethers.getContractFactory("TestToken");
    mockXCHF = await testTokenFactory.deploy("CryptoFranc", "XCHF", 18);
    // mocktoken bridge to bootstrap
    limit = floatToDec18(1_000_000);
    const bridgeFactory = await ethers.getContractFactory("StablecoinBridge");
    bridge = await bridgeFactory.deploy(
      await mockXCHF.getAddress(),
      await zchf.getAddress(),
      limit
    );
    await zchf.initialize(await bridge.getAddress(), "XCHF Bridge");
    // create a minting hub too while we have no ZCHF supply
    await zchf.initialize(await mintingHub.getAddress(), "Minting Hub");
    await zchf.initialize(await savings.getAddress(), "Savings");
    await zchf.initialize(await roller.getAddress(), "Roller");

    // wait for 1 block
    await evm_increaseTime(60);
    // now we are ready to bootstrap ZCHF with Mock-XCHF
    await mockXCHF.mint(owner.address, limit / 3n);
    await mockXCHF.mint(alice.address, limit / 3n);
    await mockXCHF.mint(bob.address, limit / 3n);
    // mint some ZCHF to block bridges without veto
    let amount = floatToDec18(20_000);
    await mockXCHF.connect(alice).approve(await bridge.getAddress(), amount);
    await bridge.connect(alice).mint(amount);
    await mockXCHF.connect(owner).approve(await bridge.getAddress(), limit / 3n);
    await bridge.connect(owner).mint(limit / 3n); // owner should have plenty
    await mockXCHF.connect(bob).approve(await bridge.getAddress(), amount);
    await bridge.connect(bob).mint(amount);
    // vol tokens
    mockVOL = await testTokenFactory.deploy("Volatile Token", "VOL", 18);
    amount = floatToDec18(500_000);
    await mockVOL.mint(owner.address, amount);
    await mockVOL.mint(alice.address, amount);
    await mockVOL.mint(bob.address, amount);
  });

  let positionAddr: string, positionContract: Position;
  let clonePositionAddr: string, clonePositionContract: Position;
  let fee = 0.01;
  let reserve = 0.1;
  let mintAmount = 100;
  let initialLimit = floatToDec18(550_000);
  let fMintAmount = floatToDec18(mintAmount);
  let fLimit;
  let fGlblZCHBalanceOfCloner: bigint;
  let initialCollateral = 110;
  let initialCollateralClone = 4;
  let challengeAmount = 0;
  let challengeNumber = 0;

  describe("Use Minting Hub", () => {
    let collateral: string;
    let fliqPrice = floatToDec18(5000);
    let minCollateral = floatToDec18(1);
    let fInitialCollateral = floatToDec18(initialCollateral);
    let duration = 60n * 86_400n;
    let fFees = BigInt(fee * 1_000_000);
    let fReserve = BigInt(reserve * 1_000_000);
    let challengePeriod = BigInt(3 * 86400); // 3 days

    before(async () => {
      collateral = await mockVOL.getAddress();
    });

    it("should revert position opening when initial period is less than 3 days", async () => {
      await mockVOL
        .connect(owner)
        .approve(await mintingHub.getAddress(), fInitialCollateral);
      await expect(
        mintingHub.openPosition(
          collateral,
          minCollateral,
          fInitialCollateral,
          initialLimit,
          86400 * 2,
          duration,
          challengePeriod,
          fFees,
          fliqPrice,
          fReserve
        )
      ).to.be.revertedWithoutReason();
    });
    it("should revert creating position when annual interest is less than 1M PPM", async () => {
      await expect(
        mintingHub.openPosition(
          collateral,
          minCollateral,
          fInitialCollateral,
          initialLimit,
          86400 * 2,
          duration,
          challengePeriod,
          2 * 1_000_000,
          fliqPrice,
          fReserve
        )
      ).to.be.revertedWithoutReason();
    });
    it("should revert creating position when reserve fee is less than 1M PPM", async () => {
      await expect(
        mintingHub.openPosition(
          collateral,
          minCollateral,
          fInitialCollateral,
          initialLimit,
          86400 * 2,
          duration,
          challengePeriod,
          fFees,
          fliqPrice,
          2 * 1_000_000
        )
      ).to.be.revertedWithoutReason();
    });
    it("should revert creating position when initial collateral is less than minimal", async () => {
      await expect(
        mintingHub.openPosition(
          collateral,
          minCollateral,
          minCollateral / 2n,
          initialLimit,
          86400 * 2,
          duration,
          challengePeriod,
          fFees,
          fliqPrice,
          fReserve
        )
      ).to.be.revertedWithCustomError(mintingHub, "InsufficientCollateral");
    });
    it("should revert creating position when minimal collateral is not worth of at least 5k ZCHF", async () => {
      await expect(
        mintingHub.openPosition(
          collateral,
          minCollateral,
          fInitialCollateral,
          initialLimit,
          86400 * 2,
          duration,
          challengePeriod,
          fFees,
          floatToDec18(4000),
          fReserve
        )
      ).to.be.revertedWithCustomError(mintingHub, "InsufficientCollateral");
    });
    it("should revert creating position when collateral token has more than 24 decimals", async () => {
      const testTokenFactory = await ethers.getContractFactory("TestToken");
      const testToken = await testTokenFactory.deploy("Test", "Test", 25);
      await expect(
        mintingHub.openPosition(
          await testToken.getAddress(),
          minCollateral,
          fInitialCollateral,
          initialLimit,
          86400 * 2,
          duration,
          challengePeriod,
          fFees,
          floatToDec18(4000),
          fReserve
        )
      ).to.be.revertedWithoutReason();
    });
    it("should revert creating position when collateral token does not revert on error", async () => {
      const testTokenFactory = await ethers.getContractFactory("FreakToken");
      const testToken = await testTokenFactory.deploy("Test", "Test", 17);
      await expect(
        mintingHub.openPosition(
          await testToken.getAddress(),
          minCollateral,
          fInitialCollateral,
          initialLimit,
          86400 * 2,
          duration,
          challengePeriod,
          fFees,
          floatToDec18(4000),
          fReserve
        )
      ).to.be.revertedWithCustomError(mintingHub, "IncompatibleCollateral");
    });
    it("create position", async () => {
      let openingFeeZCHF = await mintingHub.OPENING_FEE();
      await mockVOL.approve(await mintingHub.getAddress(), fInitialCollateral);
      let balBefore = await zchf.balanceOf(owner.address);
      let balBeforeVOL = await mockVOL.balanceOf(owner.address);
      let tx = await mintingHub.openPosition(
        collateral,
        minCollateral,
        fInitialCollateral,
        initialLimit,
        7n * 24n * 3600n,
        duration,
        challengePeriod,
        fFees,
        fliqPrice,
        fReserve
      );
      let rc = await tx.wait();
      const topic =
        "0xc9b570ab9d98bdf3e38a40fd71b20edafca42449f23ca51f0bdcbf40e8ffe175"; // PositionOpened
      const log = rc?.logs.find((x) => x.topics.indexOf(topic) >= 0);
      positionAddr = "0x" + log?.topics[2].substring(26);
      positionContract = await ethers.getContractAt(
        "Position",
        positionAddr,
        owner
      );
      let balAfter = await zchf.balanceOf(owner.address);
      let balAfterVOL = await mockVOL.balanceOf(owner.address);
      let dZCHF = dec18ToFloat(balAfter - balBefore);
      let dVOL = dec18ToFloat(balAfterVOL - balBeforeVOL);
      expect(dVOL).to.be.equal(-initialCollateral);
      expect(dZCHF).to.be.equal(-dec18ToFloat(openingFeeZCHF));
      let currentFees = await positionContract.calculateCurrentFee();
      expect(currentFees).to.be.eq(1643);
    });
    it("require cooldown", async () => {
      let tx = positionContract
        .connect(owner)
        .mint(owner.address, floatToDec18(5));
      await expect(tx).to.be.revertedWithCustomError(positionContract, "Hot");
    });
    it("should revert minting from non owner", async () => {
      await expect(
        positionContract.connect(alice).mint(owner.address, 100)
      ).to.be.revertedWithCustomError(positionContract, "NotOwner");
    });
    it("should revert minting when there is a challange", async () => {
      await mockVOL.approve(await mintingHub.getAddress(), fInitialCollateral);
      let tx = await mintingHub.openPosition(
        collateral,
        minCollateral,
        fInitialCollateral,
        initialLimit,
        7n * 24n * 3600n,
        duration,
        challengePeriod,
        fFees,
        fliqPrice,
        fReserve
      );
      let rc = await tx.wait();
      const topic =
        "0xc9b570ab9d98bdf3e38a40fd71b20edafca42449f23ca51f0bdcbf40e8ffe175"; // PositionOpened
      const log = rc?.logs.find((x) => x.topics.indexOf(topic) >= 0);
      const positionAddr = "0x" + log?.topics[2].substring(26);
      const positionContract = await ethers.getContractAt(
        "Position",
        positionAddr,
        owner
      );
      challengeAmount = initialCollateralClone / 2;
      let fchallengeAmount = floatToDec18(challengeAmount);
      let price = await positionContract.price();
      await mockVOL.approve(await mintingHub.getAddress(), fchallengeAmount);
      await mintingHub.challenge(
        await positionContract.getAddress(),
        fchallengeAmount,
        price
      );
      await expect(
        positionContract.mint(owner.address, floatToDec18(10))
      ).to.be.revertedWithCustomError(positionContract, "Challenged");
    });
    it("try clone after 7 days but before collateral was withdrawn", async () => {
      // "wait" 7 days...
      await evm_increaseTime(7 * 86_400 + 60);

      let fInitialCollateralClone = floatToDec18(initialCollateralClone);
      let fZCHFAmount = floatToDec18(1000);
      // send some collateral and ZCHF to the cloner
      await mockVOL.transfer(alice.address, fInitialCollateralClone);
      await zchf.transfer(alice.address, fZCHFAmount);

      await mockVOL
        .connect(alice)
        .approve(await mintingHub.getAddress(), fInitialCollateralClone);
      fGlblZCHBalanceOfCloner = await zchf.balanceOf(alice.address);

      let expiration = await positionContract.expiration();
      let availableLimit = await positionContract.availableForClones();
      expect(availableLimit).to.be.equal(0);
      let tx = mintingHub
        .connect(alice)
        .clone(positionAddr, fInitialCollateralClone, fMintAmount, expiration);
      await expect(tx).to.be.revertedWithCustomError(
        positionContract,
        "LimitExceeded"
      );

      let colbal1 = await mockVOL.balanceOf(positionAddr);
      await positionContract
        .connect(owner)
        .withdrawCollateral(owner.address, floatToDec18(100)); // make sure it works the next time
      let colbal2 = await mockVOL.balanceOf(positionAddr);
      expect(dec18ToFloat(colbal1)).to.be.equal(dec18ToFloat(colbal2) + 100n);
      let availableLimit2 = await positionContract.availableForMinting();
      expect(availableLimit2).to.be.greaterThan(availableLimit);
    });
    it("get loan", async () => {
      await evm_increaseTime(7 * 86_400); // 14 days passed in total

      fLimit = await positionContract.limit();
      limit = dec18ToFloat(fLimit);
      let amount = BigInt(1e18) * 10_000n;
      expect(amount).to.be.lessThan(fLimit);
      let fZCHFBefore = await zchf.balanceOf(owner.address);
      let targetAmount = BigInt(1e16) * 898548n;
      let totalMint = (await positionContract.getMintAmount(targetAmount));
      let expectedAmount = await positionContract.getUsableMint(
        totalMint,
        true
      );
      for (let testTarget = 0n; testTarget < 100n; testTarget++) {
        // make sure these functions are not susceptible to rounding errors
        let testTotal = (await positionContract.getMintAmount(targetAmount + testTarget));
        let testExpected = await positionContract.getUsableMint(
          testTotal,
          true
        );
        expect(testExpected).to.be.eq(targetAmount + testTarget);
      }

      expect(await positionContract.getUsableMint(amount, false)).to.be.equal(
        9000n * BigInt(1e18)
      );

      await positionContract.connect(owner).mint(owner.address, amount); //).to.emit("PositionOpened");
      let currentFees = await positionContract.calculateCurrentFee();
      expect(currentFees).to.be.eq(1452n); // 53 days of a 1% yearly interest

      let fZCHFAfter = await zchf.balanceOf(owner.address);
      let ZCHFMinted = fZCHFAfter - fZCHFBefore;
      expect(expectedAmount).to.be.equal(ZCHFMinted);
    });
    it("should revert cloning for invalid position", async () => {
      let fInitialCollateralClone = floatToDec18(initialCollateralClone);
      fGlblZCHBalanceOfCloner = await zchf.balanceOf(alice.address);

      let start = await positionContract.start();
      let expiration = await positionContract.expiration();
      let duration = (expiration - start) / 2n;
      let newExpiration = expiration - duration;
      await expect(
        mintingHub
          .connect(alice)
          .clone(
            owner.address,
            fInitialCollateralClone,
            fMintAmount,
            newExpiration
          )
      ).to.be.revertedWithCustomError(mintingHub, "InvalidPos");
    });
    it("should revert cloning when new expiration is greater than original one", async () => {
      let fInitialCollateralClone = floatToDec18(initialCollateralClone);
      fGlblZCHBalanceOfCloner = await zchf.balanceOf(alice.address);

      let expiration = await positionContract.expiration();
      await expect(
        mintingHub
          .connect(alice)
          .clone(
            positionAddr,
            fInitialCollateralClone,
            fMintAmount,
            expiration + 100n
          )
      ).to.be.revertedWithCustomError(
        positionContract,
        "InvalidExpiration"
      );
    });
    it("should revert initializing again", async () => {
      await expect(
        positionContract.initialize(positionAddr, 0)
      ).to.be.revertedWithCustomError(positionContract, "NotHub");
    });
    it("should revert cloning position with insufficient initial collateral", async () => {
      let expiration = await positionContract.expiration();
      await expect(
        mintingHub
          .connect(alice)
          .clone(positionAddr, 0, 0, expiration)
      ).to.be.revertedWithCustomError(mintingHub, "InsufficientCollateral");
    });
    it("clone position", async () => {
      let fInitialCollateralClone = floatToDec18(initialCollateralClone);
      fGlblZCHBalanceOfCloner = await zchf.balanceOf(alice.address);

      let fees = await positionContract.calculateCurrentFee();
      const timestamp1 = BigInt(await time.latest());
      let start = await positionContract.start();
      let expiration = await positionContract.expiration();
      let duration = (expiration - start) / 2n;
      let newExpiration = expiration - duration;
      let tx = await mintingHub
        .connect(alice)
        .clone(
          positionAddr,
          fInitialCollateralClone,
          fMintAmount,
          newExpiration
        );
      let rc = await tx.wait();
      const topic =
        "0xc9b570ab9d98bdf3e38a40fd71b20edafca42449f23ca51f0bdcbf40e8ffe175"; // PositionOpened
      const log = rc?.logs.find((x) => x.topics.indexOf(topic) >= 0);
      clonePositionAddr = "0x" + log?.topics[2].substring(26);
      clonePositionContract = await ethers.getContractAt(
        "Position",
        clonePositionAddr,
        alice
      );
      let newStart = await clonePositionContract.start();
      let newExpirationActual = await clonePositionContract.expiration();
      expect(newExpirationActual).to.be.eq(newExpiration);
      let newFees = await clonePositionContract.calculateCurrentFee();
      const timestamp2 = BigInt(await time.latest());
      expect(
        (fees * (newExpiration - timestamp2)) / (expiration - timestamp1)
      ).to.be.approximately(newFees, 1);
    });
    it("correct collateral", async () => {
      let col = await mockVOL.balanceOf(clonePositionAddr);
      expect(col).to.be.equal(floatToDec18(initialCollateralClone));
    });
    it("global mint limit V2024", async () => {
      const pgl = await positionContract.limit();
      const cgl = await clonePositionContract.limit();
      expect(pgl).to.be.equal(cgl);
    });

    it("global mint limit retained", async () => {
      let fLimit0 = await clonePositionContract.availableForMinting();
      let fLimit1 = await positionContract.availableForClones();
      if (fLimit0 != fLimit1) {
        console.log("new global limit =", fLimit0);
        console.log("original global limit =", fLimit1);
      }
      expect(fLimit0).to.be.equal(fLimit1);

      await expect(
        clonePositionContract.mint(owner.address, fLimit0 + 100n)
      ).to.be.revertedWithCustomError(clonePositionContract, "LimitExceeded");
    });
    it("correct fees charged", async () => {
      // fees:
      // - reserve contribution (temporary fee)
      // - yearlyInterestPPM
      // - position fee (or clone fee)
      let reserveContributionPPM =
        await clonePositionContract.reserveContribution();
      let yearlyInterestPPM = await clonePositionContract.annualInterestPPM();

      let fBalanceAfter = await zchf.balanceOf(alice.address);
      let mintAfterFees =
        (BigInt(mintAmount) *
          (1000_000n -
            (28n * yearlyInterestPPM) / 365n -
            reserveContributionPPM)) /
        1000_000n;
      let cloneFeeCharged =
        fBalanceAfter - fGlblZCHBalanceOfCloner - mintAfterFees * BigInt(1e18);
      expect(cloneFeeCharged).to.be.approximately(0, BigInt(1e18)); // no extra fees when cloning
    });
    it("clone position with too much mint", async () => {
      let fInitialCollateralClone = floatToDec18(initialCollateralClone);
      let fZCHFAmount = floatToDec18(1000);
      // send some collateral and ZCHF to the cloner
      await mockVOL.mint(alice.address, fInitialCollateralClone * 1000n);
      await zchf.transfer(alice.address, fZCHFAmount);

      const expiration = await positionContract.expiration();
      await mockVOL
        .connect(alice)
        .approve(
          await mintingHub.getAddress(),
          fInitialCollateralClone * 1000n
        );
      fGlblZCHBalanceOfCloner = await zchf.balanceOf(alice.address);
      let available = await positionContract.availableForClones();
      let price = await positionContract.price();
      let tx = mintingHub
        .connect(alice)
        .clone(positionAddr, fInitialCollateralClone, available, expiration);
      await expect(tx).to.be.revertedWithCustomError(
        positionContract,
        "InsufficientCollateral"
      );

      let pendingTx = mintingHub
        .connect(alice)
        .clone(
          positionAddr,
          fInitialCollateralClone * 1000n,
          initialLimit,
          expiration
        );
      await expect(pendingTx).to.be.revertedWithCustomError(
        positionContract,
        "LimitExceeded"
      );
    });
    it("repay position", async () => {
      let cloneOwner = await clonePositionContract.connect(alice).owner();
      expect(cloneOwner).to.be.eq(alice.address);
      let fInitialCollateralClone = floatToDec18(initialCollateralClone);
      let withdrawTx = clonePositionContract.withdrawCollateral(
        cloneOwner,
        fInitialCollateralClone
      );
      await expect(withdrawTx).to.be.revertedWithCustomError(
        clonePositionContract,
        "InsufficientCollateral"
      );

      let minted = await clonePositionContract.minted();
      let reservePPM = await clonePositionContract.reserveContribution();
      let repayAmount = minted - (minted * reservePPM) / 1000000n;
      let reserve = await zchf.calculateAssignedReserve(minted, reservePPM);
      expect(reserve + repayAmount).to.be.eq(minted);

      await clonePositionContract.repay(repayAmount - reserve);
      let minted1 = await clonePositionContract.minted();
      let reserve1 = await zchf.calculateAssignedReserve(minted1, reservePPM);
      let repayAmount1 = minted1 - reserve1;
      await clonePositionContract.repay(repayAmount1);
      await clonePositionContract.withdrawCollateral(
        cloneOwner,
        fInitialCollateralClone
      );
      let result = await clonePositionContract.isClosed();
      await expect(result).to.be.true;
    });
    it("should revert minting when the position is expired", async () => {
      await evm_increaseTime(86400 * 61);
      await expect(
        positionContract.mint(owner.address, floatToDec18(10))
      ).to.be.revertedWithCustomError(positionContract, "Expired");
    });
    it("should revert on price adjustments when expired", async () => {
      let currentPrice = await positionContract.price();
      await expect(
        positionContract.adjustPrice(currentPrice / 2n)
      ).to.be.revertedWithCustomError(positionContract, "Expired");
    });
    it("should revert on price adjustments when expired", async () => {
      let currentPrice = await positionContract.price();
      let minted = await positionContract.minted();
      let collateralBalance = await mockVOL.balanceOf(positionAddr);
      await positionContract.adjust(minted, collateralBalance, currentPrice); // don't revert if price is the same
      await expect(
        positionContract.adjust(minted, collateralBalance, currentPrice / 2n)
      ).to.be.revertedWithCustomError(positionContract, "Expired");
    });
    it("should revert reducing limit from non hub", async () => {
      await mockVOL.approve(await mintingHub.getAddress(), fInitialCollateral);
      let tx = await mintingHub.openPosition(
        collateral,
        minCollateral,
        fInitialCollateral,
        initialLimit,
        7n * 24n * 3600n,
        duration,
        challengePeriod,
        fFees,
        fliqPrice,
        fReserve
      );
      let rc = await tx.wait();
      const topic =
        "0xc9b570ab9d98bdf3e38a40fd71b20edafca42449f23ca51f0bdcbf40e8ffe175"; // PositionOpened
      const log = rc?.logs.find((x) => x.topics.indexOf(topic) >= 0);
      positionAddr = "0x" + log?.topics[2].substring(26);
      positionContract = await ethers.getContractAt(
        "Position",
        positionAddr,
        owner
      );
      await expect(
        positionContract.assertCloneable()
      ).to.be.revertedWithCustomError(positionContract, "Hot");
      await evm_increaseTime(86400 * 7);
      await positionContract.assertCloneable();
      await expect(
        positionContract.notifyMint(0)
      ).to.be.revertedWithCustomError(positionContract, "NotHub");
      await expect(
        positionContract.notifyRepaid(0)
      ).to.be.revertedWithCustomError(positionContract, "NotHub");
    });
    it("should revert cloning when it is expired", async () => async () => {
      await evm_increaseTime(86400 * 61);
      let fInitialCollateralClone = floatToDec18(initialCollateralClone);
      fGlblZCHBalanceOfCloner = await zchf.balanceOf(alice.address);
      let expiration = await positionContract.expiration();

      await expect(
        mintingHub
          .connect(alice)
          .clone(positionAddr, fInitialCollateralClone, fMintAmount, expiration)
      ).to.be.revertedWithCustomError(positionContract, "Expired");
    });
    it("should revert reducing limit when there is a challenge", async () => {
      challengeAmount = initialCollateralClone / 2;
      let fchallengeAmount = floatToDec18(challengeAmount);
      let price = await positionContract.price();
      await mockVOL.approve(await mintingHub.getAddress(), fchallengeAmount);
      await mintingHub.challenge(positionAddr, fchallengeAmount, price);
      challengeNumber++;
      await expect(
        positionContract.assertCloneable()
      ).to.be.revertedWithCustomError(positionContract, "Challenged");
    });
  });
  describe("denying position", () => {
    it("create position", async () => {
      let collateral = await mockVOL.getAddress();
      let fliqPrice = floatToDec18(5000);
      let minCollateral = floatToDec18(1);
      let fInitialCollateral = floatToDec18(initialCollateral);
      let duration = BigInt(60 * 86_400);
      let fFees = BigInt(fee * 1_000_000);
      let fReserve = BigInt(reserve * 1_000_000);
      let openingFeeZCHF = await mintingHub.OPENING_FEE();
      let challengePeriod = BigInt(3 * 86400); // 3 days
      await mockVOL
        .connect(owner)
        .approve(await mintingHub.getAddress(), fInitialCollateral);
      let balBefore = await zchf.balanceOf(owner.address);
      let balBeforeVOL = await mockVOL.balanceOf(owner.address);
      let tx = await mintingHub.openPosition(
        collateral,
        minCollateral,
        fInitialCollateral,
        initialLimit,
        7n * 24n * 3600n,
        duration,
        challengePeriod,
        fFees,
        fliqPrice,
        fReserve
      );
      let rc = await tx.wait();
      const topic =
        "0xc9b570ab9d98bdf3e38a40fd71b20edafca42449f23ca51f0bdcbf40e8ffe175"; // PositionOpened
      const log = rc?.logs.find((x) => x.topics.indexOf(topic) >= 0);
      positionAddr = "0x" + log?.topics[2].substring(26);
      let balAfter = await zchf.balanceOf(owner.address);
      let balAfterVOL = await mockVOL.balanceOf(owner.address);
      let dZCHF = dec18ToFloat(balAfter - balBefore);
      let dVOL = dec18ToFloat(balAfterVOL - balBeforeVOL);
      expect(dVOL).to.be.equal(BigInt(-initialCollateral));
      expect(dZCHF).to.be.equal(-dec18ToFloat(openingFeeZCHF));
      positionContract = await ethers.getContractAt(
        "Position",
        positionAddr,
        owner
      );
      let currentFees = await positionContract.calculateCurrentFee();
      expect(currentFees).to.be.eq(1643);
    });
    it("deny challenge", async () => {
      expect(positionContract.deny([], "")).to.be.emit(
        positionContract,
        "PositionDenied"
      );
    });
    it("should revert denying challenge when challenge started", async () => {
      await evm_increaseTime(86400 * 8);
      await expect(positionContract.deny([], "")).to.be.revertedWithCustomError(
        positionContract,
        "TooLate"
      );
    });
  });
  describe("challenge active", () => {
    it("create position", async () => {
      let collateral = await mockVOL.getAddress();
      let fliqPrice = floatToDec18(5000);
      let minCollateral = floatToDec18(1);
      let fInitialCollateral = floatToDec18(initialCollateral);
      let duration = BigInt(60 * 86_400);
      let fFees = BigInt(fee * 1_000_000);
      let fReserve = BigInt(reserve * 1_000_000);
      let openingFeeZCHF = await mintingHub.OPENING_FEE();
      let challengePeriod = BigInt(3 * 86400); // 3 days
      await mockVOL
        .connect(owner)
        .approve(await mintingHub.getAddress(), fInitialCollateral);
      let balBefore = await zchf.balanceOf(owner.address);
      let balBeforeVOL = await mockVOL.balanceOf(owner.address);
      let tx = await mintingHub.openPosition(
        collateral,
        minCollateral,
        fInitialCollateral,
        initialLimit,
        7n * 24n * 3600n,
        duration,
        challengePeriod,
        fFees,
        fliqPrice,
        fReserve
      );
      let rc = await tx.wait();
      const topic =
        "0xc9b570ab9d98bdf3e38a40fd71b20edafca42449f23ca51f0bdcbf40e8ffe175"; // PositionOpened
      const log = rc?.logs.find((x) => x.topics.indexOf(topic) >= 0);
      positionAddr = "0x" + log?.topics[2].substring(26);
      let balAfter = await zchf.balanceOf(owner.address);
      let balAfterVOL = await mockVOL.balanceOf(owner.address);
      let dZCHF = dec18ToFloat(balAfter - balBefore);
      let dVOL = dec18ToFloat(balAfterVOL - balBeforeVOL);
      expect(dVOL).to.be.equal(BigInt(-initialCollateral));
      expect(dZCHF).to.be.equal(-dec18ToFloat(openingFeeZCHF));
      positionContract = await ethers.getContractAt(
        "Position",
        positionAddr,
        owner
      );
    });
    it("should revert challenging from non minting hub address", async () => {
      challengeAmount = initialCollateralClone / 2;
      let fchallengeAmount = floatToDec18(challengeAmount);
      await expect(
        positionContract.notifyChallengeStarted(fchallengeAmount)
      ).to.be.revertedWithCustomError(positionContract, "NotHub");
    });
    it("should revert challenging with zero collateral", async () => {
      let price = await positionContract.price();
      await expect(
        mintingHub.challenge(positionAddr, 0, price)
      ).to.be.revertedWithCustomError(positionContract, "ChallengeTooSmall");
    });
    it("should revert challenging for invalid position address", async () => {
      challengeAmount = initialCollateralClone / 2;
      let fchallengeAmount = floatToDec18(challengeAmount);
      let price = await positionContract.price();
      await expect(
        mintingHub.challenge(owner.address, fchallengeAmount, price)
      ).to.be.revertedWithCustomError(mintingHub, "InvalidPos");
    });
    it("should revert challenging with different position price", async () => {
      challengeAmount = initialCollateralClone / 2;
      let fchallengeAmount = floatToDec18(challengeAmount);
      let price = await positionContract.price();
      await expect(
        mintingHub.challenge(positionAddr, fchallengeAmount, price + 100n)
      ).to.be.revertedWithCustomError(mintingHub, "UnexpectedPrice");
    });
    it("should revert challenging zero amount or less than minimal collateral", async () => {
      let price = await positionContract.price();
      await mockVOL.approve(await mintingHub.getAddress(), floatToDec18(0.1));

      await expect(
        mintingHub.challenge(positionAddr, 0, price)
      ).to.be.revertedWithCustomError(positionContract, "ChallengeTooSmall");
      await expect(
        mintingHub.challenge(positionAddr, floatToDec18(0.1), price)
      ).to.be.revertedWithCustomError(positionContract, "ChallengeTooSmall");
    });
    it("bid on challenged, flat sale, not expired position", async () => {
      challengeAmount = initialCollateralClone / 2;
      const fchallengeAmount = floatToDec18(challengeAmount);
      const price = await positionContract.price();
      await mockVOL.approve(await mintingHub.getAddress(), fchallengeAmount);
      let tx = await mintingHub.challenge(
        positionAddr,
        fchallengeAmount,
        price
      );
      challengeNumber++;
      const challenge = await mintingHub.challenges(challengeNumber);
      const challengerAddress = challenge.challenger;
      const challengeData = await positionContract.challengeData();

      // Flat sale
      await evm_increaseTime(challengeData.phase / 2n);
      let liqPrice = await mintingHub.price(challengeNumber);
      expect(liqPrice).to.be.equal(price);

      const bidSize = floatToDec18(challengeAmount / 4);
      let bidAmountZCHF = (liqPrice * bidSize) / DECIMALS;
      let balanceBeforeBob = await zchf.balanceOf(bob.address);
      let balanceBeforeChallenger = await zchf.balanceOf(challengerAddress);
      let volBalanceBefore = await mockVOL.balanceOf(bob.address);

      tx = await mintingHub.connect(bob).bid(challengeNumber, bidSize, false);
      await expect(tx).to.emit(mintingHub, "ChallengeAverted");
      let balanceAfterChallenger = await zchf.balanceOf(challengerAddress);
      let balanceAfterBob = await zchf.balanceOf(bob.address);
      let volBalanceAfter = await mockVOL.balanceOf(bob.address);

      expect(volBalanceAfter - volBalanceBefore).to.be.eq(bidSize);
      expect(balanceBeforeBob - balanceAfterBob).to.be.equal(bidAmountZCHF);
      expect(balanceAfterChallenger - balanceBeforeChallenger).to.be.equal(
        bidAmountZCHF
      );

      // Self bidding, should reduce challenge size
      balanceBeforeChallenger = await zchf.balanceOf(challengerAddress);
      volBalanceBefore = await mockVOL.balanceOf(challengerAddress);

      let updatedChallenge = await mintingHub.challenges(challengeNumber);
      await mintingHub.bid(challengeNumber, updatedChallenge.size, true);

      balanceAfterChallenger = await zchf.balanceOf(challengerAddress);
      volBalanceAfter = await mockVOL.balanceOf(challengerAddress);
      expect(balanceAfterChallenger).to.be.equal(balanceBeforeChallenger);
    });
    it("bid on challenged, auction sale, not expired position", async () => {
      challengeAmount = initialCollateralClone / 2;
      const fchallengeAmount = floatToDec18(challengeAmount);
      const price = await positionContract.price();
      await mockVOL
        .connect(charles)
        .approve(await mintingHub.getAddress(), fchallengeAmount);
      await mockVOL.connect(charles).mint(charles.address, fchallengeAmount);
      let tx = await mintingHub
        .connect(charles)
        .challenge(positionAddr, fchallengeAmount, price);
      challengeNumber++;
      const challenge = await mintingHub.challenges(challengeNumber);
      const challengeData = await positionContract.challengeData();

      // Auction sale
      await evm_increaseTime(challengeData.phase + challengeData.phase / 2n);
      let liqPrice = await positionContract.price();
      let auctionPrice = await mintingHub.price(challengeNumber);
      expect(auctionPrice).to.be.approximately(
        liqPrice / 2n,
        auctionPrice / 100n
      );

      const bidSize = floatToDec18(challengeAmount / 4);
      await mockVOL.mint(challenge.position, floatToDec18(challengeAmount / 2));
      let availableCollateral = await mockVOL.balanceOf(challenge.position);
      expect(availableCollateral).to.be.above(bidSize);

      // bob sends a bid
      let bidAmountZCHF = (auctionPrice * bidSize) / DECIMALS;
      let challengerAddress = challenge.challenger;
      await zchf.transfer(bob.address, bidAmountZCHF);
      let balanceBeforeBob = await zchf.balanceOf(bob.address);
      let balanceBeforeChallenger = await zchf.balanceOf(challengerAddress);
      let volBalanceBefore = await mockVOL.balanceOf(bob.address);
      tx = await mintingHub.connect(bob).bid(challengeNumber, bidSize, true);
      await expect(tx)
        .to.emit(mintingHub, "ChallengeSucceeded")
        .emit(zchf, "Profit");

      let balanceAfterChallenger = await zchf.balanceOf(challengerAddress);
      let balanceAfterBob = await zchf.balanceOf(bob.address);
      let volBalanceAfter = await mockVOL.balanceOf(bob.address);
      expect(volBalanceAfter - volBalanceBefore).to.be.eq(bidSize);
      expect(balanceBeforeBob - balanceAfterBob).to.be.approximately(
        bidAmountZCHF,
        bidAmountZCHF / 100n
      );
      expect(
        balanceAfterChallenger - balanceBeforeChallenger
      ).to.be.approximately(bidAmountZCHF / 50n, bidAmountZCHF / 5000n);

      bidAmountZCHF = bidAmountZCHF * 2n;
      await zchf.transfer(alice.address, bidAmountZCHF);
      await expect(
        mintingHub
          .connect(alice)
          .bid(challengeNumber, challenge.size * 2n, true)
      ).to.be.emit(mintingHub, "PostPonedReturn");
    });
  });
  describe("challenge clone", () => {

    let cloneContract: Position;

    beforeEach(async () => {
      let collateral = await mockVOL.getAddress();
      let fliqPrice = floatToDec18(5000);
      let minCollateral = floatToDec18(1);
      let fInitialCollateral = floatToDec18(initialCollateral);
      let duration = BigInt(60 * 86_400);
      let fFees = BigInt(fee * 1_000_000);
      let fReserve = BigInt(reserve * 1_000_000);
      let challengePeriod = BigInt(3 * 86400); // 3 days
      await mockVOL.connect(owner).approve(await mintingHub.getAddress(), 2n*fInitialCollateral);
      let tx = await mintingHub.openPosition(
        collateral,
        minCollateral,
        fInitialCollateral,
        initialLimit * 2n,
        7n * 24n * 3600n,
        duration,
        challengePeriod,
        fFees,
        fliqPrice,
        fReserve
      );
      let rc = await tx.wait();
      const topic = "0xc9b570ab9d98bdf3e38a40fd71b20edafca42449f23ca51f0bdcbf40e8ffe175"; // PositionOpened
      let log = rc?.logs.find((x) => x.topics.indexOf(topic) >= 0);
      const positionAddr = "0x" + log?.topics[2].substring(26);
      const positionContract = await ethers.getContractAt("Position", positionAddr, owner);
      const expiration = await positionContract.expiration();
      await evm_increaseTimeTo(await positionContract.start());
      tx = await mintingHub.clone(positionAddr, fInitialCollateral, initialLimit/2n, expiration);
      rc = await tx.wait();
      log = rc?.logs.find((x) => x.topics.indexOf(topic) >= 0);
      const clonePositionAddr = "0x" + log?.topics[2].substring(26);
      cloneContract = (await ethers.getContractAt("Position", clonePositionAddr, alice));
    });
    it("price should be zero at end of challenge", async () => {
      challengeAmount = initialCollateralClone / 2;
      let fchallengeAmount = floatToDec18(challengeAmount);
      await mockVOL.approve(await mintingHub.getAddress(), fchallengeAmount);
      let tx = await mintingHub.challenge(await cloneContract.getAddress(), fchallengeAmount, await cloneContract.price());
      await expect(tx).to.emit(mintingHub, "ChallengeStarted");
      challengeNumber++;
      await evm_increaseTime(86400 * 60 * 2);
      expect(await mintingHub.price(challengeNumber)).to.be.eq(0);
    });
    it("send challenge and ensure owner cannot withdraw", async () => {
      challengeAmount = initialCollateralClone / 2;
      let fchallengeAmount = floatToDec18(challengeAmount);
      await mockVOL.approve(await mintingHub.getAddress(), fchallengeAmount);
      let tx = await mintingHub.challenge(await cloneContract.getAddress(), fchallengeAmount, await cloneContract.price());
      await expect(tx).to.emit(mintingHub, "ChallengeStarted");
      challengeNumber++;
      let chprice = await mintingHub.price(challengeNumber);
      expect(chprice).to.be.eq(await cloneContract.price());
      let tx2 = cloneContract.connect(owner).withdrawCollateral(clonePositionAddr, floatToDec18(1));
      await expect(tx2).to.be.revertedWithCustomError(clonePositionContract, "Challenged");
    });
    it("bid on challenged, expired position", async () => {
      let liqPrice = dec18ToFloat(await cloneContract.price());
      let bidSize = challengeAmount / 2;
      let exp = await cloneContract.expiration();
      await evm_increaseTimeTo(exp - 5n);
      let fchallengeAmount = floatToDec18(challengeAmount);
      await mockVOL.approve(await mintingHub.getAddress(), fchallengeAmount);
      let tx2 = await mintingHub.challenge(await cloneContract.getAddress(), fchallengeAmount, await cloneContract.price());
      await expect(tx2).to.emit(mintingHub, "ChallengeStarted");
      challengeNumber++;
      const challenge = await mintingHub.challenges(challengeNumber);
      let challengerAddress = challenge.challenger;
      let positionsAddress = challenge.position;
      // await mockXCHF.connect(alice).mint(alice.address, floatToDec18(bidSize));

      // console.log("Challenging challenge " + challengeNumber + " at price " + price + " instead of " + liqPrice);
      // Challenging challenge 3 at price 24999903549382556050 instead of 25
      // const timestamp = await time.latest();
      // console.log("Challenge started at " + challenge.start + " on position with start " + (await clonePositionContract.start()) + ", expiration " + (await clonePositionContract.expiration()) + ", challenge period " + (await clonePositionContract.challengePeriod()) + ", and now it is " + timestamp);
      // Challenge started at 1810451265 on position with start 1792911949, expiration 1795503949, challenge period 259200, and now it is 1810451266
      await mockVOL.mint(clonePositionAddr, floatToDec18(bidSize)); // ensure there is something to bid on
      let balanceBeforeAlice = await zchf.balanceOf(alice.address);
      // console.log("Balance alice " + balanceBeforeAlice + " and bid size " + floatToDec18(bidSize) + " position collateral: " + await mockVOL.balanceOf(clonePositionAddr));
      // let balanceBeforeChallenger = await zchf.balanceOf(challengerAddress);
      let volBalanceBefore = await mockVOL.balanceOf(alice.address);
      const challengeData = await positionContract.challengeData();
      await evm_increaseTime(challengeData.phase);
      let tx = await mintingHub.connect(alice).bid(challengeNumber, floatToDec18(bidSize), false);
      let price = await mintingHub.price(challengeNumber);
      await expect(tx)
        .to.emit(mintingHub, "ChallengeSucceeded")
        .withArgs(
          positionsAddress,
          challengeNumber,
          (floatToDec18(bidSize) * price) / DECIMALS,
          floatToDec18(bidSize),
          floatToDec18(bidSize)
        );
      // let balanceAfterChallenger = await zchf.balanceOf(challengerAddress);
      // let balanceAfterAlice = await zchf.balanceOf(alice.address);
      let volBalanceAfter = await mockVOL.balanceOf(alice.address);
      // expect(balanceBeforeAlice - balanceAfterAlice).to.be.eq(bidAmountZCHF);
      // expect(balanceAfterChallenger - balanceBeforeChallenger).to.be.eq(bidAmountZCHF);
      expect(volBalanceAfter - volBalanceBefore).to.be.eq(floatToDec18(bidSize));
      await evm_increaseTime(86400);
      // Challenging challenge 3 at price 16666280864197424200 instead of 25
      await expect(mintingHub.bid(challengeNumber, floatToDec18(bidSize), false)).to.be.emit(mintingHub, "ChallengeSucceeded");
      expect(await mintingHub.price(challengeNumber)).to.be.eq(0);
    });
    it("bid on not existing challenge", async () => {
      let tx = mintingHub.connect(bob).bid(42, floatToDec18(42), false);
      await expect(tx).to.be.revertedWithPanic();
    });
    it("should revert notify challenge succeed call from non hub", async () => {
      await expect(
        positionContract.notifyChallengeSucceeded(owner.address, 100)
      ).to.be.revertedWithCustomError(positionContract, "NotHub");
    });
    it("should revert notify challenge avert call from non hub", async () => {
      await expect(
        positionContract.notifyChallengeAverted(100)
      ).to.be.revertedWithCustomError(positionContract, "NotHub");
    });
  });
  describe("adjusting price", async () => {
    beforeEach(async () => {
      let collateral = await mockVOL.getAddress();
      let fliqPrice = floatToDec18(5000);
      let minCollateral = floatToDec18(1);
      let fInitialCollateral = floatToDec18(initialCollateral);
      let duration = BigInt(60 * 86_400);
      let fFees = BigInt(fee * 1_000_000);
      let fReserve = BigInt(reserve * 1_000_000);
      let challengePeriod = BigInt(3 * 86400); // 3 days
      await mockVOL
        .connect(owner)
        .approve(await mintingHub.getAddress(), fInitialCollateral);
      let tx = await mintingHub.openPosition(
        collateral,
        minCollateral,
        fInitialCollateral,
        initialLimit,
        7n * 24n * 3600n,
        duration,
        challengePeriod,
        fFees,
        fliqPrice,
        fReserve
      );
      let rc = await tx.wait();
      const topic =
        "0xc9b570ab9d98bdf3e38a40fd71b20edafca42449f23ca51f0bdcbf40e8ffe175"; // PositionOpened
      const log = rc?.logs.find((x) => x.topics.indexOf(topic) >= 0);
      positionAddr = "0x" + log?.topics[2].substring(26);
      positionContract = await ethers.getContractAt(
        "Position",
        positionAddr,
        owner
      );
    });
    it("should revert adjusting price from non position owner", async () => {
      await expect(
        positionContract.connect(alice).adjustPrice(floatToDec18(1500))
      ).to.be.revertedWithCustomError(positionContract, "NotOwner");
    });
    it("should revert adjusting price when there is pending challenge", async () => {
      challengeAmount = initialCollateralClone / 2;
      let fchallengeAmount = floatToDec18(challengeAmount);
      let price = await positionContract.price();
      await mockVOL.approve(await mintingHub.getAddress(), fchallengeAmount);
      await mintingHub.challenge(positionAddr, fchallengeAmount, price);
      challengeNumber++;
      await expect(
        positionContract.adjustPrice(floatToDec18(1500))
      ).to.be.revertedWithCustomError(positionContract, "Challenged");
    });
    it("should increase cooldown for 3 days when submitted price is greater than the current price", async () => {
      await evm_increaseTime(86400 * 7);
      const prevCooldown = await positionContract.cooldown();
      console.log(prevCooldown)
      await expect(positionContract.adjustPrice(floatToDec18(5500))).to.be.emit(
        positionContract,
        "MintingUpdate"
      );
      expect(dec18ToFloat(await positionContract.price())).to.be.equal(5500n);

      const currentCooldown = await positionContract.cooldown();
      expect(currentCooldown > prevCooldown).to.be.true;
    });
    it("should revert adjusting to lower price when it lowers the collateral reserves below minted values", async () => {
      await evm_increaseTime(86400 * 8);
      await positionContract.mint(owner.address, floatToDec18(1000 * 100));

      await expect(
        positionContract.adjustPrice(floatToDec18(100))
      ).to.be.revertedWithCustomError(
        positionContract,
        "InsufficientCollateral"
      );
    });
    it("should revert adjusting price when new price is greater than minimum collateral value", async () => {
      const underPrice = initialLimit;
      await expect(
        positionContract.adjustPrice(underPrice * 2n)
      ).to.be.revertedWithCustomError(positionContract, "Hot");
    });
  });

  describe("adjusting position", async () => {
    beforeEach(async () => {
      let collateral = await mockVOL.getAddress();
      let fliqPrice = floatToDec18(5000);
      let minCollateral = floatToDec18(1);
      let fInitialCollateral = floatToDec18(initialCollateral);
      let duration = BigInt(60 * 86_400);
      let fFees = BigInt(fee * 1_000_000);
      let fReserve = BigInt(reserve * 1_000_000);
      let challengePeriod = BigInt(3 * 86400); // 3 days
      await mockVOL
        .connect(owner)
        .approve(await mintingHub.getAddress(), fInitialCollateral);
      let tx = await mintingHub.openPosition(
        collateral,
        minCollateral,
        fInitialCollateral,
        initialLimit,
        7n * 24n * 3600n,
        duration,
        challengePeriod,
        fFees,
        fliqPrice,
        fReserve
      );
      let rc = await tx.wait();
      const topic =
        "0xc9b570ab9d98bdf3e38a40fd71b20edafca42449f23ca51f0bdcbf40e8ffe175"; // PositionOpened
      const log = rc?.logs.find((x) => x.topics.indexOf(topic) >= 0);
      positionAddr = "0x" + log?.topics[2].substring(26);
      positionContract = await ethers.getContractAt(
        "Position",
        positionAddr,
        owner
      );
      expect(await positionContract.isClosed()).to.be.false;
    });
    it("should revert adjusting position from non position owner", async () => {
      await expect(
        positionContract.connect(alice).adjust(0, 0, 0)
      ).to.be.revertedWithCustomError(positionContract, "NotOwner");
    });
    it("owner can provide more collaterals to the position", async () => {
      const colBalance = await mockVOL.balanceOf(positionAddr);
      const amount = floatToDec18(100);
      await mockVOL.approve(positionAddr, amount);
      await positionContract.adjust(0, colBalance + amount, floatToDec18(1000));

      const newColBalance = await mockVOL.balanceOf(positionAddr);
      expect(newColBalance - colBalance).to.be.equal(amount);
    });
    it("owner can withdraw collaterals from the position", async () => {
      await evm_increaseTime(86400 * 8);
      const colBalance = await mockVOL.balanceOf(positionAddr);
      const amount = floatToDec18(100);
      await positionContract.adjust(0, colBalance - amount, floatToDec18(1000));

      const newColBalance = await mockVOL.balanceOf(positionAddr);
      expect(colBalance - newColBalance).to.be.equal(amount);
    });
    it("owner can mint new ZCHF", async () => {
      await evm_increaseTime(86400 * 8);
      const price = floatToDec18(1000);
      const colBalance = await mockVOL.balanceOf(positionAddr);
      const minted = await positionContract.minted();
      const amount = floatToDec18(100);

      const beforeZchfBal = await zchf.balanceOf(owner.address);
      await positionContract.adjust(minted + amount, colBalance, price);
      const afterZchfBal = await zchf.balanceOf(owner.address);
      expect(afterZchfBal - beforeZchfBal).to.be.equal(
        ethers.parseEther("89.8384")
      );
    });
    it("owner can burn ZCHF", async () => {
      await evm_increaseTime(86400 * 8);
      const price = floatToDec18(1000);
      const colBalance = await mockVOL.balanceOf(positionAddr);
      const minted = await positionContract.minted();
      const amount = floatToDec18(100);
      await positionContract.adjust(minted + amount, colBalance, price);

      await positionContract.adjust(minted, colBalance, price);
      expect(await positionContract.minted()).to.be.equal(minted);
    });
    it("owner can adjust price", async () => {
      await evm_increaseTime(86400 * 8);
      const price = await positionContract.price();
      let minted = await positionContract.minted();
      let collbal = await positionContract.minimumCollateral();
      await positionContract.adjust(minted, collbal, price * 2n);
      expect(await positionContract.price()).to.be.equal(price * 2n);
    });
  });

  describe("withdrawing collaterals", () => {
    const amount = floatToDec18(10);

    beforeEach(async () => {
      let collateral = await mockVOL.getAddress();
      let fliqPrice = floatToDec18(5000);
      let minCollateral = floatToDec18(1);
      let fInitialCollateral = floatToDec18(initialCollateral);
      let duration = BigInt(60 * 86_400);
      let fFees = BigInt(fee * 1_000_000);
      let fReserve = BigInt(reserve * 1_000_000);
      let challengePeriod = BigInt(3 * 86400); // 3 days
      await mockVOL
        .connect(owner)
        .approve(await mintingHub.getAddress(), fInitialCollateral);
      let tx = await mintingHub.openPosition(
        collateral,
        minCollateral,
        fInitialCollateral,
        initialLimit,
        7n * 24n * 3600n,
        duration,
        challengePeriod,
        fFees,
        fliqPrice,
        fReserve
      );
      let rc = await tx.wait();
      const topic =
        "0xc9b570ab9d98bdf3e38a40fd71b20edafca42449f23ca51f0bdcbf40e8ffe175"; // PositionOpened
      const log = rc?.logs.find((x) => x.topics.indexOf(topic) >= 0);
      positionAddr = "0x" + log?.topics[2].substring(26);
      positionContract = await ethers.getContractAt(
        "Position",
        positionAddr,
        owner
      );
      await mockVOL.transfer(positionAddr, amount);
    });
    it("should revert withdrawing collaterals from non position owner", async () => {
      await expect(
        positionContract
          .connect(alice)
          .withdrawCollateral(owner.address, amount)
      ).to.be.revertedWithCustomError(positionContract, "NotOwner");
    });
    it("should revert withdrawing when it is in hot auctions", async () => {
      await expect(
        positionContract.withdrawCollateral(owner.address, amount)
      ).to.be.revertedWithCustomError(positionContract, "Hot");
    });
    it("should not revert when withdrawing portion of collaterals leaving dust", async () => {
      await positionContract.deny([], "");
      await evm_increaseTime(86400 * 7);
      const balance = await mockVOL.balanceOf(positionAddr);
      await positionContract.withdrawCollateral(owner.address, balance - ethers.parseEther("0.5"));
    });
    it("owner should be able to withdraw collaterals after the auction is closed", async () => {
      await positionContract.deny([], "");
      const colBal = await mockVOL.balanceOf(positionAddr);
      expect(
        positionContract.withdrawCollateral(owner.address, colBal)
      ).to.be.emit(positionContract, "MintingUpdate");
      expect(positionContract.withdrawCollateral(owner.address, 0)).to.be.emit(
        positionContract,
        "MintingUpdate"
      );
    });
  });
  describe("withdrawing any tokens", () => {
    it("should revert withdrawing tokens from non position owner", async () => {
      const amount = floatToDec18(1);
      await expect(
        positionContract
          .connect(alice)
          .withdraw(await zchf.getAddress(), owner.address, amount)
      ).to.be.revertedWithCustomError(positionContract, "NotOwner");
    });
    it("owner can withdraw any erc20 tokens locked on position contract", async () => {
      await evm_increaseTime(86400 * 8);
      const amount = floatToDec18(1);

      await zchf.transfer(positionAddr, amount);
      const beforeBal = await zchf.balanceOf(positionAddr);
      await positionContract.withdraw(
        await zchf.getAddress(),
        owner.address,
        amount
      );
      const afterBal = await zchf.balanceOf(positionAddr);
      expect(beforeBal - afterBal).to.be.equal(amount);

      // withdraw collaterals
      await mockVOL.transfer(positionAddr, amount);
      const beforeColBal = await mockVOL.balanceOf(positionAddr);
      await positionContract.withdraw(
        await mockVOL.getAddress(),
        owner.address,
        amount
      );
      const afterColBal = await mockVOL.balanceOf(positionAddr);
      expect(beforeColBal - afterColBal).to.be.equal(amount);
    });
  });
  describe("returning postponed collateral", async () => {
    it("should return pending postponed collaterals (Need to find more exact scenarios)", async () => {
      await mintingHub.returnPostponedCollateral(
        await mockVOL.getAddress(),
        owner.address
      );
    });
  });
  describe("notifying loss", async () => {
    const amount = floatToDec18(10);
    const initialLimit = floatToDec18(1_000_000);
    let fliqPrice = floatToDec18(5000);
    let minCollateral = floatToDec18(1);
    let fInitialCollateral = floatToDec18(initialCollateral);
    let fchallengeAmount = floatToDec18(initialCollateral);
    let duration = BigInt(60 * 86_400);
    let fFees = BigInt(fee * 1_000_000);
    let fReserve = BigInt(reserve * 1_000_000);
    let challengePeriod = BigInt(3 * 86400); // 3 days

    beforeEach(async () => {
      let collateral = await mockVOL.getAddress();
      await mockVOL
        .connect(owner)
        .approve(await mintingHub.getAddress(), fInitialCollateral);
      let tx = await mintingHub.openPosition(
        collateral,
        minCollateral,
        fInitialCollateral,
        initialLimit,
        7n * 24n * 3600n,
        duration,
        challengePeriod,
        fFees,
        fliqPrice,
        fReserve
      );
      let rc = await tx.wait();
      let topic =
        "0xc9b570ab9d98bdf3e38a40fd71b20edafca42449f23ca51f0bdcbf40e8ffe175"; // PositionOpened
      let log = rc?.logs.find((x) => x.topics.indexOf(topic) >= 0);
      positionAddr = "0x" + log?.topics[2].substring(26);
      positionContract = await ethers.getContractAt(
        "Position",
        positionAddr,
        owner
      );
      await mockVOL.transfer(positionAddr, amount);

      await evm_increaseTime(86400 * 7);
      await mockVOL.approve(await mintingHub.getAddress(), initialLimit);
      await positionContract.assertCloneable();
      const cloneLimit = await positionContract.availableForClones();
      const expiration = await positionContract.expiration();
      tx = await mintingHub.clone(positionAddr, fInitialCollateral, cloneLimit, expiration);
      rc = await tx.wait();
      log = rc?.logs.find((x) => x.topics.indexOf(topic) >= 0);
      clonePositionAddr = "0x" + log?.topics[2].substring(26);
      clonePositionContract = await ethers.getContractAt("Position", clonePositionAddr, alice);

      let price = await clonePositionContract.price();
      await mockVOL.approve(await mintingHub.getAddress(), fchallengeAmount);
      await mintingHub.challenge(clonePositionAddr, fchallengeAmount, price);
      challengeNumber++;
    });
    it("should transfer loss amount from reserve to minting hub when notify loss", async () => {
      await evm_increaseTime(86400 * 6);
      await zchf.transfer(await equity.getAddress(), floatToDec18(400_000));
      let tx = await mintingHub
        .connect(bob)
        .bid(challengeNumber, fchallengeAmount, false);
      await expect(tx)
        .to.emit(mintingHub, "ChallengeSucceeded")
        .emit(zchf, "Loss");
    });
    it("should transfer loss amount from reserve to minting hub when notify loss", async () => {
      await evm_increaseTime(86400 * 6);
      let tx = await mintingHub
        .connect(bob)
        .bid(challengeNumber, fchallengeAmount, false);
      await expect(tx)
        .to.emit(mintingHub, "ChallengeSucceeded")
        .emit(zchf, "Loss");
    });
  });

  describe("position expiration auction", () => {
    let test: PositionExpirationTest;
    let pos: Position;

    it("initialize", async () => {
      const factory = await ethers.getContractFactory("PositionExpirationTest");
      test = await factory.deploy(await mintingHub.getAddress());
      await zchf.transfer(await test.getAddress(), 1000n * 10n ** 18n);
      let tx = await test.openPositionFor(await alice.getAddress());
      let rc = await tx.wait();
      const topic = "0xc9b570ab9d98bdf3e38a40fd71b20edafca42449f23ca51f0bdcbf40e8ffe175"; // PositionOpened
      const log = rc?.logs.find((x) => x.topics.indexOf(topic) >= 0);
      let positionAddr = "0x" + log?.topics[2].substring(26);
      pos = await ethers.getContractAt("Position", positionAddr, owner);

      // ensure minter's reserve is at least half there to make tests more interesting
      let target = await zchf.minterReserve();
      let present = await zchf.balanceOf(await equity.getAddress());
      if (present < target){
        let amount = (target - present) / 2n;
        zchf.connect(owner).transfer(await zchf.reserve(), amount);
      }
    });

    it("should be possible to borrow after starting", async () => {
      await evm_increaseTimeTo(await pos.start());
      let balanceBefore = await zchf.balanceOf(await alice.getAddress());
      let mintedAmount = 50000n * 10n ** 18n;
      let tx = await pos.connect(alice).mint(await alice.getAddress(), mintedAmount);
      await tx.wait();
      let balanceAfter = await zchf.balanceOf(await alice.getAddress());
      expect(balanceAfter - balanceBefore).to.be.eq(39794550000000000000000n);
      expect(await pos.minted()).to.be.eq(mintedAmount);
      await zchf.transfer(await test.getAddress(), 39794550000000000000000n);
      await zchf.transfer(await test.getAddress(), 100000000000000000000000n);
    });

    it("force sale should fail before expiration", async () => {
      let tx = test.forceBuy(await pos.getAddress(), 1n);
      expect(tx).to.be.revertedWithCustomError(pos, "Alive");
    });

    it("force sale should succeed after expiration", async () => {
      await evm_increaseTimeTo(await pos.expiration());
      let tx = await test.forceBuy(await pos.getAddress(), 1n);
    });

    it("price should reach liq price after one period", async () => {
      await evm_increaseTimeTo((await pos.expiration()) + (await pos.challengePeriod()));
      let expPrice = await mintingHub.expiredPurchasePrice(await pos.getAddress());
      let liqPrice = await pos.price();
      expect(liqPrice).to.be.eq(expPrice);
    });
    
    it("force sale at liquidation price should succeed in cleaning up position", async () => {
      let tx = await test.forceBuy(await pos.getAddress(), 35n);
      expect(await pos.minted()).to.be.eq(0n);
      expect(await pos.isClosed()).to.be.false; // still more than 10 collateral left
    });
    
    it("get rest for cheap and close position", async () => {
      await evm_increaseTimeTo((await pos.expiration()) + 2n * (await pos.challengePeriod()));
      let tx = await test.forceBuy(await pos.getAddress(), 64n);
      expect(await pos.minted()).to.be.eq(0n);
      expect(await pos.isClosed()).to.be.true;
      expect(await mockVOL.balanceOf(await pos.getAddress())).to.be.eq(0n); // still collateral left
    });
  });

  describe("position rolling", () => {
    let test: PositionRollingTest;

    let pos1: Position;
    let pos2: Position;

    it("initialize", async () => {
      const factory = await ethers.getContractFactory("PositionRollingTest");
      test = await factory.deploy(await mintingHub.getAddress());
      await zchf.transfer(await test.getAddress(), floatToDec18(2_000)); // opening fee
      await test.openTwoPositions();
      pos1 = await ethers.getContractAt("Position", await test.p1());
      pos2 = await ethers.getContractAt("Position", await test.p2());
    });

    it("roll should fail before positions are ready", async () => {
      expect(await pos1.start()).to.be.lessThan(await pos2.start());
      await evm_increaseTimeTo(await pos1.start());
      let tx = test.roll();
      expect(tx).to.be.revertedWithCustomError(pos2, "Hot");
    });

    it("roll", async () => {
      await evm_increaseTimeTo(await pos2.start());
      await test.roll();
    });

    it("roll into clone", async () => {
      // TODO
    });
  });
});
