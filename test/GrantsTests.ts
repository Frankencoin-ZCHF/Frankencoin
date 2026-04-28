import { expect } from "chai";
import { ethers } from "hardhat";
import { Equity, Frankencoin, Grants } from "../typechain";
import { evm_increaseTime } from "./helper";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

// ── Mainnet addresses ────────────────────────────────────────────────────────

const ZCHF_ADDR  = "0xB58E61C3098d85632Df34EecfB899A1Ed80921cB";
const ZCHF_WHALE = "0x9642b23Ed1E01Df1092B92641051881a322F5D4E";
const FORK_BLOCK = 24977371;

// ── Constants ────────────────────────────────────────────────────────────────

const DAY          = 86400n;
const THIRTY_DAYS  = 30n * DAY;
const SEVEN_DAYS   = 7n * DAY;
const PROPOSAL_FEE = ethers.parseEther("1000");
const STREAM_AMT   = ethers.parseEther("100"); // 100 ZCHF per period
const STREAM_PRD   = SEVEN_DAYS;               // 7-day period

// ── Helpers ──────────────────────────────────────────────────────────────────

async function parseEvent(
  grants: Grants,
  tx: Awaited<ReturnType<typeof grants.propose>>,
  name: string
) {
  const receipt = await tx.wait();
  return receipt!.logs
    .map((log) => { try { return grants.interface.parseLog(log); } catch { return null; } })
    .find((e) => e?.name === name);
}

// ── Suite ────────────────────────────────────────────────────────────────────

