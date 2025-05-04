import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { ethers } from "hardhat";
import { CCIPLocalSimulator } from "../typechain";
import { expect } from "chai";
import { evm_increaseTime } from "./helper";

describe("LeaderateSender", () => {
  async function deployFixture() {
    const [owner, singleVoter] = await ethers.getSigners();

    const ccipLocalSimualtorFactory = await ethers.getContractFactory(
      "CCIPLocalSimulator"
    );
    const ccipLocalSimulator: CCIPLocalSimulator =
      await ccipLocalSimualtorFactory.deploy();
    const ccipLocalSimulatorConfig = await ccipLocalSimulator.configuration();

    const frankenCoinFactory = await ethers.getContractFactory("Frankencoin");
    const zchf = await frankenCoinFactory.deploy(10 * 86400);
    await zchf.initialize(await owner.getAddress(), "");

    const equity = await ethers.getContractAt("Equity", await zchf.reserve());

    const leadrateFactory = await ethers.getContractFactory("Leadrate");
    const leadrate = await leadrateFactory.deploy(
      await equity.getAddress(),
      200
    );

    const leadreateSenderFactory = await ethers.getContractFactory(
      "LeadrateSender"
    );
    const leadrateSender = await leadreateSenderFactory.deploy(
      await leadrate.getAddress(),
      ccipLocalSimulatorConfig.sourceRouter_,
      ccipLocalSimulatorConfig.ccipLnM_
    );

    const bridgedLeadrateFactory = await ethers.getContractFactory(
      "BridgedLeadrate"
    );
    const bridgedLeadrate = await bridgedLeadrateFactory.deploy(
      ccipLocalSimulatorConfig.destinationRouter_,
      5,
      ccipLocalSimulatorConfig.chainSelector_,
      await leadrateSender.getAddress()
    );

    return {
      ccipLocalSimulatorConfig,
      owner,
      bridgedLeadrate,
      zchf,
      equity,
      leadrate,
      singleVoter,
      leadrateSender,
    };
  }

  it("should not apply pending changes", async () => {
    const {
      leadrate,
      leadrateSender,
      singleVoter,
      ccipLocalSimulatorConfig,
      bridgedLeadrate,
    } = await loadFixture(deployFixture);
    const previousRate = await leadrate.currentRatePPM();
    await leadrate.connect(singleVoter).proposeChange(500, []);
    await leadrateSender["pushLeadrate(uint64,address)"](
      ccipLocalSimulatorConfig.chainSelector_,
      await bridgedLeadrate.getAddress(),
      { value: 100 }
    );
    expect(await leadrate.currentRatePPM()).to.equal(previousRate);
  });

  it("should apply pending changes", async () => {
    const {
      leadrate,
      leadrateSender,
      singleVoter,
      ccipLocalSimulatorConfig,
      bridgedLeadrate,
    } = await loadFixture(deployFixture);
    await leadrate.connect(singleVoter).proposeChange(500, []);
    await evm_increaseTime(7 * 24 * 3600 + 1);
    await leadrateSender["pushLeadrate(uint64,address)"](
      ccipLocalSimulatorConfig.chainSelector_,
      await bridgedLeadrate.getAddress(),
      { value: 100 }
    );
    expect(await leadrate.currentRatePPM()).to.equal(500);
  });

  it("should apply on the bridged chain", async () => {
    const {
      bridgedLeadrate,
      leadrateSender,
      ccipLocalSimulatorConfig,
      singleVoter,
      leadrate,
    } = await loadFixture(deployFixture);
    await leadrate.connect(singleVoter).proposeChange(500, []);
    await evm_increaseTime(7 * 24 * 3600 + 1);
    await leadrateSender["pushLeadrate(uint64,address)"](
      ccipLocalSimulatorConfig.chainSelector_,
      await bridgedLeadrate.getAddress(),
      { value: 100 }
    );
    expect(await bridgedLeadrate.currentRatePPM()).to.equal(500);
  });

  describe("bulk", () => {
    it("should apply pending changes", async () => {
      const {
        bridgedLeadrate,
        leadrateSender,
        ccipLocalSimulatorConfig,
        singleVoter,
        leadrate,
      } = await loadFixture(deployFixture);
      await leadrate.connect(singleVoter).proposeChange(500, []);
      await evm_increaseTime(7 * 24 * 3600 + 1);

      await leadrateSender["pushLeadrate(uint64[],bytes[])"](
        [ccipLocalSimulatorConfig.chainSelector_],
        [
          ethers.AbiCoder.defaultAbiCoder().encode(
            ["address"],
            [await bridgedLeadrate.getAddress()]
          ),
        ],
      );
      expect(await bridgedLeadrate.currentRatePPM()).to.equal(500);
    });

    it("should revert if chains and targets are not aligned", async () => {
      const { leadrateSender, ccipLocalSimulatorConfig } = await loadFixture(
        deployFixture
      );

      await expect(
        leadrateSender["pushLeadrate(uint64[],bytes[])"](
          [ccipLocalSimulatorConfig.chainSelector_],
          [],
        )
      ).revertedWithCustomError(leadrateSender, "LengthMismatch");
    });

    it("should revert if chains and extraArgs are not aligned", async () => {
      const { bridgedLeadrate, leadrateSender, ccipLocalSimulatorConfig } =
        await loadFixture(deployFixture);

      await expect(
        leadrateSender["pushLeadrate(uint64[],bytes[],bytes[])"](
          [ccipLocalSimulatorConfig.chainSelector_],
          [
            ethers.AbiCoder.defaultAbiCoder().encode(
              ["address"],
              [await bridgedLeadrate.getAddress()]
            ),
          ],
          [],
        )
      ).revertedWithCustomError(leadrateSender, "LengthMismatch");
    });
  });
});
