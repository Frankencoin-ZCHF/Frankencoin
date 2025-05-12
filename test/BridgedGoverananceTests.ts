import { GovernanceSender, CCIPLocalSimulator } from "../typechain";
import { ethers } from "hardhat";
import { evm_increaseTime } from "./helper";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import { getLinkTokenContract } from "./helper/ccip";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

describe("Bridged Governance Tests", () => {
  async function sendSyncMessage(
    governanceSender: GovernanceSender,
    sender: HardhatEthersSigner,
    receiver: string,
    chainSelector: bigint,
    feeToken: string,
    voters: string[]
  ) {
    const fee = await governanceSender[
      "getCCIPFee(uint64,address,address[],bool)"
    ](chainSelector, receiver, voters, feeToken === ethers.ZeroAddress);

    if (feeToken !== ethers.ZeroAddress) {
      const linkTokenContract = await getLinkTokenContract(feeToken);
      await linkTokenContract
        .connect(sender)
        .approve(await governanceSender.getAddress(), fee);
    }
    const tx = await governanceSender
      .connect(sender)
      ["pushVotes(uint64,address,address[])"](chainSelector, receiver, voters);
    await tx.wait();
  }

  async function deployFixture() {
    const [minter, user1, user2, user3, user4, user5] =
      await ethers.getSigners();

    // Setup CCIP environment
    const ccipLocalSimualtorFactory = await ethers.getContractFactory(
      "CCIPLocalSimulator"
    );
    const ccipLocalSimulator: CCIPLocalSimulator =
      await ccipLocalSimualtorFactory.deploy();
    const ccipLocalSimulatorConfig = await ccipLocalSimulator.configuration();

    // Setup Frankencoin contracts
    const frankenCoinFactory = await ethers.getContractFactory("Frankencoin");
    const zchf = await frankenCoinFactory.deploy(
      10 * 864000,
    );
    await zchf.initialize(minter.address, "");

    const equity = await ethers.getContractAt("Equity", await zchf.reserve());

    // Setup bridged contracts
    const governanceSenderFactory = await ethers.getContractFactory(
      "GovernanceSender"
    );
    const governanceSender = await governanceSenderFactory.deploy(
      await equity.getAddress(),
      ccipLocalSimulatorConfig.sourceRouter_,
      ccipLocalSimulatorConfig.ccipLnM_
    );

    const bridgedGovernanceFactory = await ethers.getContractFactory(
      "BridgedGovernance"
    );
    const bridgedGovernance = await bridgedGovernanceFactory.deploy(
      ccipLocalSimulatorConfig.destinationRouter_,
      ccipLocalSimulatorConfig.chainSelector_,
      await governanceSender.getAddress()
    );

    // Setup users
    await zchf.mintWithReserve(
      user1.address,
      ethers.parseEther("10000"),
      "10000",
      "0"
    );
    await zchf.mintWithReserve(
      user2.address,
      ethers.parseEther("10000"),
      "10000",
      "0"
    );
    await zchf.mintWithReserve(
      user3.address,
      ethers.parseEther("10000"),
      "10000",
      "0"
    );
    await zchf.mintWithReserve(
      user4.address,
      ethers.parseEther("10000"),
      "10000",
      "0"
    );
    await zchf.mintWithReserve(
      user5.address,
      ethers.parseEther("10000"),
      "10000",
      "0"
    );

    await equity.connect(user1).invest(ethers.parseEther("5000"), 0);
    await equity.connect(user2).invest(ethers.parseEther("5000"), 0);
    await equity.connect(user3).invest(ethers.parseEther("5000"), 0);
    await equity.connect(user4).invest(ethers.parseEther("5000"), 0);
    await equity.connect(user5).invest(ethers.parseEther("5000"), 0);

    await evm_increaseTime(100 * 24 * 60 * 60); // 100 days

    return {
      ccipLocalSimulator,
      ccipLocalSimulatorConfig,
      zchf,
      equity,
      governanceSender,
      bridgedGovernance,
      minter,
      user1,
      user2,
      user3,
      user4,
      user5,
    };
  }

  describe("pushVotesPayNative", () => {
    it("should transfer single user votes", async () => {
      const {
        governanceSender,
        bridgedGovernance,
        user1,
        ccipLocalSimulatorConfig,
        equity,
      } = await loadFixture(deployFixture);
      await sendSyncMessage(
        governanceSender,
        user1,
        await bridgedGovernance.getAddress(),
        ccipLocalSimulatorConfig.chainSelector_,
        ethers.ZeroAddress,
        [await user1.getAddress()]
      );

      // checks
      expect(await bridgedGovernance.votes(user1.address)).to.equal(
        await equity.votes(user1.address)
      );
    });

    it("should transfer single user delegation", async () => {
      const {
        governanceSender,
        bridgedGovernance,
        user1,
        user2,
        ccipLocalSimulatorConfig,
        equity,
      } = await loadFixture(deployFixture);
      await equity.connect(user1).delegateVoteTo(await user2.getAddress());

      await sendSyncMessage(
        governanceSender,
        user1,
        await bridgedGovernance.getAddress(),
        ccipLocalSimulatorConfig.chainSelector_,
        ethers.ZeroAddress,
        [await user1.getAddress()]
      );
      // checks
      expect(await bridgedGovernance.delegates(user1.address)).to.equal(
        await user2.getAddress()
      );
    });

    it("should transfer totalVotes along", async () => {
      const {
        governanceSender,
        bridgedGovernance,
        user1,
        ccipLocalSimulatorConfig,
        equity,
      } = await loadFixture(deployFixture);
      await sendSyncMessage(
        governanceSender,
        user1,
        await bridgedGovernance.getAddress(),
        ccipLocalSimulatorConfig.chainSelector_,
        ethers.ZeroAddress,
        []
      );

      // checks
      expect(await bridgedGovernance.totalVotes()).to.equal(
        await equity.totalVotes()
      );
    });

    it("should transfer multiple users", async () => {
      const {
        governanceSender,
        bridgedGovernance,
        user1,
        user2,
        user3,
        user4,
        ccipLocalSimulatorConfig,
        equity,
      } = await loadFixture(deployFixture);
      await sendSyncMessage(
        governanceSender,
        user1,
        await bridgedGovernance.getAddress(),
        ccipLocalSimulatorConfig.chainSelector_,
        ethers.ZeroAddress,
        [
          await user1.getAddress(),
          await user2.getAddress(),
          await user3.getAddress(),
          await user4.getAddress(),
        ]
      );

      // checks
      expect(await bridgedGovernance.votes(user1.address)).to.equal(
        await equity.votes(user1.address)
      );
      expect(await bridgedGovernance.votes(user2.address)).to.equal(
        await equity.votes(user2.address)
      );
      expect(await bridgedGovernance.votes(user3.address)).to.equal(
        await equity.votes(user3.address)
      );
      expect(await bridgedGovernance.votes(user4.address)).to.equal(
        await equity.votes(user4.address)
      );
    });

    it("should transfer multiple user delegation", async () => {
      const {
        governanceSender,
        bridgedGovernance,
        user1,
        user2,
        user3,
        user4,
        ccipLocalSimulatorConfig,
        equity,
      } = await loadFixture(deployFixture);

      await equity.connect(user1).delegateVoteTo(await user2.getAddress());
      await equity.connect(user3).delegateVoteTo(await user2.getAddress());
      await equity.connect(user4).delegateVoteTo(await user2.getAddress());

      await sendSyncMessage(
        governanceSender,
        user1,
        await bridgedGovernance.getAddress(),
        ccipLocalSimulatorConfig.chainSelector_,
        ethers.ZeroAddress,
        [
          await user1.getAddress(),
          await user2.getAddress(),
          await user3.getAddress(),
          await user4.getAddress(),
        ]
      );

      // checks
      expect(await bridgedGovernance.delegates(user1.address)).to.equal(
        await user2.getAddress()
      );
      expect(await bridgedGovernance.delegates(user3.address)).to.equal(
        await user2.getAddress()
      );
      expect(await bridgedGovernance.delegates(user4.address)).to.equal(
        await user2.getAddress()
      );
      expect(await bridgedGovernance.delegates(user2.address)).to.equal(
        ethers.ZeroAddress
      );
    });

    it("should update votes", async () => {
      const {
        governanceSender,
        bridgedGovernance,
        user1,
        ccipLocalSimulatorConfig,
        equity,
      } = await loadFixture(deployFixture);

      const votesBefore = await equity.votes(await user1.getAddress());

      // transfer initial votes
      await sendSyncMessage(
        governanceSender,
        user1,
        await bridgedGovernance.getAddress(),
        ccipLocalSimulatorConfig.chainSelector_,
        ethers.ZeroAddress,
        [await user1.getAddress()]
      );

      expect(await bridgedGovernance.votes(await user1.getAddress())).eq(
        await equity.votes(await user1.getAddress())
      );

      await equity
        .connect(user1)
        .redeem(await user1.getAddress(), ethers.parseEther("1"));

      const votesAfter = await equity.votes(await user1.getAddress());
      expect(votesAfter).to.lessThan(votesBefore);

      // transfer updated votes
      await sendSyncMessage(
        governanceSender,
        user1,
        await bridgedGovernance.getAddress(),
        ccipLocalSimulatorConfig.chainSelector_,
        ethers.ZeroAddress,
        [await user1.getAddress()]
      );

      expect(await bridgedGovernance.votes(await user1.getAddress())).to.equal(
        await equity.votes(await user1.getAddress())
      );
    });

    it("should update delegation", async () => {
      const {
        governanceSender,
        bridgedGovernance,
        user1,
        user2,
        user3,
        ccipLocalSimulatorConfig,
        equity,
      } = await loadFixture(deployFixture);

      const user2Addr = await user2.getAddress();
      await equity.connect(user1).delegateVoteTo(user2Addr);

      // transfer delegation
      await sendSyncMessage(
        governanceSender,
        user1,
        await bridgedGovernance.getAddress(),
        ccipLocalSimulatorConfig.chainSelector_,
        ethers.ZeroAddress,
        [await user1.getAddress()]
      );

      expect(
        await bridgedGovernance.delegates(await user1.getAddress())
      ).to.equal(user2Addr);

      const user3Addr = await user3.getAddress();
      await equity.connect(user1).delegateVoteTo(user3Addr);

      // transfer redelegation
      await sendSyncMessage(
        governanceSender,
        user1,
        await bridgedGovernance.getAddress(),
        ccipLocalSimulatorConfig.chainSelector_,
        ethers.ZeroAddress,
        [await user1.getAddress()]
      );

      expect(
        await bridgedGovernance.delegates(await user1.getAddress())
      ).to.equal(user3Addr);
    });
  });

  describe("pushVotesPayToken", () => {
    it("should transfer single user votes", async () => {
      const {
        governanceSender,
        bridgedGovernance,
        user1,
        ccipLocalSimulatorConfig,
        equity,
      } = await loadFixture(deployFixture);
      await sendSyncMessage(
        governanceSender,
        user1,
        await bridgedGovernance.getAddress(),
        ccipLocalSimulatorConfig.chainSelector_,
        ccipLocalSimulatorConfig.linkToken_,
        [await user1.getAddress()]
      );

      // checks
      expect(await bridgedGovernance.votes(user1.address)).to.equal(
        await equity.votes(user1.address)
      );
    });

    it("should transfer single user delegation", async () => {
      const {
        governanceSender,
        bridgedGovernance,
        user1,
        user2,
        ccipLocalSimulatorConfig,
        equity,
      } = await loadFixture(deployFixture);

      await equity.connect(user1).delegateVoteTo(await user2.getAddress());

      await sendSyncMessage(
        governanceSender,
        user1,
        await bridgedGovernance.getAddress(),
        ccipLocalSimulatorConfig.chainSelector_,
        ccipLocalSimulatorConfig.linkToken_,
        [await user1.getAddress()]
      );

      // checks
      expect(await bridgedGovernance.delegates(user1.address)).to.equal(
        await user2.getAddress()
      );
    });

    it("should transfer totalVotes along", async () => {
      const {
        governanceSender,
        bridgedGovernance,
        user1,
        ccipLocalSimulatorConfig,
        equity,
      } = await loadFixture(deployFixture);
      await sendSyncMessage(
        governanceSender,
        user1,
        await bridgedGovernance.getAddress(),
        ccipLocalSimulatorConfig.chainSelector_,
        ccipLocalSimulatorConfig.linkToken_,
        []
      );

      // checks
      expect(await bridgedGovernance.totalVotes()).to.equal(
        await equity.totalVotes()
      );
    });

    it("should transfer multiple users", async () => {
      const {
        governanceSender,
        bridgedGovernance,
        user1,
        user2,
        user3,
        user4,
        ccipLocalSimulatorConfig,
        equity,
      } = await loadFixture(deployFixture);
      await sendSyncMessage(
        governanceSender,
        user1,
        await bridgedGovernance.getAddress(),
        ccipLocalSimulatorConfig.chainSelector_,
        ccipLocalSimulatorConfig.linkToken_,
        [
          await user1.getAddress(),
          await user2.getAddress(),
          await user3.getAddress(),
          await user4.getAddress(),
        ]
      );

      // checks
      expect(await bridgedGovernance.votes(user1.address)).to.equal(
        await equity.votes(user1.address)
      );
      expect(await bridgedGovernance.votes(user2.address)).to.equal(
        await equity.votes(user2.address)
      );
      expect(await bridgedGovernance.votes(user3.address)).to.equal(
        await equity.votes(user3.address)
      );
      expect(await bridgedGovernance.votes(user4.address)).to.equal(
        await equity.votes(user4.address)
      );
    });

    it("should transfer multiple user delegation", async () => {
      const {
        governanceSender,
        bridgedGovernance,
        user1,
        user2,
        user3,
        user4,
        ccipLocalSimulatorConfig,
        equity,
      } = await loadFixture(deployFixture);

      await equity.connect(user1).delegateVoteTo(await user2.getAddress());
      await equity.connect(user3).delegateVoteTo(await user2.getAddress());
      await equity.connect(user4).delegateVoteTo(await user2.getAddress());

      await sendSyncMessage(
        governanceSender,
        user1,
        await bridgedGovernance.getAddress(),
        ccipLocalSimulatorConfig.chainSelector_,
        ccipLocalSimulatorConfig.linkToken_,
        [
          await user1.getAddress(),
          await user2.getAddress(),
          await user3.getAddress(),
          await user4.getAddress(),
        ]
      );

      // checks
      expect(await bridgedGovernance.delegates(user1.address)).to.equal(
        await user2.getAddress()
      );
      expect(await bridgedGovernance.delegates(user3.address)).to.equal(
        await user2.getAddress()
      );
      expect(await bridgedGovernance.delegates(user4.address)).to.equal(
        await user2.getAddress()
      );
      expect(await bridgedGovernance.delegates(user2.address)).to.equal(
        ethers.ZeroAddress
      );
    });

    it("should update votes", async () => {
      const {
        governanceSender,
        bridgedGovernance,
        user1,
        ccipLocalSimulatorConfig,
        equity,
      } = await loadFixture(deployFixture);

      const votesBefore = await equity.votes(await user1.getAddress());

      await sendSyncMessage(
        governanceSender,
        user1,
        await bridgedGovernance.getAddress(),
        ccipLocalSimulatorConfig.chainSelector_,
        ccipLocalSimulatorConfig.linkToken_,
        [await user1.getAddress()]
      );

      expect(await bridgedGovernance.votes(await user1.getAddress())).eq(
        await equity.votes(await user1.getAddress())
      );

      await equity
        .connect(user1)
        .redeem(await user1.getAddress(), ethers.parseEther("1"));

      const votesAfter = await equity.votes(await user1.getAddress());
      expect(votesAfter).to.lessThan(votesBefore);

      await sendSyncMessage(
        governanceSender,
        user1,
        await bridgedGovernance.getAddress(),
        ccipLocalSimulatorConfig.chainSelector_,
        ccipLocalSimulatorConfig.linkToken_,
        [await user1.getAddress()]
      );

      expect(await bridgedGovernance.votes(await user1.getAddress())).to.equal(
        await equity.votes(await user1.getAddress())
      );
    });

    it("should update delegation", async () => {
      const {
        governanceSender,
        bridgedGovernance,
        user1,
        user2,
        user3,
        ccipLocalSimulatorConfig,
        equity,
      } = await loadFixture(deployFixture);
      await equity.connect(user1).delegateVoteTo(await user2.getAddress());

      // transfer delegation

      await sendSyncMessage(
        governanceSender,
        user1,
        await bridgedGovernance.getAddress(),
        ccipLocalSimulatorConfig.chainSelector_,
        ccipLocalSimulatorConfig.linkToken_,
        [await user1.getAddress()]
      );

      const user3Addr = await user3.getAddress();
      await equity.connect(user1).delegateVoteTo(user3Addr);

      // transfer redelegation

      await sendSyncMessage(
        governanceSender,
        user1,
        await bridgedGovernance.getAddress(),
        ccipLocalSimulatorConfig.chainSelector_,
        ccipLocalSimulatorConfig.linkToken_,
        [await user1.getAddress()]
      );

      expect(
        await bridgedGovernance.delegates(await user1.getAddress())
      ).to.equal(user3Addr);
    });
  });
});
