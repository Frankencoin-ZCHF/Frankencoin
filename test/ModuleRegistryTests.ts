import { expect } from "chai";
import { ethers } from "hardhat";
import { Equity, Frankencoin, ModuleRegistry } from "../typechain";
import { evm_increaseTime } from "./helper";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

// ── Mainnet addresses ────────────────────────────────────────────────────────

const ZCHF_ADDR  = "0xB58E61C3098d85632Df34EecfB899A1Ed80921cB";
const ZCHF_WHALE = "0x9642b23Ed1E01Df1092B92641051881a322F5D4E";
const FORK_BLOCK = 24977371;

// ── Constants ────────────────────────────────────────────────────────────────

const DAY          = 86400n;
const THIRTY_DAYS  = 30n * DAY;
const PROPOSAL_FEE = ethers.parseEther("1000");

// ── Helpers ──────────────────────────────────────────────────────────────────

async function parseEvent(
  registry: ModuleRegistry,
  tx: Awaited<ReturnType<typeof registry.propose>>,
  name: string
) {
  const receipt = await tx.wait();
  return receipt!.logs
    .map((log) => { try { return registry.interface.parseLog(log); } catch { return null; } })
    .find((e) => e?.name === name);
}

// ── Suite ────────────────────────────────────────────────────────────────────

