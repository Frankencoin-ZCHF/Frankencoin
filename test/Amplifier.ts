import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import {
  Frankencoin,
  IERC20,
  IUniswapV3Pool,
} from "../typechain";
import { ethers, network } from "hardhat";
import { evm_increaseTime } from "./helper";
import { expect } from "chai";
import {
  UniswapAmplifier,
  AmplifiedPosition,
} from "../typechain/contracts/swap/UniswapAmplifier.sol";

describe("Amplifier", async () => {
  let owner: HardhatEthersSigner;
  let alice: HardhatEthersSigner;

  let zchf: Frankencoin;
  let amplifier: UniswapAmplifier;
  let usdt: IERC20;
  let pool: IUniswapV3Pool;
  let expiration = Math.round(Date.now() / 1000) + 1209600 + 3600; // now + minApplicationPeriod + 1h

  // The widest tick range, aligned to the pool's tick spacing, that stays within +/- 20% of the anchor.
  let tickLow: bigint;
  let tickHigh: bigint;

  before(async () => {
    [owner, alice] = await ethers.getSigners();

    // Setup forking
    const alchemy = process.env.ALCHEMY_RPC_KEY;
    if (alchemy?.length == 0 || !alchemy) {
      console.log("WARN: No Alchemy Key found in .env");
    }

    await network.provider.request({
      method: "hardhat_reset",
      params: [
        {
          forking: {
            jsonRpcUrl: `https://eth-mainnet.g.alchemy.com/v2/${alchemy}`,
            blockNumber: 23017544,
          },
        },
      ],
    });
    await network.provider.send("hardhat_setBalance", [
      await owner.getAddress(),
      `0x${ethers.parseEther("100").toString(16)}`,
    ]);
    await network.provider.send("hardhat_setBalance", [
      await alice.getAddress(),
      `0x${ethers.parseEther("100").toString(16)}`,
    ]);

    // Setup environment
    // ZCHF - USDT
    pool = (await ethers.getContractAt(
      "contracts/swap/utils/IUniswapV3Pool.sol:IUniswapV3Pool",
      "0x8e4318e2cb1ae291254b187001a59a1f8ac78cef"
    )) as any as IUniswapV3Pool;
    zchf = await ethers.getContractAt(
      "Frankencoin",
      "0xB58E61C3098d85632Df34EecfB899A1Ed80921cB"
    );
    usdt = (await ethers.getContractAt(
      "contracts/erc20/IERC20.sol:IERC20",
      "0xdAC17F958D2ee523a2206206994597C13D831ec7"
    )) as any as IERC20;

    const fps = await ethers.getImpersonatedSigner(
      "0x1bA26788dfDe592fec8bcB0Eaff472a42BE341B2"
    ); // fps contract is the biggest holder at this block

    await network.provider.send("hardhat_setBalance", [
      await fps.getAddress(),
      `0x${ethers.parseEther("1").toString(16)}`,
    ]);
    await zchf
      .connect(fps)
      .transfer(await owner.getAddress(), ethers.parseEther("500000"));

    // Setup amplifier
    const amplifierFactory = await ethers.getContractFactory("UniswapAmplifier");
    amplifier = await amplifierFactory.deploy(
      await pool.getAddress(),
      "0xB58E61C3098d85632Df34EecfB899A1Ed80921cB",
      "0xB58E61C3098d85632Df34EecfB899A1Ed80921cB", // the Frankencoin contract acts as the IFrankencoinMinter
      expiration,
      ethers.parseEther("5000000")
    );

    // Pick the widest aligned range within the amplifier's allowed band for the test positions.
    const spacing = BigInt(await pool.tickSpacing());
    const minTick = await amplifier.MINIMUM_TICK();
    const maxTick = await amplifier.MAXIMUM_TICK();
    const ceilToSpacing = (t: bigint) => {
      const m = ((t % spacing) + spacing) % spacing;
      return m === 0n ? t : t + (spacing - m);
    };
    const floorToSpacing = (t: bigint) => t - (((t % spacing) + spacing) % spacing);
    // Symmetric ~+/-1000 tick range around the anchor (minTick = anchor - 1000), so the position is roughly
    // balanced at the current price and comfortably meets the 4/5 dollar-collateral requirement.
    tickLow = ceilToSpacing(minTick);
    tickHigh = floorToSpacing(minTick + 2000n);

    // Apply amplifier as minter
    await zchf.suggestMinter(
      await amplifier.getAddress(),
      await zchf.MIN_APPLICATION_PERIOD(),
      await zchf.MIN_FEE(),
      "Amplifier"
    );
    await evm_increaseTime((await zchf.MIN_APPLICATION_PERIOD()) + 3600n);

    // Steal some USDT
    const binance = await ethers.getImpersonatedSigner(
      "0xF977814e90dA44bFA03b6295A0616a897441aceC"
    ); // Binance is the biggest holder at this block
    usdt.connect(binance).transfer(await owner.getAddress(), 5000000 * 10 ** 6);
  });

  after(async () => {
    await network.provider.request({
      method: "hardhat_reset",
      params: [],
    });
  });

  it("should have the correct initial values", async () => {
    expect((await amplifier.UNISWAP_POOL()).toLowerCase()).to.be.eq(
      await pool.getAddress()
    );
    expect(await amplifier.ZCHF()).to.be.eq(await zchf.getAddress());
    expect(await amplifier.USD()).to.be.eq(await usdt.getAddress());
    expect(await amplifier.EXPIRATION()).to.be.eq(expiration);
    expect(await amplifier.LIMIT()).to.be.eq(ethers.parseEther("5000000"));

    let slot0 = await pool.slot0();
    // ZCHF is token0 in this pool, so a weaker dollar means a higher tick: more room upward (+1500) than down (-1000)
    expect(await amplifier.ZCHF_IS_TOKEN0()).to.be.eq(true);
    expect(await amplifier.MINIMUM_TICK()).to.be.eq(slot0.tick - 1000n);
    expect(await amplifier.MAXIMUM_TICK()).to.be.eq(slot0.tick + 1500n);
    expect(await amplifier.PRICE_ANCHOR_X96()).to.be.eq(
      (slot0.sqrtPriceX96 * slot0.sqrtPriceX96) >> 96n
    );
  });

  it("should return the correct min. dollars", async () => {
    // 4/5 of the anchor-price value of 1 ZCHF, allowing 1.25:1 leverage
    const anchor = await amplifier.PRICE_ANCHOR_X96();
    const expected = ((anchor * ethers.parseEther("1")) / (1n << 96n)) * 4n / 5n;
    expect(await amplifier.getMinimumDollars(ethers.parseEther("1"))).to.be.eq(
      expected
    );
  });

  it("should report the exploit threshold price", async () => {
    // Replicate the contract: P* = anchor / 1.0001^appreciationTicks + getMinimumDollars(Q96); exploitable below the
    // reciprocal dollar price, scaled to 18 decimals. Derived from the live parameters, so no magic constants.
    const Q96 = 1n << 96n;
    const mulDiv = (a: bigint, b: bigint, c: bigint) => (a * b) / c; // floor, matching Math.mulDiv
    const pow1_0001 = (ticks: bigint) => {
      let base = mulDiv(10001n, Q96, 10000n);
      let exp = ticks;
      let result = Q96;
      while (exp > 0n) {
        if (exp & 1n) result = mulDiv(result, base, Q96);
        base = mulDiv(base, base, Q96);
        exp >>= 1n;
      }
      return result;
    };

    const anchor = await amplifier.PRICE_ANCHOR_X96();
    const appreciationTicks = BigInt(await amplifier.MAX_DOLLAR_APPRECIATION_TICKS());
    const floorX96 = mulDiv(anchor, Q96, pow1_0001(appreciationTicks));
    const pStarX96 = floorX96 + (await amplifier.getMinimumDollars(Q96));
    const chfPerUsdX96 = mulDiv(Q96, Q96, pStarX96);
    const usdDecimals = await usdt.decimals();
    const expected = mulDiv(chfPerUsdX96, 10n ** usdDecimals, Q96);

    const reported = await amplifier.exploitableAt();
    expect(reported).to.be.eq(expected);

    // sanity: with an anchor near 0.80 CHF/USD, the threshold is a ~41% dollar decline, i.e. roughly 0.47 CHF/USD
    expect(reported).to.be.greaterThan(ethers.parseEther("0.40"));
    expect(reported).to.be.lessThan(ethers.parseEther("0.55"));
  });

  it("should create a position", async () => {
    await expect(amplifier.createAmplifiedPosition(tickLow, tickHigh)).to.emit(
      amplifier,
      "AmplifiedPositionCreated"
    );
  });

  it("should revert repay call", async () => {
    await expect(
      amplifier.repay(await owner.getAddress(), 0, 0, 0)
    ).revertedWithCustomError(amplifier, "AccessDenied");
  });

  it("should revert borrowIntoPool call", async () => {
    await expect(
      amplifier.borrowIntoPool(await owner.getAddress(), 0, 0)
    ).revertedWithCustomError(amplifier, "AccessDenied");
  });

  describe("Amplified position", () => {
    let position: AmplifiedPosition;

    before(async () => {
      const tx = await amplifier.createAmplifiedPosition(tickLow, tickHigh);
      const receipt = await tx.wait();
      const created = (receipt?.logs ?? [])
        .map((l) => {
          try {
            return amplifier.interface.parseLog(l);
          } catch {
            return null;
          }
        })
        .find((e) => e?.name === "AmplifiedPositionCreated");

      if (!created) {
        throw new Error("Unable to find AmplifiedPositionCreated log");
      }

      position = await ethers.getContractAt(
        "AmplifiedPosition",
        created.args[0]
      );
    });

    it("should set the owner", async () => {
      expect(await position.owner()).to.be.eq(await owner.getAddress());
    });

    it("should be bound to the given tick range", async () => {
      expect(await position.tickLow()).to.be.eq(tickLow);
      expect(await position.tickHigh()).to.be.eq(tickHigh);
    });

    it("should mint", async () => {
      await usdt.approve(
        await amplifier.getAddress(),
        ethers.parseUnits("5000000", 6)
      );

      const usdtUserBefore = await usdt.balanceOf(await owner.getAddress());
      const usdtPoolBefore = await usdt.balanceOf(await pool.getAddress());
      const zchfPoolBefore = await zchf.balanceOf(await pool.getAddress());
      const borrowedBefore = await position.borrowed();
      const totalBorrowedBefore = await amplifier.totalBorrowed();

      await expect(
        position.mint("500000000000000", await amplifier.getPrice())
      ).emit(position, "Mint");

      const usdtUserAfter = await usdt.balanceOf(await owner.getAddress());
      const usdtPoolAfter = await usdt.balanceOf(await pool.getAddress());
      const zchfPoolAfter = await zchf.balanceOf(await pool.getAddress());
      const borrowedAfter = await position.borrowed();
      const totalBorrowedAfter = await amplifier.totalBorrowed();

      expect(usdtUserAfter).to.be.lessThan(usdtUserBefore);
      expect(usdtPoolAfter).to.be.equal(usdtPoolBefore + usdtUserBefore - usdtUserAfter);
      expect(zchfPoolAfter).to.be.equal(zchfPoolBefore + borrowedAfter - borrowedBefore);
      expect(borrowedAfter).to.be.greaterThan(borrowedBefore);
      expect(totalBorrowedAfter).to.be.greaterThan(totalBorrowedBefore);
    });

    it("should revert mint when the expected price is off by more than 0.1%", async () => {
      const price = await amplifier.getPrice();
      await expect(
        position.mint("100000000000000", (price * 990n) / 1000n)
      ).revertedWithCustomError(amplifier, "PriceChangedTooMuch");
    });

    it("should partially burn", async () => {
      const usdtUserBefore = await usdt.balanceOf(await owner.getAddress());
      const usdtPoolBefore = await usdt.balanceOf(await pool.getAddress());
      const zchfPoolBefore = await zchf.balanceOf(await pool.getAddress());
      const borrowedBefore = await position.borrowed();
      const totalBorrowedBefore = await amplifier.totalBorrowed();

      await expect(
        position.burn("250000000000000", await amplifier.getPrice())
      ).emit(position, "Burn");

      const usdtUserAfter = await usdt.balanceOf(await owner.getAddress());
      const usdtPoolAfter = await usdt.balanceOf(await pool.getAddress());
      const zchfPoolAfter = await zchf.balanceOf(await pool.getAddress());
      const borrowedAfter = await position.borrowed();
      const totalBorrowedAfter = await amplifier.totalBorrowed();

      expect(usdtUserAfter).to.be.greaterThan(usdtUserBefore);
      expect(usdtPoolAfter).to.be.lessThan(usdtPoolBefore);
      expect(zchfPoolAfter).to.be.lessThan(zchfPoolBefore);
      expect(borrowedAfter).to.be.lessThan(borrowedBefore);
      expect(totalBorrowedAfter).to.be.lessThan(totalBorrowedBefore);
      expect(borrowedAfter).to.be.greaterThan(0);
      expect(totalBorrowedAfter).to.be.greaterThan(0);
    });

    it("should burn fully", async () => {
      await expect(
        position.burn("250000000000000", await amplifier.getPrice())
      ).emit(position, "Burn");

      expect(await position.borrowed()).to.be.eq(0);
      expect(await amplifier.totalBorrowed()).to.be.eq(0);
    });

    it("should not allow to call mint callback", async () => {
      await expect(
        position.uniswapV3MintCallback(50000n, 50000n, "0x00")
      ).revertedWithCustomError(position, "AccessDenied");
    });

    it("should not allow alice to mint", async () => {
      await expect(
        position.connect(alice).mint("500000000000000", await amplifier.getPrice())
      ).revertedWithCustomError(position, "NotOwner");
    });

    it("should not allow alice to burn", async () => {
      await expect(
        position.connect(alice).burn("500000000000000", await amplifier.getPrice())
      ).revertedWithCustomError(position, "NotOwner");
    });
  });
});
