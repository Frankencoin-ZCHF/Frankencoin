import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";

describe("CCIPSender", () => {
  async function deployFixture() {
    const [owner] = await ethers.getSigners();

    const ccipLocalSimualtorFactory = await ethers.getContractFactory(
      "CCIPLocalSimulator"
    );
    const ccipLocalSimulator = await ccipLocalSimualtorFactory.deploy();
    const ccipLocalSimulatorConfig = await ccipLocalSimulator.configuration();

    const ccipSenderFactory = await ethers.getContractFactory("CCIPSenderTest");
    const ccipSender = await ccipSenderFactory.deploy(
      ccipLocalSimulatorConfig.sourceRouter_,
      ccipLocalSimulatorConfig.linkToken_
    );

    return {
      ccipLocalSimulatorConfig,
      owner,
      ccipSender,
      ccipLocalSimulator,
    };
  }

  it("should initialize with correct router address", async () => {
    const { ccipSender, ccipLocalSimulatorConfig } = await loadFixture(
      deployFixture
    );
    expect(await ccipSender.ROUTER()).to.equal(
      ccipLocalSimulatorConfig.sourceRouter_
    );
  });

  it("should initialize with correct link token address", async () => {
    const { ccipSender, ccipLocalSimulatorConfig } = await loadFixture(
      deployFixture
    );
    expect(await ccipSender.LINK()).to.equal(
      ccipLocalSimulatorConfig.linkToken_
    );
  });

  it("should abiencode the receiver", async () => {
    const { ccipSender } = await loadFixture(deployFixture);
    const receiver = "0x1234567890123456789012345678901234567890";
    const abiEncodedReceiver = await ccipSender.toReceiver(receiver);
    expect(abiEncodedReceiver).to.equal(
      ethers.AbiCoder.defaultAbiCoder().encode(["address"], [receiver])
    );
  });

  it("shoold construct a message with native fee token", async () => {
    const { ccipSender } = await loadFixture(deployFixture);
    const receiver = "0x1234567890123456789012345678901234567890";
    const abiEncodedReceiver = ethers.AbiCoder.defaultAbiCoder().encode(
      ["address"],
      [receiver]
    );
    const abiEncodedPayload = ethers.AbiCoder.defaultAbiCoder().encode(
      ["string"],
      ["payload"]
    );

    const message = await ccipSender[
      "constructMessage(bytes,bytes,(address,uint256)[],bool,bytes)"
    ](abiEncodedReceiver, abiEncodedPayload, [], true, "0x");
    expect(message.receiver).to.equal(abiEncodedReceiver);
    expect(message.data).to.equal(abiEncodedPayload);
    expect(message.tokenAmounts).to.deep.equal([]);
    expect(message.feeToken).to.equal(ethers.ZeroAddress);
    expect(message.extraArgs).to.equal("0x");
  });
  it("shoold construct a message with link fee token", async () => {
    const { ccipSender, ccipLocalSimulatorConfig } = await loadFixture(
      deployFixture
    );
    const receiver = "0x1234567890123456789012345678901234567890";
    const abiEncodedReceiver = ethers.AbiCoder.defaultAbiCoder().encode(
      ["address"],
      [receiver]
    );
    const abiEncodedPayload = ethers.AbiCoder.defaultAbiCoder().encode(
      ["string"],
      ["payload"]
    );

    const message = await ccipSender[
      "constructMessage(bytes,bytes,(address,uint256)[],bool,bytes)"
    ](abiEncodedReceiver, abiEncodedPayload, [], false, "0x");
    expect(message.receiver).to.equal(abiEncodedReceiver);
    expect(message.data).to.equal(abiEncodedPayload);
    expect(message.tokenAmounts).to.deep.equal([]);
    expect(message.feeToken).to.equal(ccipLocalSimulatorConfig.linkToken_);
    expect(message.extraArgs).to.equal("0x");
  });

  it("should pass the token amounts", async () => {
    const { ccipSender } = await loadFixture(deployFixture);
    const receiver = "0x1234567890123456789012345678901234567890";
    const tokenAddress = "0x5678901234567890123456789012345678901234";
    const abiEncodedReceiver = ethers.AbiCoder.defaultAbiCoder().encode(
      ["address"],
      [receiver]
    );
    const message = await ccipSender[
      "constructMessage(bytes,bytes,(address,uint256)[],bool,bytes)"
    ](
      abiEncodedReceiver,
      "0x",
      [
        {
          token: tokenAddress,
          amount: 5000,
        },
      ],
      false,
      "0x"
    );

    expect(message.tokenAmounts).to.deep.equal([[tokenAddress, 5000n]]);
  });

  it("should return the router fee", async () => {
    const { ccipSender, ccipLocalSimulatorConfig } = await loadFixture(
      deployFixture
    );
    const receiver = "0x1234567890123456789012345678901234567890";
    const abiEncodedReceiver = ethers.AbiCoder.defaultAbiCoder().encode(
      ["address"],
      [receiver]
    );
    const mockRouter = await ethers.getContractAt(
      "MockCCIPRouter",
      ccipLocalSimulatorConfig.sourceRouter_
    );
    await mockRouter.setFee(1000);

    const fee = await ccipSender.calculateFee(
      ccipLocalSimulatorConfig.chainSelector_,
      {
        receiver: abiEncodedReceiver,
        data: "0x",
        tokenAmounts: [],
        feeToken: ethers.ZeroAddress,
        extraArgs: "0x",
      }
    );

    expect(fee).to.equal(1000);
  });

  it("should return overpaied native fee", async () => {
    const { ccipSender, ccipLocalSimulatorConfig, owner } = await loadFixture(
      deployFixture
    );
    const receiver = "0x1234567890123456789012345678901234567890";
    const abiEncodedReceiver = ethers.AbiCoder.defaultAbiCoder().encode(
      ["address"],
      [receiver]
    );
    const mockRouter = await ethers.getContractAt(
      "MockCCIPRouter",
      ccipLocalSimulatorConfig.sourceRouter_
    );
    await mockRouter.setFee(1000);
    const tx = ccipSender.send(
      ccipLocalSimulatorConfig.chainSelector_,
      {
        receiver: abiEncodedReceiver,
        data: "0x",
        tokenAmounts: [],
        feeToken: ethers.ZeroAddress,
        extraArgs: "0x",
      },
      {
        value: ethers.parseEther("1"),
      }
    );
    expect(tx).changeEtherBalance(owner, -1000);
  });

  it("should throw if feetoken balance is too low", async () => {
    const { ccipSender, ccipLocalSimulatorConfig, owner } = await loadFixture(
      deployFixture
    );
    const receiver = "0x1234567890123456789012345678901234567890";
    const abiEncodedReceiver = ethers.AbiCoder.defaultAbiCoder().encode(
      ["address"],
      [receiver]
    );
    const mockRouter = await ethers.getContractAt(
      "MockCCIPRouter",
      ccipLocalSimulatorConfig.sourceRouter_
    );
    await mockRouter.setFee(1000);
    await expect(
      ccipSender.send(
        ccipLocalSimulatorConfig.chainSelector_,
        {
          receiver: abiEncodedReceiver,
          data: "0x",
          tokenAmounts: [],
          feeToken: ccipLocalSimulatorConfig.linkToken_,
          extraArgs: "0x",
        },
        {
          value: ethers.parseEther("1"),
        }
      )
    ).revertedWithCustomError(ccipSender, "InsufficientFeeTokens");
  });

  it("should throw if feetoken allowance is too low", async () => {
    const { ccipSender, ccipLocalSimulatorConfig, ccipLocalSimulator, owner } =
      await loadFixture(deployFixture);
    const receiver = "0x1234567890123456789012345678901234567890";
    const abiEncodedReceiver = ethers.AbiCoder.defaultAbiCoder().encode(
      ["address"],
      [receiver]
    );
    const mockRouter = await ethers.getContractAt(
      "MockCCIPRouter",
      ccipLocalSimulatorConfig.sourceRouter_
    );
    await ccipLocalSimulator.requestLinkFromFaucet(
      await owner.getAddress(),
      ethers.parseEther("10")
    );

    await mockRouter.setFee(1000);
    await expect(
      ccipSender.send(
        ccipLocalSimulatorConfig.chainSelector_,
        {
          receiver: abiEncodedReceiver,
          data: "0x",
          tokenAmounts: [],
          feeToken: ccipLocalSimulatorConfig.linkToken_,
          extraArgs: "0x",
        },
        {
          value: ethers.parseEther("1"),
        }
      )
    ).revertedWithCustomError(ccipSender, "InsufficientFeeTokenAllowance");
  });

  it("should use fee token", async () => {
    const { ccipSender, ccipLocalSimulatorConfig, ccipLocalSimulator, owner } =
      await loadFixture(deployFixture);
    const receiver = "0x1234567890123456789012345678901234567890";
    const abiEncodedReceiver = ethers.AbiCoder.defaultAbiCoder().encode(
      ["address"],
      [receiver]
    );
    const mockRouter = await ethers.getContractAt(
      "MockCCIPRouter",
      ccipLocalSimulatorConfig.sourceRouter_
    );
    await ccipLocalSimulator.requestLinkFromFaucet(
      await owner.getAddress(),
      ethers.parseEther("10")
    );
    const linkContract = await ethers.getContractAt(
      "contracts/erc20/ERC20.sol:ERC20",
      ccipLocalSimulatorConfig.linkToken_
    );
    await linkContract.approve(
      await ccipSender.getAddress(),
      ethers.parseEther("10")
    );

    await mockRouter.setFee(1000);
    const tx = ccipSender.send(ccipLocalSimulatorConfig.chainSelector_, {
      receiver: abiEncodedReceiver,
      data: "0x",
      tokenAmounts: [],
      feeToken: ccipLocalSimulatorConfig.linkToken_,
      extraArgs: "0x",
    });
    await expect(tx).changeEtherBalance(owner, 0);
    await expect(tx).changeTokenBalance(linkContract, owner, -1000);
  });
});
