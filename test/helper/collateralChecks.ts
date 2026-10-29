import { expect } from "chai";
import { ethers, network } from "hardhat";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { floatToDec18 } from "../../scripts/math";
import { evm_increaseTime } from "./index";

/**
 * Reusable acceptance checks for a new Frankencoin collateral token.
 *
 * The checks mirror what the MintingHub / Position contracts rely on:
 *  - the hub requires decimals <= 24 and a transfer exceeding the balance to revert
 *  - the hub and positions ignore the return values of transfer / transferFrom, so they must be `true`
 *  - the position balance is compared to the amounts moved, so there must be no fee and no rounding dust
 *    (e.g. xStocks leave 1 wei behind on transfers)
 *
 * Usage: call `runCollateralChecks({...})` from a test file, see SwissGoldCollateralTests.ts.
 */
export interface CollateralCheckConfig {
  /** Display name used in the describe block */
  name: string;
  /** Collateral token address on the forked chain */
  token: string;
  /** Mainnet fork block, pin it for reproducible tests */
  forkBlock: number;
  /**
   * Gives `to` exactly `amount` of the collateral token (e.g. impersonate a whale, or wrap the underlying).
   * Called with the token already attached.
   */
  fund: (token: Erc20, to: HardhatEthersSigner, amount: bigint) => Promise<void>;
  /** Largest amount fund() will be asked for, 18 decimal tokens use whole units */
  maxFunding: bigint;
  /** Minimum collateral and liquidation price used for the position integration check (36 - decimals) */
  position: { minCollateral: bigint; initialCollateral: bigint; liqPrice: bigint };
}

type Erc20 = any;

const ERC20_ABI = [
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
  "function totalSupply() view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address,address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
  "function transfer(address,uint256) returns (bool)",
  "function transferFrom(address,address,uint256) returns (bool)",
  "event Transfer(address indexed,address indexed,uint256)",
];

export const resetFork = async (forkBlock: number) => {
  const alchemy = process.env.ALCHEMY_RPC_KEY;
  if (!alchemy) throw new Error("Missing ALCHEMY_RPC_KEY in .env, forking is required for collateral checks");
  await network.provider.request({
    method: "hardhat_reset",
    params: [{ forking: { jsonRpcUrl: `https://eth-mainnet.g.alchemy.com/v2/${alchemy}`, blockNumber: forkBlock } }],
  });
};

