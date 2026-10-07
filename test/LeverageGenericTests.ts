import { expect } from "chai";
import { ethers } from "hardhat";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

/**
 * Fork tests for LeverageGeneric (mainnet, latest block).
 *
 * Position: cbBTC PositionV2 original, flashloan source: Morpho Blue (real contracts).
 *  - Mock router tests cover both flows and the failure paths deterministically.
 *  - Enso tests use real route calldata from the Enso API (skipped without ENSO_API_KEY).
 */
describe("LeverageGeneric", function () {
  this.timeout(300_000);

  const ZCHF = "0xB58E61C3098d85632Df34EecfB899A1Ed80921cB";
  const CBBTC = "0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf";
  const MORPHO = "0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb";
  const SOURCE = "0x5F2c10f779B7f0C44ee80128A3d7ac75B255bb95"; // cbBTC position
  const ZCHF_WHALE = "0x1bA26788dfDe592fec8bcB0Eaff472a42BE341B2"; // Equity (reserve), holds millions of ZCHF

  const ERC20_ABI = [
    "function balanceOf(address) view returns (uint256)",
    "function transfer(address,uint256) returns (bool)",
    "function approve(address,uint256) returns (bool)",
  ];
  const POS_ABI = [
    "function owner() view returns (address)",
    "function minted() view returns (uint256)",
    "function price() view returns (uint256)",
    "function expiration() view returns (uint40)",
    "function minimumCollateral() view returns (uint256)",
  ];

  let alice: HardhatEthersSigner;
  let zchf: any, cbbtc: any, src: any;
  let C: bigint; // target collateral (cbBTC base units)
  let expiration: number;

  const impersonate = async (addr: string) => {
    await ethers.provider.send("hardhat_setBalance", [addr, "0x56BC75E2D63100000"]);
    await ethers.provider.send("hardhat_impersonateAccount", [addr]);
    return ethers.getSigner(addr);
  };

  const setup = async () => {
    const key = process.env.ALCHEMY_RPC_KEY;
    await ethers.provider.send("hardhat_reset", [
      { forking: { jsonRpcUrl: `https://eth-mainnet.g.alchemy.com/v2/${key}` } },
    ]);

    [alice] = await ethers.getSigners();
    zchf = await ethers.getContractAt(ERC20_ABI, ZCHF);
    cbbtc = await ethers.getContractAt(ERC20_ABI, CBBTC);
    src = await ethers.getContractAt(POS_ABI, SOURCE);

    const block = await ethers.provider.getBlock("latest");
    const srcExp = Number(await src.expiration());
    expiration = Math.min(srcExp, block!.timestamp + 180 * 24 * 3600);

    const min = await src.minimumCollateral();
    C = min * 5n > 20_000_000n ? min * 5n : 20_000_000n; // ≥ 0.2 cbBTC

    // Fund alice: ZCHF from whale, cbBTC from Morpho's idle balance
    const whale = await impersonate(ZCHF_WHALE);
    await zchf.connect(whale).transfer(alice.address, ethers.parseEther("1000000"));
    const morpho = await impersonate(MORPHO);
    await cbbtc.connect(morpho).transfer(alice.address, 2n * C);
  };

  before(async function () {
    if (!process.env.ALCHEMY_RPC_KEY) this.skip();
    await setup();
  });

  // ── Mock router ───────────────────────────────────────────────────────────

  describe("mock router", function () {
    let leverage: any, router: any;
    let ratePrice: bigint;

    before(async function () {
      // Market 1.84× the liquidation price → ZCHF per cbBTC unit, like Position.price()
      ratePrice = ((await src.price()) * 184n) / 100n;
      router = await ethers.deployContract("MockSwapRouter", [ratePrice]);
      leverage = await ethers.deployContract("LeverageGeneric", [await router.getAddress()]);

      const morpho = await impersonate(MORPHO);
      await cbbtc.connect(morpho).transfer(await router.getAddress(), 10n * C);
    });

    const swapData = (amountIn: bigint) =>
      router.interface.encodeFunctionData("swap", [ZCHF, CBBTC, amountIn]);

    const expectClean = async (pos: string) => {
      const addr = await leverage.getAddress();
      expect(await zchf.balanceOf(addr)).to.equal(0n);
      expect(await cbbtc.balanceOf(addr)).to.equal(0n);
      const position = await ethers.getContractAt(POS_ABI, pos);
      expect(await position.owner()).to.equal(alice.address);
      expect(await cbbtc.balanceOf(pos)).to.equal(C);
    };

    it("preview matches the minted amount", async function () {
      const p = await leverage.preview(SOURCE, expiration, C);
      expect(p.mintGross).to.equal((C * (await src.price())) / 10n ** 18n);
      expect(p.reserveAmount + p.feeAmount + p.mintNet).to.equal(p.mintGross);
    });

    it("flow 1: equity in ZCHF", async function () {
      const p = await leverage.preview(SOURCE, expiration, C);
      const netIn = (p.mintNet * 999n) / 1000n; // margin for rounding
      const z = (C * ratePrice) / 10n ** 18n - netIn + ethers.parseEther("10");
      const amountIn = z + netIn;

      await zchf.connect(alice).approve(await leverage.getAddress(), z);
      const args = [SOURCE, z, C, expiration, swapData(amountIn)];
      const pos = await leverage.connect(alice).executeWithZCHF.staticCall(...args);

      const morphoBefore = await cbbtc.balanceOf(MORPHO);
      await leverage.connect(alice).executeWithZCHF(...args);

      await expectClean(pos);
      const position = await ethers.getContractAt(POS_ABI, pos);
      expect(await position.minted()).to.equal(p.mintGross);
      expect(await cbbtc.balanceOf(MORPHO)).to.equal(morphoBefore); // zero-fee flashloan repaid
    });

    it("flow 2: equity in collateral", async function () {
      const p = await leverage.preview(SOURCE, expiration, C);
      const netIn = (p.mintNet * 999n) / 1000n;
      const e = (C * 60n) / 100n; // swap of netIn yields ≈ 0.43 C, borrow is 0.4 C
      const amountIn = netIn;

      await cbbtc.connect(alice).approve(await leverage.getAddress(), e);
      const args = [SOURCE, e, C, expiration, swapData(amountIn)];
      const pos = await leverage.connect(alice).executeWithCollateral.staticCall(...args);

      const morphoBefore = await cbbtc.balanceOf(MORPHO);
      await leverage.connect(alice).executeWithCollateral(...args);

      await expectClean(pos);
      const position = await ethers.getContractAt(POS_ABI, pos);
      expect(await position.minted()).to.equal(p.mintGross);
      expect(await cbbtc.balanceOf(MORPHO)).to.equal(morphoBefore);
    });

    it("reverts when the swap does not cover the flashloan", async function () {
      const p = await leverage.preview(SOURCE, expiration, C);
      const netIn = (p.mintNet * 999n) / 1000n;
      const e = (C * 20n) / 100n; // borrow 0.8 C, swap yields only ≈ 0.43 C

      await cbbtc.connect(alice).approve(await leverage.getAddress(), e);
      await expect(
        leverage.connect(alice).executeWithCollateral(SOURCE, e, C, expiration, swapData(netIn))
      ).to.be.revertedWithCustomError(leverage, "InsufficientSwapOutput");
    });

    it("reverts when the swap call fails", async function () {
      const e = (C * 60n) / 100n;
      await cbbtc.connect(alice).approve(await leverage.getAddress(), e);
      await expect(
        leverage.connect(alice).executeWithCollateral(SOURCE, e, C, expiration, "0xdeadbeef")
      ).to.be.revertedWithCustomError(leverage, "SwapFailed");
    });

    it("rejects callbacks not coming from Morpho", async function () {
      await expect(leverage.connect(alice).onMorphoFlashLoan(1n, "0x")).to.be.revertedWithCustomError(
        leverage,
        "NotMorpho"
      );
    });

    it("rejects equity ≥ target collateral in flow 2", async function () {
      await expect(
        leverage.connect(alice).executeWithCollateral(SOURCE, C, C, expiration, "0x")
      ).to.be.revertedWithCustomError(leverage, "InvalidAmount");
    });
  });

  // ── Enso ──────────────────────────────────────────────────────────────────

  describe("enso router", function () {
    const ENSO = "https://api.enso.finance/api/v1/shortcuts/route";
    let leverage: any;
    let routerAddr: string;

    const quote = async (from: string, tokenIn: string, tokenOut: string, amountIn: bigint) => {
      const q = new URLSearchParams({
        chainId: "1",
        fromAddress: from,
        receiver: from,
        spender: from,
        tokenIn,
        tokenOut,
        amountIn: amountIn.toString(),
        slippage: "100", // 1%
        routingStrategy: "router",
      });
      let res: Response | undefined;
      for (let i = 0; i < 6; i++) {
        // throttle: the Enso API rate-limits aggressively (HTTP 429)
        await new Promise((r) => setTimeout(r, 2_500 * (i + 1)));
        try {
          res = await fetch(`${ENSO}?${q}`, {
            headers: { Authorization: `Bearer ${process.env.ENSO_API_KEY}` },
            signal: AbortSignal.timeout(20_000),
          });
          if (res.status != 429) break;
        } catch (e) {
          if (i == 5) throw e;
        }
      }
      res = res!;
      expect(res.ok, `enso ${res.status}`).to.equal(true);
      return (await res.json()) as { amountOut: string; minAmountOut: string; tx: { to: string; data: string } };
    };

    // Enso picks a different route per quote and some routes fail on a fork (e.g. an unverified
    // venue reverting with "Unknown"), so re-quote and re-simulate a few times before giving up.
    const withSimulatedRoute = async <T>(attempt: () => Promise<T>): Promise<T> => {
      let last: unknown;
      for (let i = 0; i < 3; i++) {
        try {
          return await attempt();
        } catch (e) {
          last = e;
        }
      }
      throw last;
    };

    // Fresh fork per test so the on-chain state matches Enso's quote as closely as possible.
    beforeEach(async function () {
      if (!process.env.ENSO_API_KEY) this.skip();
      await setup();
      // The router address is immutable: discover it with a probe quote, then deploy.
      const probe = await quote(alice.address, ZCHF, CBBTC, ethers.parseEther("1000"));
      routerAddr = probe.tx.to;
      leverage = await ethers.deployContract("LeverageGeneric", [routerAddr]);
    });

    it("flow 1: equity in ZCHF", async function () {
      const lev = await leverage.getAddress();
      const p = await leverage.preview(SOURCE, expiration, C);
      const netIn = (p.mintNet * 999n) / 1000n;

      // Price C collateral via a probe, then size equity z so that z + netIn buys ≥ C (+3% buffer).
      const probe = await quote(lev, ZCHF, CBBTC, ethers.parseEther("10000"));
      const perZchf = BigInt(probe.minAmountOut) * 10n ** 18n / ethers.parseEther("10000"); // cbBTC per 1e18 ZCHF (floor)
      const needZchf = (C * 10n ** 18n * 103n) / (perZchf * 100n);
      const z = needZchf > netIn ? needZchf - netIn : 1n;
      const amountIn = z + netIn;

      await zchf.connect(alice).approve(lev, z);
      const { route, pos } = await withSimulatedRoute(async () => {
        const route = await quote(lev, ZCHF, CBBTC, amountIn);
        expect(BigInt(route.minAmountOut)).to.be.gte(C);
        const pos = await leverage
          .connect(alice)
          .executeWithZCHF.staticCall(SOURCE, z, C, expiration, route.tx.data);
        return { route, pos };
      });
      await leverage.connect(alice).executeWithZCHF(SOURCE, z, C, expiration, route.tx.data);

      const position = await ethers.getContractAt(POS_ABI, pos);
      expect(await position.owner()).to.equal(alice.address);
      expect(await cbbtc.balanceOf(pos)).to.equal(C);
      expect(await zchf.balanceOf(lev)).to.equal(0n);
      expect(await cbbtc.balanceOf(lev)).to.equal(0n);
    });

    it("flow 2: equity in collateral", async function () {
      const lev = await leverage.getAddress();
      const p = await leverage.preview(SOURCE, expiration, C);
      const netIn = (p.mintNet * 999n) / 1000n;

      const { route, e, pos } = await withSimulatedRoute(async () => {
        const route = await quote(lev, ZCHF, CBBTC, netIn);
        const out = BigInt(route.minAmountOut); // cbBTC guaranteed by the swap
        const e = C - out + C / 100n; // borrow = C − e = out − 1% of C
        expect(e).to.be.gt(0n).and.lt(C);
        await cbbtc.connect(alice).approve(lev, e);
        const pos = await leverage
          .connect(alice)
          .executeWithCollateral.staticCall(SOURCE, e, C, expiration, route.tx.data);
        return { route, e, pos };
      });
      await leverage.connect(alice).executeWithCollateral(SOURCE, e, C, expiration, route.tx.data);

      const position = await ethers.getContractAt(POS_ABI, pos);
      expect(await position.owner()).to.equal(alice.address);
      expect(await cbbtc.balanceOf(pos)).to.equal(C);
      expect(await zchf.balanceOf(lev)).to.equal(0n);
      expect(await cbbtc.balanceOf(lev)).to.equal(0n);
    });
  });
});
