import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";

describe("BridgedLeadrate", () => {
  async function deployFixture() {
    const [owner, leadreateMock, singleVoter, router] =
      await ethers.getSigners();
    const chainSelector = 123456789;

    const bridgedLeadrateFactory = await ethers.getContractFactory(
      "BridgedLeadrate"
    );
    const bridgedLeadrate = await bridgedLeadrateFactory.deploy(
      await router.getAddress(),
      5,
      chainSelector,
      await leadreateMock.getAddress()
    );

    return {
      chainSelector,
      router,
      owner,
      bridgedLeadrate,
      leadreateMock,
      singleVoter,
    };
  }

  it("should validate the source chain", async () => {
    const { owner, bridgedLeadrate, router } = await loadFixture(deployFixture);
    const abicoder = ethers.AbiCoder.defaultAbiCoder();

    await expect(
      bridgedLeadrate.connect(router).ccipReceive({
        messageId:
          "0x0000000000000000000000000000000000000000000000000000000000000001",
        sourceChainSelector: "123456",
        sender: abicoder.encode(["address"], [await owner.getAddress()]),
        data: abicoder.encode(["uint64"], [50]),
        destTokenAmounts: [],
      })
    ).revertedWithCustomError(bridgedLeadrate, "InvalidSourceChain");
  });

  it("should validate the sender", async () => {
    const { owner, bridgedLeadrate, router, chainSelector } = await loadFixture(
      deployFixture
    );
    const abicoder = ethers.AbiCoder.defaultAbiCoder();

    await expect(
      bridgedLeadrate.connect(router).ccipReceive({
        messageId:
          "0x0000000000000000000000000000000000000000000000000000000000000001",
        sourceChainSelector: chainSelector,
        sender: abicoder.encode(["address"], [await owner.getAddress()]),
        data: abicoder.encode(["uint64"], [50]),
        destTokenAmounts: [],
      })
    ).revertedWithCustomError(bridgedLeadrate, "InvalidSender");
  });

  it("should update the rate", async () => {
    const { owner, bridgedLeadrate, router, chainSelector, leadreateMock } =
      await loadFixture(deployFixture);
    const abicoder = ethers.AbiCoder.defaultAbiCoder();
    expect(await bridgedLeadrate.currentRatePPM()).to.not.equal(50);

    await bridgedLeadrate.connect(router).ccipReceive({
      messageId:
        "0x0000000000000000000000000000000000000000000000000000000000000001",
      sourceChainSelector: chainSelector,
      sender: abicoder.encode(["address"], [await leadreateMock.getAddress()]),
      data: abicoder.encode(["uint64"], [50]),
      destTokenAmounts: [],
    });
    expect(await bridgedLeadrate.currentRatePPM()).to.equal(50);
  });
});