export const runCollateralChecks = (cfg: CollateralCheckConfig) => {
  describe(`Collateral checks: ${cfg.name}`, () => {
    let owner: HardhatEthersSigner;
    let alice: HardhatEthersSigner;
    let bob: HardhatEthersSigner;
    let carol: HardhatEthersSigner;
    let token: Erc20;

    // odd and awkward values on purpose, rounding errors show up on those
    const AMOUNTS = [1n, 2n, 3n, 7n, 999n, 123456789n, 10n ** 18n + 1n, 1234567890123456789n, 3n * 10n ** 18n + 17n];

    const fresh = async (to: HardhatEthersSigner, amount: bigint) => {
      await cfg.fund(token, to, amount);
      expect(await token.balanceOf(to.address)).to.be.gte(amount);
    };

    before(async () => {
      await resetFork(cfg.forkBlock);
      [owner, alice, bob, carol] = await ethers.getSigners();
      for (const s of [owner, alice, bob, carol]) {
        await network.provider.send("hardhat_setBalance", [s.address, "0x56BC75E2D63100000"]);
      }
      token = new ethers.Contract(cfg.token, ERC20_ABI, owner);
    });

    // every test starts from a clean snapshot, balances are re-funded inside the tests
    let snap: string;
    beforeEach(async () => {
      snap = await network.provider.send("evm_snapshot");
    });
    afterEach(async () => {
      await network.provider.send("evm_revert", [snap]);
    });

    describe("metadata", () => {
      it("is a contract exposing the ERC20 view functions", async () => {
        expect(await ethers.provider.getCode(cfg.token)).to.not.equal("0x");
        expect((await token.name()).length).to.be.greaterThan(0);
        expect((await token.symbol()).length).to.be.greaterThan(0);
        await token.totalSupply();
      });

      it("has decimals <= 24 (hub requirement, leaves 12 digits for the price)", async () => {
        expect(await token.decimals()).to.be.lte(24);
      });
    });

    describe("transfer semantics", () => {
      it("transfer returns true", async () => {
        await fresh(alice, 1000n);
        expect(await token.connect(alice).transfer.staticCall(bob.address, 1000n)).to.equal(true);
      });

      it("transferFrom returns true", async () => {
        await fresh(alice, 1000n);
        await token.connect(alice).approve(bob.address, 1000n);
        expect(await token.connect(bob).transferFrom.staticCall(alice.address, carol.address, 1000n)).to.equal(true);
      });

      it("approve returns true", async () => {
        expect(await token.connect(alice).approve.staticCall(bob.address, 1n)).to.equal(true);
      });

      it("reverts (does not return false) when the transfer exceeds the balance, as the hub probes it", async () => {
        // same probe as MintingHub.openPosition, sent from an account without balance
        const invalidAmount = (await token.totalSupply()) + 1n;
        await expect(token.connect(bob).transfer(ethers.getAddress("0x0000000000000000000000000000000000000123"), invalidAmount)).to
          .be.reverted;
        await fresh(alice, 100n);
        await expect(token.connect(alice).transfer(bob.address, 101n)).to.be.reverted;
      });

      it("transferFrom reverts without sufficient allowance", async () => {
        await fresh(alice, 100n);
        await token.connect(alice).approve(bob.address, 99n);
        await expect(token.connect(bob).transferFrom(alice.address, carol.address, 100n)).to.be.reverted;
      });

      it("transferFrom consumes exactly the allowance used", async () => {
        await fresh(alice, 1000n);
        await token.connect(alice).approve(bob.address, 1000n);
        await token.connect(bob).transferFrom(alice.address, carol.address, 400n);
        expect(await token.allowance(alice.address, bob.address)).to.equal(600n);
      });

      it("emits a Transfer event with the exact amount", async () => {
        await fresh(alice, 12345n);
        await expect(token.connect(alice).transfer(bob.address, 12345n))
          .to.emit(token, "Transfer")
          .withArgs(alice.address, bob.address, 12345n);
      });
    });

    describe("no fees", () => {
      for (const amount of AMOUNTS) {
        it(`transfer of ${amount} moves exactly ${amount}`, async () => {
          await fresh(alice, amount);
          const supply = await token.totalSupply();
          const [a0, b0] = [await token.balanceOf(alice.address), await token.balanceOf(bob.address)];

          await token.connect(alice).transfer(bob.address, amount);

          expect(await token.balanceOf(alice.address)).to.equal(a0 - amount);
          expect(await token.balanceOf(bob.address)).to.equal(b0 + amount);
          expect(await token.totalSupply()).to.equal(supply);
        });

        it(`transferFrom of ${amount} moves exactly ${amount}`, async () => {
          await fresh(alice, amount);
          const supply = await token.totalSupply();
          const [a0, c0] = [await token.balanceOf(alice.address), await token.balanceOf(carol.address)];

          await token.connect(alice).approve(bob.address, amount);
          await token.connect(bob).transferFrom(alice.address, carol.address, amount);

          expect(await token.balanceOf(alice.address)).to.equal(a0 - amount);
          expect(await token.balanceOf(carol.address)).to.equal(c0 + amount);
          expect(await token.balanceOf(bob.address)).to.equal(0n); // spender never holds anything
          expect(await token.totalSupply()).to.equal(supply);
        });
      }

      it("transfer to self does not change the balance or supply", async () => {
        await fresh(alice, 1234567n);
        const supply = await token.totalSupply();
        await token.connect(alice).transfer(alice.address, 1234567n);
        expect(await token.balanceOf(alice.address)).to.equal(1234567n);
        expect(await token.totalSupply()).to.equal(supply);
      });

      it("a chain of transfers loses nothing", async () => {
        const amount = 3n * 10n ** 18n + 17n;
        await fresh(alice, amount);
        const supply = await token.totalSupply();
        await token.connect(alice).transfer(bob.address, amount);
        await token.connect(bob).transfer(carol.address, amount);
        await token.connect(carol).transfer(alice.address, amount);
        expect(await token.balanceOf(alice.address)).to.equal(amount);
        expect(await token.balanceOf(bob.address)).to.equal(0n);
        expect(await token.balanceOf(carol.address)).to.equal(0n);
        expect(await token.totalSupply()).to.equal(supply);
      });
    });

    describe("full balance moves, nothing is left behind (no 1 wei rounding dust)", () => {
      for (const amount of AMOUNTS) {
        it(`transfer of the whole balance ${amount} leaves 0`, async () => {
          await fresh(alice, amount);
          const balance = await token.balanceOf(alice.address);
          await token.connect(alice).transfer(bob.address, balance);
          expect(await token.balanceOf(alice.address)).to.equal(0n);
          expect(await token.balanceOf(bob.address)).to.equal(balance);
        });

        it(`transferFrom of the whole balance ${amount} leaves 0`, async () => {
          await fresh(alice, amount);
          const balance = await token.balanceOf(alice.address);
          await token.connect(alice).approve(bob.address, balance);
          await token.connect(bob).transferFrom(alice.address, carol.address, balance);
          expect(await token.balanceOf(alice.address)).to.equal(0n);
          expect(await token.balanceOf(carol.address)).to.equal(balance);
          expect(await token.allowance(alice.address, bob.address)).to.equal(0n);
        });
      }

      it("the largest funded balance moves completely", async () => {
        await fresh(alice, cfg.maxFunding);
        const balance = await token.balanceOf(alice.address);
        await token.connect(alice).transfer(bob.address, balance);
        expect(await token.balanceOf(alice.address)).to.equal(0n);
        expect(await token.balanceOf(bob.address)).to.equal(balance);
      });

      it("splitting a balance in parts and sending it on leaves 0", async () => {
        const amount = 1000000000000000001n;
        await fresh(alice, amount);
        const part = amount / 3n;
        await token.connect(alice).transfer(bob.address, part);
        await token.connect(alice).transfer(bob.address, part);
        await token.connect(alice).transfer(bob.address, amount - 2n * part);
        expect(await token.balanceOf(alice.address)).to.equal(0n);
        expect(await token.balanceOf(bob.address)).to.equal(amount);
      });
    });

    describe("Frankencoin integration (real MintingHub and Position)", () => {
      let zchf: any;
      let hub: any;
      let positionAddr: string;

      const open = async (initial: bigint) => {
        await fresh(alice, initial);
        await token.connect(alice).approve(await hub.getAddress(), initial);
        const tx = await (
          await hub
            .connect(alice)
            .openPosition(
              cfg.token,
              cfg.position.minCollateral,
              initial,
              floatToDec18(100_000),
              3 * 86_400,
              100 * 86_400,
              86_400,
              10000,
              cfg.position.liqPrice,
              100000
            )
        ).wait();
        const topic = "0xc9b570ab9d98bdf3e38a40fd71b20edafca42449f23ca51f0bdcbf40e8ffe175"; // PositionOpened
        const log = tx.logs.find((x: any) => x.topics.indexOf(topic) >= 0);
        positionAddr = "0x" + log.topics[2].substring(26);
      };

      beforeEach(async () => {
        zchf = await (await ethers.getContractFactory("Frankencoin")).deploy(5 * 86400);
        const factory = await (await ethers.getContractFactory("PositionFactory")).deploy();
        const savings = await (await ethers.getContractFactory("Savings")).deploy(await zchf.getAddress(), 20000n);
        const roller = await (await ethers.getContractFactory("contracts/minting/PositionRoller.sol:PositionRoller")).deploy(await zchf.getAddress());
        hub = await (
          await ethers.getContractFactory("MintingHub")
        ).deploy(
          await zchf.getAddress(),
          await savings.getAddress(),
          await roller.getAddress(),
          await factory.getAddress()
        );
        await zchf.initialize(owner.address, "owner");
        await zchf.initialize(await hub.getAddress(), "mintingHub");
        await zchf.mint(owner.address, floatToDec18(2_000_000));
        const equity = await ethers.getContractAt("Equity", await zchf.reserve());
        await equity.invest(floatToDec18(1_000_000), 0);
        await zchf.transfer(alice.address, floatToDec18(10_000)); // covers the opening fee
        await zchf.connect(alice).approve(await hub.getAddress(), floatToDec18(10_000));
      });

      it("MintingHub accepts the token as collateral (no IncompatibleCollateral)", async () => {
        await open(cfg.position.initialCollateral);
        const position = await ethers.getContractAt("Position", positionAddr);
        expect(await position.collateral()).to.equal(ethers.getAddress(cfg.token));
      });

      it("position holds exactly the deposited collateral", async () => {
        await open(cfg.position.initialCollateral);
        expect(await token.balanceOf(positionAddr)).to.equal(cfg.position.initialCollateral);
        expect(await token.balanceOf(alice.address)).to.equal(0n);
      });

      it("owner gets back the entire collateral on withdrawal, nothing stays in the position", async () => {
        await open(cfg.position.initialCollateral);
        const position = await ethers.getContractAt("Position", positionAddr, alice);
        await evm_increaseTime(3 * 86_400 + 300);
        await position.withdrawCollateral(alice.address, cfg.position.initialCollateral);
        expect(await token.balanceOf(positionAddr)).to.equal(0n);
        expect(await token.balanceOf(alice.address)).to.equal(cfg.position.initialCollateral);
      });

      it("adding collateral via adjust is accounted exactly", async () => {
        await open(cfg.position.initialCollateral);
        const position = await ethers.getContractAt("Position", positionAddr, alice);
        const extra = 1234567890123456789n;
        const total = cfg.position.initialCollateral + extra;
        await fresh(alice, extra);
        await token.connect(alice).approve(positionAddr, extra);
        await position.adjust(0, total, cfg.position.liqPrice);
        expect(await token.balanceOf(positionAddr)).to.equal(total);
      });

      describe("MintingHub flows: challenge, bid, forced sale", () => {
        const DAY = 86_400;
        const MINTED = floatToDec18(5_000);
        let position: any;
        let hubAddr: string;
        let initial: bigint;
        let phase: bigint;

        // Everything the hub holds must be explained by open challenges or postponed returns, ZCHF never stays in the hub
        const expectHubClean = async (pendingCollateral = 0n) => {
          expect(await token.balanceOf(hubAddr)).to.equal(pendingCollateral);
          expect(await zchf.balanceOf(hubAddr)).to.equal(0n);
        };

        const challenge = async (size: bigint) => {
          await fresh(bob, size);
          await token.connect(bob).approve(hubAddr, size);
          await hub.connect(bob).challenge(positionAddr, size, 0);
        };

        beforeEach(async () => {
          initial = cfg.position.initialCollateral;
          await open(initial);
          position = await ethers.getContractAt("Position", positionAddr, alice);
          hubAddr = await hub.getAddress();
          phase = await position.challengePeriod();
          await evm_increaseTime(3 * DAY + 300);
          await position.mint(alice.address, MINTED);
          for (const s of [bob, carol]) {
            await zchf.transfer(s.address, floatToDec18(100_000));
            await zchf.connect(s).approve(hubAddr, ethers.MaxUint256);
          }
        });

        it("challenge locks exactly the challenged collateral in the hub", async () => {
          await challenge(initial);
          expect(await token.balanceOf(bob.address)).to.equal(0n);
          expect(await position.challengedAmount()).to.equal(initial);
          await expectHubClean(initial);
        });

        it("averting a challenge (bid in phase 1) pays the challenger and releases exactly the size", async () => {
          await challenge(initial);
          await evm_increaseTime(60);
          const bobZchf = await zchf.balanceOf(bob.address);
          await hub.connect(carol).bid(0, initial, false);
          expect(await zchf.balanceOf(bob.address)).to.equal(bobZchf + (initial * cfg.position.liqPrice) / 10n ** 18n);
          expect(await token.balanceOf(carol.address)).to.equal(initial);
          expect(await position.challengedAmount()).to.equal(0n);
          expect(await token.balanceOf(positionAddr)).to.equal(initial);
          await expectHubClean();
        });

        it("partially averting leaves the rest of the challenge open and accounted", async () => {
          await challenge(initial);
          await evm_increaseTime(60);
          const part = 1000000000000000001n;
          await hub.connect(carol).bid(0, part, false);
          expect(await token.balanceOf(carol.address)).to.equal(part);
          expect(await position.challengedAmount()).to.equal(initial - part);
          await expectHubClean(initial - part);
          await hub.connect(carol).bid(0, initial, false); // clamps to the rest
          expect(await token.balanceOf(carol.address)).to.equal(initial);
          await expectHubClean();
        });

        it("successful challenge of the whole position: bidder gets the collateral, challenger gets theirs back, debt is cleared", async () => {
          await challenge(initial);
          await evm_increaseTime(DAY + 60);
          await hub.connect(carol).bid(0, initial, false);
          expect(await token.balanceOf(bob.address)).to.equal(initial); // challenger collateral returned in full
          expect(await token.balanceOf(carol.address)).to.equal(initial);
          expect(await token.balanceOf(positionAddr)).to.equal(0n);
          expect(await position.minted()).to.equal(0n);
          expect(await position.challengedAmount()).to.equal(0n);
          expect(await position.isClosed()).to.equal(true);
          await expectHubClean();
        });

        it("successful partial challenge with an odd size leaves no dust anywhere", async () => {
          const size = cfg.position.minCollateral + 1n;
          await challenge(size);
          await evm_increaseTime(DAY + 60);
          await hub.connect(carol).bid(0, size, false);
          expect(await token.balanceOf(bob.address)).to.equal(size);
          expect(await token.balanceOf(carol.address)).to.equal(size);
          expect(await token.balanceOf(positionAddr)).to.equal(initial - size);
          expect(await position.challengedAmount()).to.equal(0n);
          await expectHubClean();
        });

        it("late bid below the debt (bad debt) clears the position and leaves nothing in the hub", async () => {
          await challenge(initial);
          await evm_increaseTime((DAY * 19) / 10); // ~90% into phase 2, price ~10% of liq price
          await hub.connect(carol).bid(0, initial, false);
          expect(await token.balanceOf(carol.address)).to.equal(initial);
          expect(await position.minted()).to.equal(0n);
          await expectHubClean();
        });

        it("postponed collateral return is held exactly and can be claimed in full", async () => {
          await challenge(initial);
          await evm_increaseTime(DAY + 60);
          await hub.connect(carol).bid(0, initial, true);
          expect(await token.balanceOf(bob.address)).to.equal(0n);
          expect(await hub.pendingReturns(cfg.token, bob.address)).to.equal(initial);
          await expectHubClean(initial);
          await hub.connect(bob).returnPostponedCollateral(cfg.token, bob.address);
          expect(await token.balanceOf(bob.address)).to.equal(initial);
          await expectHubClean();
        });

        describe("forced sale of an expired position", () => {
          const expireAndAge = async (extra: bigint) => {
            const expiration = await position.expiration();
            await network.provider.send("evm_setNextBlockTimestamp", [Number(expiration + extra)]);
            await network.provider.send("evm_mine");
          };

          it("buying everything repays the debt and moves all collateral to the buyer", async () => {
            await expireAndAge(phase); // 1x liquidation price
            const aliceZchf = await zchf.balanceOf(alice.address);
            await hub.connect(carol).buyExpiredCollateral(positionAddr, ethers.MaxUint256);
            expect(await token.balanceOf(carol.address)).to.equal(initial);
            expect(await token.balanceOf(positionAddr)).to.equal(0n);
            expect(await position.minted()).to.equal(0n);
            expect(await zchf.balanceOf(alice.address)).to.be.gt(aliceZchf); // surplus goes to the owner
            await expectHubClean();
          });

          it("buying an odd partial amount moves exactly that amount", async () => {
            await expireAndAge(phase);
            const part = 1000000000000000001n;
            await hub.connect(carol).buyExpiredCollateral(positionAddr, part);
            expect(await token.balanceOf(carol.address)).to.equal(part);
            expect(await token.balanceOf(positionAddr)).to.equal(initial - part);
            await expectHubClean();
          });

          it("buying in two parts sums up exactly", async () => {
            await expireAndAge(phase);
            const part = 1000000000000000001n;
            await hub.connect(carol).buyExpiredCollateral(positionAddr, part);
            await hub.connect(carol).buyExpiredCollateral(positionAddr, ethers.MaxUint256);
            expect(await token.balanceOf(carol.address)).to.equal(initial);
            expect(await token.balanceOf(positionAddr)).to.equal(0n);
            expect(await position.minted()).to.equal(0n);
            await expectHubClean();
          });

          it("free phase (price 0) clears the bad debt and leaves nothing behind", async () => {
            await expireAndAge(2n * phase + 1n);
            await hub.connect(carol).buyExpiredCollateral(positionAddr, ethers.MaxUint256);
            expect(await token.balanceOf(carol.address)).to.equal(initial);
            expect(await token.balanceOf(positionAddr)).to.equal(0n);
            expect(await position.minted()).to.equal(0n);
            await expectHubClean();
          });

          it("is blocked while a challenge is open", async () => {
            await challenge(cfg.position.minCollateral);
            await expireAndAge(phase);
            await expect(hub.connect(carol).buyExpiredCollateral(positionAddr, ethers.MaxUint256)).to.be.reverted;
          });
        });
      });
    });
  });
};
