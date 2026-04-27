import { expect } from "chai";
import { ethers } from "hardhat";
import {
  AmplifierCurve,
  AmplifiedCurvePosition,
  IBasicFrankencoin,
  ITwocrypto,
  IERC20,
} from "../typechain";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { evm_increaseTime } from "./helper";

const normalizeAddress = (addr: string) => ethers.getAddress(addr);

/**
 * Fork tests for AmplifierCurve + AmplifiedCurvePosition (EIP-1167 clone).
 *
 * Pool:  0x027b40f5917fcd0eac57d7015e120096a5f92ca9  (crvUSD / ZCHF TwoCrypto)
 * Chain: Ethereum mainnet, block 24970536
 */
describe("AmplifierCurve", function () {
  // --- Pinned mainnet addresses ---
  const ZCHF_ADDR = "0xB58E61C3098d85632Df34EecfB899A1Ed80921cB";
  const CURVE_POOL_ADDR = "0x027b40f5917fcd0eac57d7015e120096a5f92ca9";
  const CRVUSD_WHALE = "0x4f944A4f195f4a86eBb97bAbF07E0dE1d79638b7";
  const ZCHF_WHALE = "0x9642b23Ed1E01Df1092B92641051881a322F5D4E";
  const FORK_BLOCK = 24970536;

  // --- Test parameters ---
  const BORROW_LIMIT = ethers.parseEther("1000000");
  const ZCHF_TO_BORROW = ethers.parseEther("1000");
  const COLLATERAL_AMOUNT = ethers.parseEther("1300"); // ~10% buffer over minimum

  let owner: HardhatEthersSigner;
  let alice: HardhatEthersSigner;
  let zchfWhale: HardhatEthersSigner;
  let crvUsdWhale: HardhatEthersSigner;

  let amplifier: AmplifierCurve;
  let position: AmplifiedCurvePosition;
  let zchf: IBasicFrankencoin;
  let pool: ITwocrypto;
  let collateral: IERC20;

  let expirationTs: number;
  let minPeriod: bigint;

  // -----------------------------------------------------------------------

  before(async function () {
    const alchemyKey = process.env.ALCHEMY_RPC_KEY;
    await ethers.provider.send("hardhat_reset", [
      {
        forking: {
          jsonRpcUrl: `https://eth-mainnet.g.alchemy.com/v2/${alchemyKey}`,
          blockNumber: FORK_BLOCK,
        },
      },
    ]);

    [owner, alice] = await ethers.getSigners();

    // Fund and impersonate whales
    await owner.sendTransaction({
      to: ZCHF_WHALE,
      value: ethers.parseEther("1"),
    });
    await owner.sendTransaction({
      to: CRVUSD_WHALE,
      value: ethers.parseEther("1"),
    });
    await ethers.provider.send("hardhat_impersonateAccount", [ZCHF_WHALE]);
    await ethers.provider.send("hardhat_impersonateAccount", [CRVUSD_WHALE]);
    zchfWhale = await ethers.getSigner(ZCHF_WHALE);
    crvUsdWhale = await ethers.getSigner(CRVUSD_WHALE);

    // Contract handles
    zchf = (await ethers.getContractAt(
      "IBasicFrankencoin",
      ZCHF_ADDR
    )) as unknown as IBasicFrankencoin;
    pool = (await ethers.getContractAt(
      "ITwocrypto",
      CURVE_POOL_ADDR
    )) as unknown as ITwocrypto;

    // Resolve collateral: whichever coin in the pool is not ZCHF
    const coin0 = await pool.coins(0n);
    const collateralAddr =
      normalizeAddress(coin0) === normalizeAddress(ZCHF_ADDR)
        ? await pool.coins(1n)
        : coin0;
    collateral = (await ethers.getContractAt(
      "contracts/erc20/IERC20.sol:IERC20",
      collateralAddr
    )) as unknown as IERC20;

    // Expiration: 1 year from fork block
    const block = await ethers.provider.getBlock(FORK_BLOCK);
    expirationTs = block!.timestamp + 365 * 24 * 3600;

    // Deploy AmplifierCurve
    amplifier = (await ethers.deployContract("AmplifierCurve", [
      CURVE_POOL_ADDR,
      ZCHF_ADDR,
      expirationTs,
      BORROW_LIMIT,
    ])) as unknown as AmplifierCurve;

    // Register amplifier as ZCHF minter
    const MIN_FEE = await (zchf as any).MIN_FEE();
    minPeriod = await (zchf as any).MIN_APPLICATION_PERIOD();
    await (zchf as any)
      .connect(zchfWhale)
      .suggestMinter(
        await amplifier.getAddress(),
        minPeriod,
        MIN_FEE,
        "AmplifierCurve fork test"
      );
    await evm_increaseTime(minPeriod + 1n);

    // Create alice's position via staticCall to capture address before sending tx
    const posAddr = await amplifier
      .connect(alice)
      .createAmplifiedPosition.staticCall();
    await amplifier.connect(alice).createAmplifiedPosition();
    position = (await ethers.getContractAt(
      "AmplifiedCurvePosition",
      posAddr
    )) as unknown as AmplifiedCurvePosition;

    // Fund alice with collateral and a ZCHF buffer for repayment shortfalls
    await collateral
      .connect(crvUsdWhale)
      .transfer(alice.address, ethers.parseEther("10000"));
    await (zchf as any)
      .connect(zchfWhale)
      .transfer(alice.address, ethers.parseEther("50"));
  });

  // -----------------------------------------------------------------------

  describe("constructor", function () {
    it("CURVE_POOL is set", async function () {
      expect(normalizeAddress(await amplifier.CURVE_POOL())).to.equal(
        normalizeAddress(CURVE_POOL_ADDR)
      );
    });

    it("ZCHF is set", async function () {
      expect(normalizeAddress(await amplifier.ZCHF())).to.equal(
        normalizeAddress(ZCHF_ADDR)
      );
    });

    it("ZCHF_INDEX points to ZCHF in the pool", async function () {
      const index = await amplifier.ZCHF_INDEX();
      expect(index).to.be.oneOf([0n, 1n]);
      const coin = await pool.coins(index);
      expect(normalizeAddress(coin)).to.equal(normalizeAddress(ZCHF_ADDR));
    });

    it("COLLATERAL is the non-ZCHF coin", async function () {
      const collateralAddr = await amplifier.COLLATERAL();
      expect(normalizeAddress(collateralAddr)).to.not.equal(
        normalizeAddress(ZCHF_ADDR)
      );
      const coin0 = await pool.coins(0n);
      const coin1 = await pool.coins(1n);
      expect([normalizeAddress(coin0), normalizeAddress(coin1)]).to.include(
        normalizeAddress(collateralAddr)
      );
    });

    it("PRICE_ANCHOR is a non-zero oracle snapshot", async function () {
      expect(await amplifier.PRICE_ANCHOR()).to.be.gt(0n);
    });

    it("EXPIRATION matches constructor arg", async function () {
      expect(await amplifier.EXPIRATION()).to.equal(expirationTs);
    });

    it("LIMIT matches constructor arg", async function () {
      expect(await amplifier.LIMIT()).to.equal(BORROW_LIMIT);
    });

    it("POSITION_IMPLEMENTATION has deployed bytecode", async function () {
      const impl = await amplifier.POSITION_IMPLEMENTATION();
      expect(await ethers.provider.getCode(impl)).to.not.equal("0x");
    });

    it("totalBorrowed starts at zero", async function () {
      expect(await amplifier.totalBorrowed()).to.equal(0n);
    });

    it("amplifier is a registered ZCHF minter", async function () {
      expect(await (zchf as any).isMinter(await amplifier.getAddress())).to.be
        .true;
    });
  });

  // -----------------------------------------------------------------------

  describe("createAmplifiedPosition()", function () {
    it("emits AmplifiedPositionCreated", async function () {
      await expect(amplifier.connect(owner).createAmplifiedPosition()).to.emit(
        amplifier,
        "AmplifiedPositionCreated"
      );
    });

    it("returned address is a deployed clone", async function () {
      const posAddr = await amplifier
        .connect(owner)
        .createAmplifiedPosition.staticCall();
      expect(normalizeAddress(posAddr)).to.not.equal(
        normalizeAddress(ethers.ZeroAddress)
      );
    });

    it("clone is registered as a ZCHF position under this amplifier", async function () {
      const parent = await (zchf as any).getPositionParent(
        await position.getAddress()
      );
      expect(normalizeAddress(parent)).to.equal(
        normalizeAddress(await amplifier.getAddress())
      );
    });

    it("clone.owner is the caller", async function () {
      expect(normalizeAddress(await position.owner())).to.equal(
        normalizeAddress(alice.address)
      );
    });

    it("clone.AMP points back to the amplifier", async function () {
      expect(normalizeAddress(await position.AMP())).to.equal(
        normalizeAddress(await amplifier.getAddress())
      );
    });

    it("clone cannot be re-initialized", async function () {
      await expect(
        position.initialize(await amplifier.getAddress(), owner.address)
      ).to.be.revertedWithCustomError(position, "AlreadyInitialized");
    });
  });

  // -----------------------------------------------------------------------

  describe("getMinimumCollateral()", function () {
    it("returns a positive amount", async function () {
      expect(await amplifier.getMinimumCollateral(ZCHF_TO_BORROW)).to.be.gt(0n);
    });

    it("scales linearly", async function () {
      const half = await amplifier.getMinimumCollateral(
        ethers.parseEther("500")
      );
      const full = await amplifier.getMinimumCollateral(
        ethers.parseEther("1000")
      );
      expect(full).to.equal(half * 2n);
    });

    it("matches anchor price math", async function () {
      const anchor = await amplifier.PRICE_ANCHOR();
      const zchfIndex = await amplifier.ZCHF_INDEX();
      const ONE = ethers.parseEther("1");
      const expected =
        zchfIndex === 0n
          ? (ZCHF_TO_BORROW * ONE) / anchor
          : (ZCHF_TO_BORROW * anchor) / ONE;
      expect(await amplifier.getMinimumCollateral(ZCHF_TO_BORROW)).to.equal(
        expected
      );
    });
  });

  // -----------------------------------------------------------------------

  describe("checkPrice()", function () {
    it("does not revert at the fork block oracle price", async function () {
      await expect(amplifier.checkPrice()).to.not.be.rejected;
    });
  });

  // -----------------------------------------------------------------------

  describe("mint()", function () {
    it("reverts for non-owner", async function () {
      await expect(
        position.connect(owner).mint(ZCHF_TO_BORROW, COLLATERAL_AMOUNT, 0n)
      ).to.be.revertedWithCustomError(position, "NotOwner");
    });

    it("reverts with InsufficientCollateral when below minimum", async function () {
      const min = await amplifier.getMinimumCollateral(ZCHF_TO_BORROW);
      await collateral
        .connect(alice)
        .approve(await amplifier.getAddress(), min - 1n);
      await expect(
        position.connect(alice).mint(ZCHF_TO_BORROW, min - 1n, 0n)
      ).to.be.revertedWithCustomError(amplifier, "InsufficientCollateral");
    });

    it("emits Mint and Borrowed on a successful call", async function () {
      await collateral
        .connect(alice)
        .approve(await amplifier.getAddress(), COLLATERAL_AMOUNT);
      await expect(
        position.connect(alice).mint(ZCHF_TO_BORROW, COLLATERAL_AMOUNT, 0n)
      )
        .to.emit(position, "Mint")
        .and.to.emit(amplifier, "Borrowed");
    });

    it("position.borrowed equals zchfAmount", async function () {
      expect(await position.borrowed()).to.equal(ZCHF_TO_BORROW);
    });

    it("position.lpBalance is positive", async function () {
      expect(await position.lpBalance()).to.be.gt(0n);
    });

    it("amplifier.totalBorrowed equals zchfAmount", async function () {
      expect(await amplifier.totalBorrowed()).to.equal(ZCHF_TO_BORROW);
    });

    it("no tokens are left stranded in the position contract", async function () {
      const posAddr = await position.getAddress();
      expect(await (zchf as any).balanceOf(posAddr)).to.equal(0n);
      expect(await collateral.balanceOf(posAddr)).to.equal(0n);
    });
  });

  // -----------------------------------------------------------------------

  describe("burn()", function () {
    it("reverts for non-owner", async function () {
      const lp = await position.lpBalance();
      await expect(
        position.connect(owner).burn(lp, [0n, 0n])
      ).to.be.revertedWithCustomError(position, "NotOwner");
    });

    it("emits Burn and Repaid on a successful full exit", async function () {
      const lp = await position.lpBalance();
      await expect(position.connect(alice).burn(lp, [0n, 0n]))
        .to.emit(position, "Burn")
        .and.to.emit(amplifier, "Repaid");
    });

    it("position.borrowed is zero after full exit", async function () {
      expect(await position.borrowed()).to.equal(0n);
    });

    it("position.lpBalance is zero after full exit", async function () {
      expect(await position.lpBalance()).to.equal(0n);
    });

    it("amplifier.totalBorrowed is zero after full exit", async function () {
      expect(await amplifier.totalBorrowed()).to.equal(0n);
    });

    it("alice received collateral back from the pool", async function () {
      // Started with 10000 collateral, put in 1100, should have ~8900+ back
      expect(await collateral.balanceOf(alice.address)).to.be.gt(
        ethers.parseEther("8900")
      );
    });
  });

  // -----------------------------------------------------------------------

  describe("access control", function () {
    it("borrowIntoPosition reverts for non-position callers", async function () {
      await expect(
        amplifier
          .connect(alice)
          .borrowIntoPosition(
            alice.address,
            ethers.parseEther("1"),
            ethers.parseEther("2")
          )
      ).to.be.revertedWithCustomError(amplifier, "AccessDenied");
    });

    it("repay reverts for non-position callers", async function () {
      await expect(
        amplifier
          .connect(alice)
          .repay(
            alice.address,
            ethers.parseEther("1"),
            ethers.parseEther("1"),
            ethers.parseEther("1")
          )
      ).to.be.revertedWithCustomError(amplifier, "AccessDenied");
    });
  });

  // -----------------------------------------------------------------------

  describe("expiry", function () {
    let expiredAmp: AmplifierCurve;
    let expiredPos: AmplifiedCurvePosition;

    before(async function () {
      // Deploy a second amplifier that expires well before the minter registration clears,
      // then advance time so it's both registered AND expired.
      const block = await ethers.provider.getBlock("latest");
      const now = block!.timestamp;

      expiredAmp = (await ethers.deployContract("AmplifierCurve", [
        CURVE_POOL_ADDR,
        ZCHF_ADDR,
        now + Number(minPeriod) + 2, // expires just after registration clears
        BORROW_LIMIT,
      ])) as unknown as AmplifierCurve;

      const MIN_FEE = await (zchf as any).MIN_FEE();
      await (zchf as any)
        .connect(zchfWhale)
        .suggestMinter(await expiredAmp.getAddress(), minPeriod, MIN_FEE, "");

      // Advance time: past registration period AND past the amplifier expiration
      await evm_increaseTime(minPeriod + 10n);

      const posAddr = await expiredAmp
        .connect(alice)
        .createAmplifiedPosition.staticCall();
      await expiredAmp.connect(alice).createAmplifiedPosition();
      expiredPos = (await ethers.getContractAt(
        "AmplifiedCurvePosition",
        posAddr
      )) as unknown as AmplifiedCurvePosition;
    });

    it("mint reverts with AmplifierExpired", async function () {
      await collateral
        .connect(alice)
        .approve(await expiredAmp.getAddress(), COLLATERAL_AMOUNT);
      await expect(
        expiredPos.connect(alice).mint(ZCHF_TO_BORROW, COLLATERAL_AMOUNT, 0n)
      ).to.be.revertedWithCustomError(expiredAmp, "AmplifierExpired");
    });
  });

  // -----------------------------------------------------------------------

  describe("borrow limit", function () {
    let limitedAmp: AmplifierCurve;
    let limitedPos: AmplifiedCurvePosition;

    const TINY_LIMIT = ethers.parseEther("1"); // 1 ZCHF total

    before(async function () {
      const block = await ethers.provider.getBlock("latest");
      const now = block!.timestamp;

      limitedAmp = (await ethers.deployContract("AmplifierCurve", [
        CURVE_POOL_ADDR,
        ZCHF_ADDR,
        now + 365 * 24 * 3600,
        TINY_LIMIT,
      ])) as unknown as AmplifierCurve;

      const MIN_FEE = await (zchf as any).MIN_FEE();
      await (zchf as any)
        .connect(zchfWhale)
        .suggestMinter(await limitedAmp.getAddress(), minPeriod, MIN_FEE, "");
      await evm_increaseTime(minPeriod + 1n);

      const posAddr = await limitedAmp
        .connect(alice)
        .createAmplifiedPosition.staticCall();
      await limitedAmp.connect(alice).createAmplifiedPosition();
      limitedPos = (await ethers.getContractAt(
        "AmplifiedCurvePosition",
        posAddr
      )) as unknown as AmplifiedCurvePosition;
    });

    it("mint reverts with LimitExceeded when borrow exceeds the cap", async function () {
      // Trying to borrow 1000 ZCHF against a 1 ZCHF limit
      await collateral
        .connect(alice)
        .approve(await limitedAmp.getAddress(), COLLATERAL_AMOUNT);
      await expect(
        limitedPos.connect(alice).mint(ZCHF_TO_BORROW, COLLATERAL_AMOUNT, 0n)
      ).to.be.revertedWithCustomError(limitedAmp, "LimitExceeded");
    });
  });
});