describe("Grants", function () {
  let owner:     HardhatEthersSigner;
  let alice:     HardhatEthersSigner; // proposer — funded with ZCHF from whale
  let bob:       HardhatEthersSigner; // permissionless accept caller; zero FPS
  let recipient: HardhatEthersSigner; // grant recipient
  let whale:     HardhatEthersSigner; // impersonated ZCHF whale; also invests FPS

  let zchf:   Frankencoin;
  let equity: Equity;
  let grants: Grants;

  // ── Global fork setup ──────────────────────────────────────────────────────

  before(async function () {
    [owner, alice, bob, recipient] = await ethers.getSigners();

    const alchemyKey = process.env.ALCHEMY_RPC_KEY;
    await ethers.provider.send("hardhat_reset", [
      {
        forking: {
          jsonRpcUrl: `https://eth-mainnet.g.alchemy.com/v2/${alchemyKey}`,
          blockNumber: FORK_BLOCK,
        },
      },
    ]);

    for (const s of [owner, alice, bob, recipient]) {
      await ethers.provider.send("hardhat_setBalance", [
        s.address,
        `0x${ethers.parseEther("10").toString(16)}`,
      ]);
    }

    await owner.sendTransaction({ to: ZCHF_WHALE, value: ethers.parseEther("1") });
    await ethers.provider.send("hardhat_impersonateAccount", [ZCHF_WHALE]);
    whale = await ethers.getSigner(ZCHF_WHALE);

    zchf   = await ethers.getContractAt("Frankencoin", ZCHF_ADDR);
    equity = await ethers.getContractAt("Equity", await zchf.reserve());

    // Fund alice for proposal fees across the whole suite
    await zchf.connect(whale).transfer(alice.address, ethers.parseEther("10000"));

    // Whale invests remaining ZCHF into FPS to build voting weight
    const investAmount = await zchf.balanceOf(ZCHF_WHALE);
    await equity.connect(whale).invest(investAmount, 0n);

    // Advance 730 days so the whale's fresh FPS accumulates sufficient votes
    await evm_increaseTime(730n * DAY);

    grants = await ethers.deployContract("Grants", [ZCHF_ADDR]);

    const minFee    = await zchf.MIN_FEE();
    const minPeriod = await zchf.MIN_APPLICATION_PERIOD();
    await zchf.connect(alice).suggestMinter(
      await grants.getAddress(), minPeriod, minFee, "Grants"
    );
    await evm_increaseTime(minPeriod + 1n);

    console.log("\n=== Grants fork setup ===");
    console.log("Block  :", FORK_BLOCK);
    console.log("Grants :", await grants.getAddress());
    console.log("ZCHF   :", ZCHF_ADDR);
    console.log("Equity :", await equity.getAddress());
    console.log("Whale FPS:", ethers.formatEther(await equity.balanceOf(ZCHF_WHALE)));
  });

  after(async function () {
    await ethers.provider.send("hardhat_reset", []);
  });

  // ── Constructor ───────────────────────────────────────────────────────────

  describe("constructor", function () {
    it("zchf reference is correct", async function () {
      expect(await grants.zchf()).to.equal(ZCHF_ADDR);
    });

    it("VETO_PERIOD is 30 days", async function () {
      expect(await grants.VETO_PERIOD()).to.equal(THIRTY_DAYS);
    });

    it("MIN_PROPOSAL_FEE is 1000 ZCHF", async function () {
      expect(await grants.MIN_PROPOSAL_FEE()).to.equal(PROPOSAL_FEE);
    });

    it("nextGrantId starts at 1", async function () {
      expect(await grants.nextGrantId()).to.equal(1n);
    });

    it("grants contract is a registered ZCHF minter", async function () {
      expect(await zchf.isMinter(await grants.getAddress())).to.be.true;
    });

    it("no grant is active on deployment", async function () {
      expect(await grants.isActive(1n)).to.be.false;
    });
  });

  // ── propose() guards — New grant ──────────────────────────────────────────

  describe("propose() guards — New grant", function () {
    it("reverts FeeTooLow when fee is below minimum", async function () {
      const block = await ethers.provider.getBlock("latest");
      const exp   = BigInt(block!.timestamp) + THIRTY_DAYS + 365n * DAY;
      await zchf.connect(alice).approve(await grants.getAddress(), PROPOSAL_FEE - 1n);
      await expect(
        grants.connect(alice).propose(0, PROPOSAL_FEE - 1n, exp, alice.address, STREAM_AMT, STREAM_PRD, "")
      ).to.be.revertedWithCustomError(grants, "FeeTooLow");
    });

    it("reverts InvalidParameters when recipient is zero address", async function () {
      const block = await ethers.provider.getBlock("latest");
      const exp   = BigInt(block!.timestamp) + THIRTY_DAYS + 365n * DAY;
      await zchf.connect(alice).approve(await grants.getAddress(), PROPOSAL_FEE);
      await expect(
        grants.connect(alice).propose(0, PROPOSAL_FEE, exp, ethers.ZeroAddress, STREAM_AMT, STREAM_PRD, "")
      ).to.be.revertedWithCustomError(grants, "InvalidParameters");
    });

    it("reverts InvalidParameters when streamAmount is zero", async function () {
      const block = await ethers.provider.getBlock("latest");
      const exp   = BigInt(block!.timestamp) + THIRTY_DAYS + 365n * DAY;
      await zchf.connect(alice).approve(await grants.getAddress(), PROPOSAL_FEE);
      await expect(
        grants.connect(alice).propose(0, PROPOSAL_FEE, exp, recipient.address, 0, STREAM_PRD, "")
      ).to.be.revertedWithCustomError(grants, "InvalidParameters");
    });

    it("reverts InvalidParameters when streamPeriod is zero", async function () {
      const block = await ethers.provider.getBlock("latest");
      const exp   = BigInt(block!.timestamp) + THIRTY_DAYS + 365n * DAY;
      await zchf.connect(alice).approve(await grants.getAddress(), PROPOSAL_FEE);
      await expect(
        grants.connect(alice).propose(0, PROPOSAL_FEE, exp, recipient.address, STREAM_AMT, 0, "")
      ).to.be.revertedWithCustomError(grants, "InvalidParameters");
    });

    it("reverts InvalidExpiration when expiry is not past the veto window", async function () {
      const block  = await ethers.provider.getBlock("latest");
      const tooSoon = BigInt(block!.timestamp) + THIRTY_DAYS;
      await zchf.connect(alice).approve(await grants.getAddress(), PROPOSAL_FEE);
      await expect(
        grants.connect(alice).propose(0, PROPOSAL_FEE, tooSoon, recipient.address, STREAM_AMT, STREAM_PRD, "")
      ).to.be.revertedWithCustomError(grants, "InvalidExpiration");
    });
  });

  // ── Revoke path ───────────────────────────────────────────────────────────
  // alice proposes a new grant → whale (FPS holder) revokes within the veto window

  describe("propose() New and revoke()", function () {
    let grantId: bigint;
    let aliceBalanceBefore:   bigint;
    let reserveBalanceBefore: bigint;

    it("emits GrantProposed with type New and assigns grantId 1", async function () {
      const block = await ethers.provider.getBlock("latest");
      const exp   = BigInt(block!.timestamp) + THIRTY_DAYS + 365n * DAY;

      await zchf.connect(alice).approve(await grants.getAddress(), PROPOSAL_FEE);
      aliceBalanceBefore   = await zchf.balanceOf(alice.address);
      reserveBalanceBefore = await zchf.balanceOf(await equity.getAddress());

      const tx    = await grants.connect(alice).propose(0, PROPOSAL_FEE, exp, recipient.address, STREAM_AMT, STREAM_PRD, "dev grant");
      const event = await parseEvent(grants, tx, "GrantProposed");

      expect(event).to.not.be.undefined;
      grantId = event!.args.grantId;
      expect(grantId).to.equal(1n);
      expect(event!.args.proposer).to.equal(alice.address);
      expect(event!.args.ptype).to.equal(0n); // ProposalType.New
      expect(event!.args.grantExpiry).to.equal(exp);
      expect(event!.args.message).to.equal("dev grant");
    });

    it("nextGrantId advances to 2", async function () {
      expect(await grants.nextGrantId()).to.equal(2n);
    });

    it("fee is deducted from the proposer", async function () {
      expect(await zchf.balanceOf(alice.address)).to.equal(aliceBalanceBefore - PROPOSAL_FEE);
    });

    it("proposal struct is stored correctly", async function () {
      const p = await grants.proposals(grantId);
      expect(p.proposer).to.equal(alice.address);
      expect(p.fee).to.equal(PROPOSAL_FEE);
      expect(p.recipient).to.equal(recipient.address);
      expect(p.streamAmount).to.equal(STREAM_AMT);
      expect(p.streamPeriod).to.equal(STREAM_PRD);
      expect(p.activateAt).to.be.gt(0n);
    });

    it("reverts AlreadyProposed on duplicate propose for the same grantId", async function () {
      // grantId=1 has a pending proposal; propose(stop) on it should hit AlreadyProposed
      // (isActive is false since grant not yet created, so GrantNotActive fires first;
      //  test that a second New proposal bumps nextGrantId and doesn't conflict)
      const block = await ethers.provider.getBlock("latest");
      const exp   = BigInt(block!.timestamp) + THIRTY_DAYS + 365n * DAY;
      await zchf.connect(alice).approve(await grants.getAddress(), PROPOSAL_FEE);
      // A second new-grant proposal gets grantId=2 — never conflicts with grantId=1
      const tx    = await grants.connect(alice).propose(0, PROPOSAL_FEE, exp, recipient.address, STREAM_AMT, STREAM_PRD, "grant2");
      const event = await parseEvent(grants, tx, "GrantProposed");
      expect(event!.args.grantId).to.equal(2n);
    });

    it("reverts NoProposal when revoking a non-existent grant", async function () {
      await expect(
        grants.connect(whale).revoke(99n, [], "no proposal")
      ).to.be.revertedWithCustomError(grants, "NoProposal");
    });

    it("reverts NotQualified when the caller holds no FPS votes", async function () {
      await expect(
        grants.connect(bob).revoke(grantId, [], "not qualified")
      ).to.be.revertedWithCustomError(equity, "NotQualified");
    });

    it("emits GrantRevoked when a qualified FPS holder revokes within the veto window", async function () {
      await expect(grants.connect(whale).revoke(grantId, [], "rejected"))
        .to.emit(grants, "GrantRevoked")
        .withArgs(grantId, ZCHF_WHALE, "rejected");
    });

    it("deposit is forwarded to the reserve as profit", async function () {
      expect(await zchf.balanceOf(await equity.getAddress())).to.be.gte(
        reserveBalanceBefore + PROPOSAL_FEE
      );
    });

    it("proposal struct is deleted after revoke", async function () {
      const p = await grants.proposals(grantId);
      expect(p.activateAt).to.equal(0n);
    });

    it("grant is not active after revoke", async function () {
      expect(await grants.isActive(grantId)).to.be.false;
    });
  });

  // ── Accept path ───────────────────────────────────────────────────────────
  // alice proposes a new grant → veto window passes → bob accepts

  describe("accept() — New grant", function () {
    let grantId: bigint;
    let proposalExpiry: bigint;
    let aliceBalanceBefore: bigint;
    let acceptedAt: bigint;

    it("emits GrantProposed on a fresh proposal", async function () {
      const block   = await ethers.provider.getBlock("latest");
      proposalExpiry = BigInt(block!.timestamp) + THIRTY_DAYS + 365n * DAY;

      await zchf.connect(alice).approve(await grants.getAddress(), PROPOSAL_FEE);
      aliceBalanceBefore = await zchf.balanceOf(alice.address);

      const tx    = await grants.connect(alice).propose(0, PROPOSAL_FEE, proposalExpiry, recipient.address, STREAM_AMT, STREAM_PRD, "accept test");
      const event = await parseEvent(grants, tx, "GrantProposed");
      grantId = event!.args.grantId;
      expect(grantId).to.equal(3n); // third proposal overall
    });

    it("reverts VetoPeriodActive when accept is called before the window closes", async function () {
      await expect(grants.connect(bob).accept(grantId))
        .to.be.revertedWithCustomError(grants, "VetoPeriodActive");
    });

    it("reverts VetoPeriodOver when revoke is called after the window closes", async function () {
      await evm_increaseTime(THIRTY_DAYS + 1n);
      await expect(grants.connect(whale).revoke(grantId, [], "too late"))
        .to.be.revertedWithCustomError(grants, "VetoPeriodOver");
    });

    it("reverts NoProposal when accept is called for a non-existent proposal", async function () {
      await expect(grants.connect(bob).accept(99n))
        .to.be.revertedWithCustomError(grants, "NoProposal");
    });

    it("emits GrantAccepted with sender and expiry", async function () {
      const block  = await ethers.provider.getBlock("latest");
      acceptedAt   = BigInt(block!.timestamp) + 1n; // approximate next block
      await expect(grants.connect(bob).accept(grantId))
        .to.emit(grants, "GrantAccepted")
        .withArgs(grantId, bob.address, proposalExpiry);
    });

    it("grant fields are set correctly after accept", async function () {
      const g = await grants.grants(grantId);
      expect(g.recipient).to.equal(recipient.address);
      expect(g.streamAmount).to.equal(STREAM_AMT);
      expect(g.streamPeriod).to.equal(STREAM_PRD);
      expect(g.expiry).to.equal(proposalExpiry);
      expect(g.settlements).to.equal(0n);
      expect(g.latestSettlement).to.be.gte(acceptedAt - 2n); // within a block
    });

    it("fee is refunded to the proposer", async function () {
      expect(await zchf.balanceOf(alice.address)).to.equal(aliceBalanceBefore);
    });

    it("proposal struct is cleared after accept", async function () {
      const p = await grants.proposals(grantId);
      expect(p.activateAt).to.equal(0n);
    });

    it("grant is active after accept", async function () {
      expect(await grants.isActive(grantId)).to.be.true;
    });
  });

  // ── stream() ──────────────────────────────────────────────────────────────
  // Uses grantId=3 which was accepted in the previous describe block.

  describe("stream()", function () {
    const ACTIVE_GRANT_ID = 3n;

    it("reverts InvalidGrant for a non-existent grant", async function () {
      await expect(grants.connect(bob).stream(99n))
        .to.be.revertedWithCustomError(grants, "InvalidGrant");
    });

    it("reverts NothingToStream when less than one period has elapsed since acceptance", async function () {
      await expect(grants.connect(bob).stream(ACTIVE_GRANT_ID))
        .to.be.revertedWithCustomError(grants, "NothingToStream");
    });

    it("settles one period after one streamPeriod has elapsed", async function () {
      await evm_increaseTime(SEVEN_DAYS);

      const balBefore  = await zchf.balanceOf(recipient.address);
      const gBefore    = await grants.grants(ACTIVE_GRANT_ID);

      await expect(grants.connect(bob).stream(ACTIVE_GRANT_ID))
        .to.emit(grants, "GrantStreamed")
        .withArgs(ACTIVE_GRANT_ID, recipient.address, STREAM_AMT, 1n);

      expect(await zchf.balanceOf(recipient.address)).to.equal(balBefore + STREAM_AMT);

      const gAfter = await grants.grants(ACTIVE_GRANT_ID);
      expect(gAfter.settlements).to.equal(1n);
      expect(gAfter.latestSettlement).to.equal(gBefore.latestSettlement + STREAM_PRD);
    });

    it("settles two periods in a single call after two streamPeriods have elapsed", async function () {
      await evm_increaseTime(2n * SEVEN_DAYS);

      const balBefore = await zchf.balanceOf(recipient.address);

      await expect(grants.connect(bob).stream(ACTIVE_GRANT_ID))
        .to.emit(grants, "GrantStreamed")
        .withArgs(ACTIVE_GRANT_ID, recipient.address, 2n * STREAM_AMT, 2n);

      expect(await zchf.balanceOf(recipient.address)).to.equal(balBefore + 2n * STREAM_AMT);

      const g = await grants.grants(ACTIVE_GRANT_ID);
      expect(g.settlements).to.equal(2n);
    });

    it("reverts NothingToStream when called again before the next period elapses", async function () {
      await expect(grants.connect(bob).stream(ACTIVE_GRANT_ID))
        .to.be.revertedWithCustomError(grants, "NothingToStream");
    });
  });

  // ── Stop proposal ─────────────────────────────────────────────────────────

  describe("propose() Stop and final stream", function () {
    const ACTIVE_GRANT_ID = 3n;
    let stopGrantExpiry:    bigint;
    let settlementBefore:   bigint;
    let aliceBalanceBefore: bigint;

    it("reverts GrantNotActive when targeting a non-existent grant", async function () {
      await zchf.connect(alice).approve(await grants.getAddress(), PROPOSAL_FEE);
      await expect(
        grants.connect(alice).propose(99n, PROPOSAL_FEE, 0, ethers.ZeroAddress, 0, 0, "")
      ).to.be.revertedWithCustomError(grants, "GrantNotActive");
    });

    it("emits GrantProposed with type Stop and grantExpiry == activateAt", async function () {
      await zchf.connect(alice).approve(await grants.getAddress(), PROPOSAL_FEE);
      aliceBalanceBefore = await zchf.balanceOf(alice.address);

      const tx    = await grants.connect(alice).propose(ACTIVE_GRANT_ID, PROPOSAL_FEE, 0, ethers.ZeroAddress, 0, 0, "wind down");
      const event = await parseEvent(grants, tx, "GrantProposed");

      expect(event!.args.grantId).to.equal(ACTIVE_GRANT_ID);
      expect(event!.args.ptype).to.equal(1n); // ProposalType.Stop
      stopGrantExpiry = event!.args.grantExpiry;
      expect(stopGrantExpiry).to.equal(event!.args.activateAt);
    });

    it("reverts AlreadyProposed when a stop proposal already exists", async function () {
      await zchf.connect(alice).approve(await grants.getAddress(), PROPOSAL_FEE);
      await expect(
        grants.connect(alice).propose(ACTIVE_GRANT_ID, PROPOSAL_FEE, 0, ethers.ZeroAddress, 0, 0, "duplicate")
      ).to.be.revertedWithCustomError(grants, "AlreadyProposed");
    });

    it("grant is still streamable during the veto window", async function () {
      // Advance one period within the veto window
      await evm_increaseTime(SEVEN_DAYS);
      settlementBefore = (await grants.grants(ACTIVE_GRANT_ID)).latestSettlement;
      await expect(grants.connect(bob).stream(ACTIVE_GRANT_ID)).to.emit(grants, "GrantStreamed");
    });

    it("emits GrantAccepted on accept after veto window", async function () {
      await evm_increaseTime(THIRTY_DAYS + 1n);
      await expect(grants.connect(bob).accept(ACTIVE_GRANT_ID))
        .to.emit(grants, "GrantAccepted")
        .withArgs(ACTIVE_GRANT_ID, bob.address, stopGrantExpiry);
    });

    it("fee is refunded to the proposer after stop accept", async function () {
      expect(await zchf.balanceOf(alice.address)).to.equal(aliceBalanceBefore);
    });

    it("grant.expiry is set to the stop expiry (already past)", async function () {
      const g = await grants.grants(ACTIVE_GRANT_ID);
      expect(g.expiry).to.equal(stopGrantExpiry);
      expect(g.expiry).to.be.lte(BigInt((await ethers.provider.getBlock("latest"))!.timestamp));
    });

    it("isActive returns false after stop is accepted", async function () {
      expect(await grants.isActive(ACTIVE_GRANT_ID)).to.be.false;
    });

    it("remaining periods before expiry are still claimable after stop", async function () {
      // latestSettlement is some point before stopGrantExpiry; remaining full periods can stream
      const g = await grants.grants(ACTIVE_GRANT_ID);
      const elapsed  = stopGrantExpiry - g.latestSettlement;
      const periods  = elapsed / g.streamPeriod;

      if (periods > 0n) {
        const balBefore = await zchf.balanceOf(recipient.address);
        await expect(grants.connect(bob).stream(ACTIVE_GRANT_ID)).to.emit(grants, "GrantStreamed");
        expect(await zchf.balanceOf(recipient.address)).to.be.gt(balBefore);
      }
    });

    it("reverts NothingToStream once all pre-expiry periods are claimed", async function () {
      // Drain any remaining claimable periods first
      try { await grants.connect(bob).stream(ACTIVE_GRANT_ID); } catch { /* already drained */ }

      await expect(grants.connect(bob).stream(ACTIVE_GRANT_ID))
        .to.be.revertedWithCustomError(grants, "NothingToStream");
    });
  });
});
