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
      99536518700449223n,
      expiration,
      ethers.parseEther("5000000")
    );

    // Pick the widest aligned range within +/- 20% of the anchor for the test positions.
    const spacing = BigInt(await pool.tickSpacing());
    const anchor = await amplifier.TICK_ANCHOR();
    const ceilToSpacing = (t: bigint) => {
      const m = ((t % spacing) + spacing) % spacing;
      return m === 0n ? t : t + (spacing - m);
    };
    const floorToSpacing = (t: bigint) => t - (((t % spacing) + spacing) % spacing);
    tickLow = ceilToSpacing(anchor - 2000n);
    tickHigh = floorToSpacing(anchor + 2000n);

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
    expect(await amplifier.TOKEN0()).to.be.eq(await pool.token0());
    expect(await amplifier.ZCHF()).to.be.eq(await zchf.getAddress());
    expect(await amplifier.USD()).to.be.eq(await usdt.getAddress());
    expect(await amplifier.EXPIRATION()).to.be.eq(expiration);
    expect(await amplifier.LIMIT()).to.be.eq(ethers.parseEther("5000000"));

    let slot0 = await pool.slot0();
    expect(await amplifier.TICK_ANCHOR()).to.be.eq(slot0.tick);
    expect(await amplifier.PRICE_ANCHOR_X96()).to.be.eq(
      (slot0.sqrtPriceX96 * slot0.sqrtPriceX96) >> 96n
    );
  });

  it("should return the correct min. dollars", async () => {
    expect(await amplifier.getMinimumDollars(ethers.parseEther("1"))).to.be.eq(
      1256327
    );
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

      await expect(position.mint("500000000000000")).emit(position, "Mint");

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

    it("should partially burn", async () => {
      const usdtUserBefore = await usdt.balanceOf(await owner.getAddress());
      const usdtPoolBefore = await usdt.balanceOf(await pool.getAddress());
      const zchfPoolBefore = await zchf.balanceOf(await pool.getAddress());
      const borrowedBefore = await position.borrowed();
      const totalBorrowedBefore = await amplifier.totalBorrowed();

      await expect(position.burn("250000000000000")).emit(position, "Burn");

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
      await expect(position.burn("250000000000000")).emit(position, "Burn");

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
        position.connect(alice).mint("500000000000000")
      ).revertedWithCustomError(position, "NotOwner");
    });

    it("should not allow alice to burn", async () => {
      await expect(
        position.connect(alice).burn("500000000000000")
      ).revertedWithCustomError(position, "NotOwner");
    });
  });
});