describe("ModuleRegistry", function () {
  let owner:     HardhatEthersSigner;
  let alice:     HardhatEthersSigner; // proposer — funded with ZCHF from whale
  let bob:       HardhatEthersSigner; // permissionless accept caller; zero FPS
  let whale:     HardhatEthersSigner; // impersonated ZCHF whale; also invests FPS

  let zchf:     Frankencoin;
  let equity:   Equity;
  let registry: ModuleRegistry;

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

    // Fund local signers with ETH so they can send transactions
    for (const s of [owner, alice, bob]) {
      await ethers.provider.send("hardhat_setBalance", [
        s.address,
        `0x${ethers.parseEther("10").toString(16)}`,
      ]);
    }

    // Fund and impersonate ZCHF whale
    await owner.sendTransaction({ to: ZCHF_WHALE, value: ethers.parseEther("1") });
    await ethers.provider.send("hardhat_impersonateAccount", [ZCHF_WHALE]);
    whale = await ethers.getSigner(ZCHF_WHALE);

    // Attach to existing mainnet contracts
    zchf   = await ethers.getContractAt("Frankencoin", ZCHF_ADDR);
    equity = await ethers.getContractAt("Equity", await zchf.reserve());

    // Fund alice with ZCHF for proposal fees (multiple proposals across the suite)
    await zchf.connect(whale).transfer(alice.address, ethers.parseEther("10000"));

    // Whale invests ALL remaining ZCHF into FPS to maximise their voting stake.
    // Equity gets infinite ZCHF allowance from Frankencoin (_allowance returns
    // type(uint256).max when spender == address(reserve)), so no explicit approve needed.
    const investAmount = await zchf.balanceOf(ZCHF_WHALE);
    await equity.connect(whale).invest(investAmount, 0n);

    // Advance 730 days so the freshly-minted FPS votes accumulate to a meaningful
    // share before any test runs. Existing FPS holders' votes also grow, but the
    // whale's large stake makes them proportionally competitive at the 2% quorum.
    await evm_increaseTime(730n * DAY);

    // Deploy and register registry as a ZCHF minter
    registry = await ethers.deployContract("ModuleRegistry", [ZCHF_ADDR]);

    const minFee    = await zchf.MIN_FEE();
    const minPeriod = await zchf.MIN_APPLICATION_PERIOD();
    // Alice pays the suggestMinter fee — whale has no ZCHF left after full FPS investment
    await zchf.connect(alice).suggestMinter(
      await registry.getAddress(), minPeriod, minFee, "ModuleRegistry"
    );
    await evm_increaseTime(minPeriod + 1n);

    console.log("\n=== ModuleRegistry fork setup ===");
    console.log("Block    :", FORK_BLOCK);
    console.log("Registry :", await registry.getAddress());
    console.log("ZCHF     :", ZCHF_ADDR);
    console.log("Equity   :", await equity.getAddress());
    console.log("Whale FPS:", ethers.formatEther(await equity.balanceOf(ZCHF_WHALE)));
  });

  after(async function () {
    await ethers.provider.send("hardhat_reset", []);
  });

  // ── Constructor ───────────────────────────────────────────────────────────

  describe("constructor", function () {
    it("zchf reference is correct", async function () {
      expect(await registry.zchf()).to.equal(ZCHF_ADDR);
    });

    it("VETO_PERIOD is 30 days", async function () {
      expect(await registry.VETO_PERIOD()).to.equal(THIRTY_DAYS);
    });

    it("MIN_PROPOSAL_FEE is 1000 ZCHF", async function () {
      expect(await registry.MIN_PROPOSAL_FEE()).to.equal(PROPOSAL_FEE);
    });

    it("registry is a registered ZCHF minter", async function () {
      expect(await zchf.isMinter(await registry.getAddress())).to.be.true;
    });

    it("no address is active on deployment", async function () {
      expect(await registry.isActive(alice.address)).to.be.false;
      expect(await registry.isActive(bob.address)).to.be.false;
    });
  });

  // ── propose() guards ──────────────────────────────────────────────────────

  describe("propose() guards", function () {
    it("reverts FeeTooLow when fee is below the minimum", async function () {
      const block = await ethers.provider.getBlock("latest");
      const exp = BigInt(block!.timestamp) + THIRTY_DAYS + 365n * DAY;
      await zchf.connect(alice).approve(await registry.getAddress(), PROPOSAL_FEE - 1n);
      await expect(
        registry.connect(alice).propose(bob.address, PROPOSAL_FEE - 1n, exp, "")
      ).to.be.revertedWithCustomError(registry, "FeeTooLow");
    });

    it("reverts InvalidExpiration when expiration is not strictly past the veto window", async function () {
      const block = await ethers.provider.getBlock("latest");
      const tooSoon = BigInt(block!.timestamp) + THIRTY_DAYS;
      await zchf.connect(alice).approve(await registry.getAddress(), PROPOSAL_FEE);
      await expect(
        registry.connect(alice).propose(bob.address, PROPOSAL_FEE, tooSoon, "")
      ).to.be.revertedWithCustomError(registry, "InvalidExpiration");
    });
  });

  // ── Revoke path ───────────────────────────────────────────────────────────
  // alice proposes bob.address → veto window open → whale (FPS holder) revokes

  describe("propose() and revoke()", function () {
    let proposalExpiration: bigint;
    let aliceBalanceBefore: bigint;
    let reserveBalanceBefore: bigint;

    before(async function () {
      // The 730-day warp in setup gives the whale sufficient accumulated FPS
      // votes relative to existing mainnet holders. No additional warp needed.
    });

    it("emits ModuleProposed with category New", async function () {
      const block = await ethers.provider.getBlock("latest");
      proposalExpiration = BigInt(block!.timestamp) + THIRTY_DAYS + 365n * DAY;

      await zchf.connect(alice).approve(await registry.getAddress(), PROPOSAL_FEE);
      aliceBalanceBefore    = await zchf.balanceOf(alice.address);
      reserveBalanceBefore  = await zchf.balanceOf(await equity.getAddress());

      const tx    = await registry.connect(alice).propose(bob.address, PROPOSAL_FEE, proposalExpiration, "first proposal");
      const event = await parseEvent(registry, tx, "ModuleProposed");

      expect(event).to.not.be.undefined;
      expect(event!.args.module).to.equal(bob.address);
      expect(event!.args.proposer).to.equal(alice.address);
      expect(event!.args.category).to.equal(0n); // ProposalCategory.New
      expect(event!.args.expiration).to.equal(proposalExpiration);
      expect(event!.args.message).to.equal("first proposal");
    });

    it("fee is deducted from the proposer", async function () {
      expect(await zchf.balanceOf(alice.address)).to.equal(aliceBalanceBefore - PROPOSAL_FEE);
    });

    it("proposal struct is stored correctly", async function () {
      const p = await registry.proposals(bob.address);
      expect(p.proposer).to.equal(alice.address);
      expect(p.fee).to.equal(PROPOSAL_FEE);
      expect(p.expiration).to.equal(proposalExpiration);
      expect(p.activateAt).to.be.gt(0n);
    });

    it("reverts AlreadyProposed on duplicate proposal", async function () {
      const block = await ethers.provider.getBlock("latest");
      const exp = BigInt(block!.timestamp) + THIRTY_DAYS + 365n * DAY;
      await zchf.connect(alice).approve(await registry.getAddress(), PROPOSAL_FEE);
      await expect(
        registry.connect(alice).propose(bob.address, PROPOSAL_FEE, exp, "")
      ).to.be.revertedWithCustomError(registry, "AlreadyProposed");
    });

    it("reverts NoProposal when revoking an address with no pending proposal", async function () {
      await expect(
        registry.connect(whale).revoke(alice.address, [], "no proposal")
      ).to.be.revertedWithCustomError(registry, "NoProposal");
    });

    it("reverts NotQualified when the caller holds no FPS votes", async function () {
      await expect(
        registry.connect(bob).revoke(bob.address, [], "not qualified")
      ).to.be.revertedWithCustomError(equity, "NotQualified");
    });

    it("emits ModuleRevoked when a qualified FPS holder revokes within the veto window", async function () {
      await expect(registry.connect(whale).revoke(bob.address, [], "rejected"))
        .to.emit(registry, "ModuleRevoked")
        .withArgs(bob.address, ZCHF_WHALE, "rejected");
    });

    it("deposit is forwarded to the reserve as profit", async function () {
      expect(await zchf.balanceOf(await equity.getAddress())).to.be.gte(
        reserveBalanceBefore + PROPOSAL_FEE
      );
    });

    it("proposal struct is deleted after revoke", async function () {
      const p = await registry.proposals(bob.address);
      expect(p.activateAt).to.equal(0n);
    });

    it("revoked module is not active", async function () {
      expect(await registry.isActive(bob.address)).to.be.false;
    });
  });

  // ── Accept path ───────────────────────────────────────────────────────────
  // alice proposes alice.address → veto window passes → anyone calls accept()

  describe("accept()", function () {
    let proposalExpiration: bigint;
    let aliceBalanceBefore: bigint;

    it("emits ModuleProposed on a fresh proposal", async function () {
      const block = await ethers.provider.getBlock("latest");
      proposalExpiration = BigInt(block!.timestamp) + THIRTY_DAYS + 365n * DAY;

      await zchf.connect(alice).approve(await registry.getAddress(), PROPOSAL_FEE);
      aliceBalanceBefore = await zchf.balanceOf(alice.address);

      await expect(
        registry.connect(alice).propose(alice.address, PROPOSAL_FEE, proposalExpiration, "accept test")
      ).to.emit(registry, "ModuleProposed");
    });

    it("reverts VetoPeriodActive when accept is called before the window closes", async function () {
      await expect(registry.connect(bob).accept(alice.address))
        .to.be.revertedWithCustomError(registry, "VetoPeriodActive");
    });

    it("reverts VetoPeriodOver when revoke is called after the window closes", async function () {
      await evm_increaseTime(THIRTY_DAYS + 1n);
      await expect(registry.connect(whale).revoke(alice.address, [], "too late"))
        .to.be.revertedWithCustomError(registry, "VetoPeriodOver");
    });

    it("reverts NoProposal when accept is called for an address without a pending proposal", async function () {
      await expect(registry.connect(bob).accept(bob.address))
        .to.be.revertedWithCustomError(registry, "NoProposal");
    });

    it("emits ModuleAccepted with sender and expiration", async function () {
      await expect(registry.connect(bob).accept(alice.address))
        .to.emit(registry, "ModuleAccepted")
        .withArgs(alice.address, bob.address, proposalExpiration);
    });

    it("moduleExpiry is set to the proposed expiration", async function () {
      expect(await registry.moduleExpiry(alice.address)).to.equal(proposalExpiration);
    });

    it("deposit is refunded to the proposer", async function () {
      expect(await zchf.balanceOf(alice.address)).to.equal(aliceBalanceBefore);
    });

    it("proposal struct is cleared after accept", async function () {
      const p = await registry.proposals(alice.address);
      expect(p.activateAt).to.equal(0n);
      expect(p.fee).to.equal(0n);
    });

    it("module is active after accept", async function () {
      expect(await registry.isActive(alice.address)).to.be.true;
    });
  });

  // ── Minting proxy ─────────────────────────────────────────────────────────
  // alice.address is the active module; alice (signer) calls moduleMint/moduleBurn

  describe("moduleMint() and moduleBurn()", function () {
    const AMOUNT = ethers.parseEther("500");

    it("reverts NotActive for a caller that is not a registered module", async function () {
      await expect(registry.connect(bob).moduleMint(owner.address, AMOUNT))
        .to.be.revertedWithCustomError(registry, "NotActive");
      await expect(registry.connect(bob).moduleBurn(owner.address, AMOUNT))
        .to.be.revertedWithCustomError(registry, "NotActive");
    });

    it("active module can moduleMint ZCHF to any target", async function () {
      const balBefore = await zchf.balanceOf(owner.address);
      await registry.connect(alice).moduleMint(owner.address, AMOUNT);
      expect(await zchf.balanceOf(owner.address)).to.equal(balBefore + AMOUNT);
    });

    it("active module can moduleBurn ZCHF from any address (minterOnly bypasses allowance)", async function () {
      const balBefore = await zchf.balanceOf(owner.address);
      await registry.connect(alice).moduleBurn(owner.address, AMOUNT);
      expect(await zchf.balanceOf(owner.address)).to.equal(balBefore - AMOUNT);
    });
  });

  // ── Reserve proxy ─────────────────────────────────────────────────────────
  // alice.address is the active module; alice (signer) calls moduleProfit/moduleLoss

  describe("moduleProfit() and moduleLoss()", function () {
    const AMOUNT = ethers.parseEther("100");

    it("reverts NotActive for a caller that is not a registered module", async function () {
      await expect(registry.connect(bob).moduleProfit(owner.address, AMOUNT))
        .to.be.revertedWithCustomError(registry, "NotActive");
      await expect(registry.connect(bob).moduleLoss(owner.address, AMOUNT))
        .to.be.revertedWithCustomError(registry, "NotActive");
    });

    it("active module can moduleProfit — moves ZCHF from source to reserve", async function () {
      // Give owner some ZCHF to forward as profit
      await registry.connect(alice).moduleMint(owner.address, AMOUNT);

      const ownerBalBefore   = await zchf.balanceOf(owner.address);
      const reserveBalBefore = await zchf.balanceOf(await equity.getAddress());

      await registry.connect(alice).moduleProfit(owner.address, AMOUNT);

      expect(await zchf.balanceOf(owner.address)).to.equal(ownerBalBefore - AMOUNT);
      expect(await zchf.balanceOf(await equity.getAddress())).to.be.gte(reserveBalBefore + AMOUNT);
    });

    it("active module can moduleLoss — moves ZCHF from reserve to source", async function () {
      const bobBalBefore = await zchf.balanceOf(bob.address);

      await registry.connect(alice).moduleLoss(bob.address, AMOUNT);

      expect(await zchf.balanceOf(bob.address)).to.equal(bobBalBefore + AMOUNT);
      // Reserve may be topped up by minting if equity was insufficient;
      // just verify the recipient received the full amount.
    });

    it("reverts NotActive for moduleTransfer when caller is not a registered module", async function () {
      await expect(registry.connect(bob).moduleTransfer(owner.address, bob.address, AMOUNT))
        .to.be.revertedWithCustomError(registry, "NotActive");
    });

    it("active module can moduleTransfer — moves ZCHF from source to target without approval (minter infinite allowance)", async function () {
      // Mint ZCHF to owner so it has a balance to be transferred from
      await registry.connect(alice).moduleMint(owner.address, AMOUNT);

      const ownerBalBefore = await zchf.balanceOf(owner.address);
      const bobBalBefore   = await zchf.balanceOf(bob.address);

      // Module transfers from owner → bob without owner approving the registry
      await registry.connect(alice).moduleTransfer(owner.address, bob.address, AMOUNT);

      expect(await zchf.balanceOf(owner.address)).to.equal(ownerBalBefore - AMOUNT);
      expect(await zchf.balanceOf(bob.address)).to.equal(bobBalBefore + AMOUNT);
    });
  });

  // ── Extension ─────────────────────────────────────────────────────────────

  describe("propose() — extension", function () {
    let extendedExpiration: bigint;

    it("emits ModuleProposed with category Extension", async function () {
      const currentExpiry  = await registry.moduleExpiry(alice.address);
      extendedExpiration   = currentExpiry + 180n * DAY;

      await zchf.connect(alice).approve(await registry.getAddress(), PROPOSAL_FEE);
      const tx    = await registry.connect(alice).propose(alice.address, PROPOSAL_FEE, extendedExpiration, "extend TTL");
      const event = await parseEvent(registry, tx, "ModuleProposed");

      expect(event).to.not.be.undefined;
      expect(event!.args.category).to.equal(1n); // ProposalCategory.Extension
      expect(event!.args.expiration).to.equal(extendedExpiration);
    });

    it("moduleExpiry is updated to the extended value after accept", async function () {
      await evm_increaseTime(THIRTY_DAYS + 1n);
      await registry.connect(bob).accept(alice.address);
      expect(await registry.moduleExpiry(alice.address)).to.equal(extendedExpiration);
    });
  });

  // ── Retirement ────────────────────────────────────────────────────────────

  describe("propose() — retirement", function () {
    let shortLivedModule: string;
    let retireAt: bigint;

    before(async function () {
      // Set up a module with a TTL of VETO_PERIOD + 30s so that any retirement
      // attempt will push expiration past currentExpiry → InvalidExpiration.
      const block  = await ethers.provider.getBlock("latest");
      const shortTTL = BigInt(block!.timestamp) + THIRTY_DAYS + 30n;
      shortLivedModule = ethers.Wallet.createRandom().address;

      await zchf.connect(alice).approve(await registry.getAddress(), PROPOSAL_FEE);
      await registry.connect(alice).propose(shortLivedModule, PROPOSAL_FEE, shortTTL, "short lived");
      await evm_increaseTime(THIRTY_DAYS + 1n);
      await registry.connect(bob).accept(shortLivedModule);
      // shortLivedModule now has ~29 seconds of TTL left
    });

    it("reverts InvalidExpiration when remaining TTL is shorter than the veto window", async function () {
      await zchf.connect(alice).approve(await registry.getAddress(), PROPOSAL_FEE);
      await expect(
        registry.connect(alice).propose(shortLivedModule, PROPOSAL_FEE, 0n, "retire short-lived")
      ).to.be.revertedWithCustomError(registry, "InvalidExpiration");
    });

    it("emits ModuleProposed with category Retirement and overrides the expiration to activateAt", async function () {
      await zchf.connect(alice).approve(await registry.getAddress(), PROPOSAL_FEE);
      const tx    = await registry.connect(alice).propose(alice.address, PROPOSAL_FEE, 1n, "retire early");
      const event = await parseEvent(registry, tx, "ModuleProposed");

      expect(event).to.not.be.undefined;
      expect(event!.args.category).to.equal(2n); // ProposalCategory.Retirement
      retireAt = event!.args.expiration;

      const p = await registry.proposals(alice.address);
      expect(p.expiration).to.equal(retireAt);
      expect(p.activateAt).to.equal(retireAt); // expiration is overridden to activateAt
    });

    it("moduleExpiry is set to the retirement timestamp after accept", async function () {
      await evm_increaseTime(THIRTY_DAYS + 1n);
      await registry.connect(bob).accept(alice.address);
      expect(await registry.moduleExpiry(alice.address)).to.equal(retireAt);
    });

    it("module is inactive after the retirement timestamp passes", async function () {
      expect(await registry.isActive(alice.address)).to.be.false;
    });

    it("retired module cannot moduleMint", async function () {
      await expect(registry.connect(alice).moduleMint(owner.address, ethers.parseEther("1")))
        .to.be.revertedWithCustomError(registry, "NotActive");
    });
  });
});
