import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";

describe.only("TransferReference", () => {
  async function deployFixture() {
    const [owner, nonOwner] = await ethers.getSigners();

    const frankencoinFactory = await ethers.getContractFactory("Frankencoin");
    const frankencoin = await frankencoinFactory.deploy(0);
    await frankencoin.initialize(await owner.getAddress(), "");

    const ccipLocalSimualtorFactory = await ethers.getContractFactory(
      "CCIPLocalSimulator"
    );
    const ccipLocalSimulator = await ccipLocalSimualtorFactory.deploy();
    const ccipLocalSimulatorConfig = await ccipLocalSimulator.configuration();

    const transferReferenceFactory = await ethers.getContractFactory(
      "TransferReference"
    );
    const transferReference = await transferReferenceFactory.deploy(
      await frankencoin.getAddress(),
      ccipLocalSimulatorConfig.sourceRouter_,
      ccipLocalSimulatorConfig.linkToken_
    );

    await frankencoin.mint(await owner.getAddress(), ethers.parseEther("1000"));
    await frankencoin.suggestMinter(
      await transferReference.getAddress(),
      await frankencoin.MIN_APPLICATION_PERIOD(),
      await frankencoin.MIN_FEE(),
      "referenceTransfer"
    );

    return {
      owner,
      nonOwner,
      frankencoin,
      ccipLocalSimulatorConfig,
      transferReference,
      ccipLocalSimulator,
    };
  }

  describe("transfer", () => {
    it("should transfer the tokens and emit", async () => {
      const { transferReference, frankencoin, owner } = await loadFixture(
        deployFixture
      );
      const recipient = ethers.Wallet.createRandom().address;
      await frankencoin.mint(owner.address, ethers.parseEther("100"));
      const tx = await transferReference.transfer(
        recipient,
        ethers.parseEther("100"),
        "test"
      );
      await expect(tx).changeTokenBalance(
        frankencoin,
        owner.address,
        -ethers.parseEther("100")
      );
      await expect(tx).changeTokenBalance(
        frankencoin,
        recipient,
        ethers.parseEther("100")
      );
      await expect(tx)
        .to.emit(transferReference, "Transfer")
        .withArgs(owner.address, recipient, ethers.parseEther("100"), "test");
    });
  });

  describe("transferFrom", () => {
    it("should revert if no allowance is set", async () => {
      const { transferReference, frankencoin, owner, nonOwner } =
        await loadFixture(deployFixture);

      await frankencoin.mint(
        await owner.getAddress(),
        ethers.parseEther("100")
      );
      await expect(
        transferReference
          .connect(nonOwner)
          .transferFrom(
            await owner.getAddress(),
            ethers.Wallet.createRandom().address,
            ethers.parseEther("100"),
            "test"
          )
      ).revertedWithCustomError(transferReference, "InfiniteAllowanceRequired");
    });

    it("should revert if allowance is not infinite", async () => {
      const { transferReference, frankencoin, owner, nonOwner } =
        await loadFixture(deployFixture);

      await frankencoin.mint(
        await owner.getAddress(),
        ethers.parseEther("100")
      );
      await frankencoin.approve(
        await nonOwner.getAddress(),
        ethers.parseEther("100")
      );
      await expect(
        transferReference
          .connect(nonOwner)
          .transferFrom(
            await owner.getAddress(),
            ethers.Wallet.createRandom().address,
            ethers.parseEther("100"),
            "test"
          )
      ).revertedWithCustomError(transferReference, "InfiniteAllowanceRequired");
    });

    it("should transfer the tokens and emit", async () => {
      const { transferReference, frankencoin, owner, nonOwner } =
        await loadFixture(deployFixture);
      await frankencoin.mint(
        await owner.getAddress(),
        ethers.parseEther("100")
      );
      await frankencoin.approve(
        await nonOwner.getAddress(),
        BigInt(1) << BigInt(255)
      );
      const recipient = ethers.Wallet.createRandom().address;
      const tx = transferReference
        .connect(nonOwner)
        .transferFrom(
          await owner.getAddress(),
          recipient,
          ethers.parseEther("100"),
          "test"
        );
      await expect(tx).changeTokenBalance(
        frankencoin,
        owner.address,
        -ethers.parseEther("100")
      );
      await expect(tx).changeTokenBalance(
        frankencoin,
        recipient,
        ethers.parseEther("100")
      );
      await expect(tx)
        .to.emit(transferReference, "Transfer")
        .withArgs(owner.address, recipient, ethers.parseEther("100"), "test");
    });
  });

  describe("crossTransfer", () => {
    it("should transfer via ccip", async () => {
      const {
        transferReference,
        frankencoin,
        owner,
        ccipLocalSimulatorConfig,
      } = await loadFixture(deployFixture);
      const recipient = ethers.Wallet.createRandom().address;
      await frankencoin.mint(
        await owner.getAddress(),
        ethers.parseEther("100")
      );
      const tx = await transferReference[
        "crossTransfer(uint64,address,uint256,string)"
      ](
        ccipLocalSimulatorConfig.chainSelector_,
        recipient,
        ethers.parseEther("100"),
        "test"
      );
      await expect(tx).changeTokenBalance(
        frankencoin,
        await owner.getAddress(),
        -ethers.parseEther("100")
      );
      await expect(tx).changeTokenBalance(
        frankencoin,
        recipient,
        ethers.parseEther("100")
      );
      await expect(tx)
        .to.emit(transferReference, "CrossTransfer")
        .withArgs(
          await owner.getAddress(),
          await owner.getAddress(),
          ccipLocalSimulatorConfig.chainSelector_,
          ethers.AbiCoder.defaultAbiCoder().encode(["address"], [recipient]),
          ethers.parseEther("100"),
          "test"
        );
    });
  });

  describe("crossTransferFrom", async () => {
    it("should transfer and emit", async () => {
      const {
        transferReference,
        frankencoin,
        owner,
        nonOwner,
        ccipLocalSimulatorConfig,
      } = await loadFixture(deployFixture);
      const recipient = ethers.Wallet.createRandom().address;
      await frankencoin.mint(
        await owner.getAddress(),
        ethers.parseEther("100")
      );
      await frankencoin.approve(
        await nonOwner.getAddress(),
        BigInt(1) << BigInt(255)
      );
      const tx = await transferReference
        .connect(nonOwner)
        ["crossTransferFrom(uint64,address,address,uint256,string)"](
          ccipLocalSimulatorConfig.chainSelector_,
          await owner.getAddress(),
          recipient,
          ethers.parseEther("100"),
          "test"
        );
      await expect(tx).changeTokenBalance(
        frankencoin,
        await owner.getAddress(),
        -ethers.parseEther("100")
      );
      await expect(tx).changeTokenBalance(
        frankencoin,
        recipient,
        ethers.parseEther("100")
      );
      await expect(tx)
        .to.emit(transferReference, "CrossTransfer")
        .withArgs(
          await nonOwner.getAddress(),
          await owner.getAddress(),
          ccipLocalSimulatorConfig.chainSelector_,
          ethers.AbiCoder.defaultAbiCoder().encode(["address"], [recipient]),
          ethers.parseEther("100"),
          "test"
        );
    });

    it("should revert with no allowance", async () => {
      const {
        transferReference,
        frankencoin,
        owner,
        nonOwner,
        ccipLocalSimulatorConfig,
      } = await loadFixture(deployFixture);
      const recipient = ethers.Wallet.createRandom().address;
      await frankencoin.mint(
        await owner.getAddress(),
        ethers.parseEther("100")
      );
      await expect(
        transferReference
          .connect(nonOwner)
          ["crossTransferFrom(uint64,address,address,uint256,string)"](
            ccipLocalSimulatorConfig.chainSelector_,
            await owner.getAddress(),
            recipient,
            ethers.parseEther("100"),
            "test"
          )
      ).revertedWithCustomError(transferReference, "InfiniteAllowanceRequired");
    });

    it("should revert with non infinite allowance", async () => {
      const {
        transferReference,
        frankencoin,
        owner,
        nonOwner,
        ccipLocalSimulatorConfig,
      } = await loadFixture(deployFixture);
      const recipient = ethers.Wallet.createRandom().address;
      await frankencoin.mint(
        await owner.getAddress(),
        ethers.parseEther("100")
      );
      await frankencoin.approve(
        await nonOwner.getAddress(),
        ethers.parseEther("100")
      );
      await expect(
        transferReference
          .connect(nonOwner)
          ["crossTransferFrom(uint64,address,address,uint256,string)"](
            ccipLocalSimulatorConfig.chainSelector_,
            await owner.getAddress(),
            recipient,
            ethers.parseEther("100"),
            "test"
          )
      ).revertedWithCustomError(transferReference, "InfiniteAllowanceRequired");
    });

    it("should transfer and emit (extraArgs)", async () => {
      const {
        transferReference,
        frankencoin,
        owner,
        nonOwner,
        ccipLocalSimulatorConfig,
      } = await loadFixture(deployFixture);
      const recipient = ethers.Wallet.createRandom().address;
      await frankencoin.mint(
        await owner.getAddress(),
        ethers.parseEther("100")
      );
      await frankencoin.approve(
        await nonOwner.getAddress(),
        BigInt(1) << BigInt(255)
      );
      const tx = await transferReference
        .connect(nonOwner)
        [
          "crossTransferFrom(uint64,address,address,uint256,(uint256,bool),string)"
        ](
          ccipLocalSimulatorConfig.chainSelector_,
          await owner.getAddress(),
          recipient,
          ethers.parseEther("100"),
          {
            gasLimit: 1,
            allowOutOfOrderExecution: true,
          },
          "test"
        );
      await expect(tx).changeTokenBalance(
        frankencoin,
        await owner.getAddress(),
        -ethers.parseEther("100")
      );
      await expect(tx).changeTokenBalance(
        frankencoin,
        recipient,
        ethers.parseEther("100")
      );
      await expect(tx)
        .to.emit(transferReference, "CrossTransfer")
        .withArgs(
          await nonOwner.getAddress(),
          await owner.getAddress(),
          ccipLocalSimulatorConfig.chainSelector_,
          ethers.AbiCoder.defaultAbiCoder().encode(["address"], [recipient]),
          ethers.parseEther("100"),
          "test"
        );
    });

    it("should revert with no allowance (extraArgs)", async () => {
      const {
        transferReference,
        frankencoin,
        owner,
        nonOwner,
        ccipLocalSimulatorConfig,
      } = await loadFixture(deployFixture);
      const recipient = ethers.Wallet.createRandom().address;
      await frankencoin.mint(
        await owner.getAddress(),
        ethers.parseEther("100")
      );
      await expect(
        transferReference
          .connect(nonOwner)
          [
            "crossTransferFrom(uint64,address,address,uint256,(uint256,bool),string)"
          ](
            ccipLocalSimulatorConfig.chainSelector_,
            await owner.getAddress(),
            recipient,
            ethers.parseEther("100"),
            {
              gasLimit: 1,
              allowOutOfOrderExecution: true,
            },
            "test"
          )
      ).revertedWithCustomError(transferReference, "InfiniteAllowanceRequired");
    });

    it("should revert with non infinite allowance (extraArgs)", async () => {
      const {
        transferReference,
        frankencoin,
        owner,
        nonOwner,
        ccipLocalSimulatorConfig,
      } = await loadFixture(deployFixture);
      const recipient = ethers.Wallet.createRandom().address;
      await frankencoin.mint(
        await owner.getAddress(),
        ethers.parseEther("100")
      );
      await frankencoin.approve(
        await nonOwner.getAddress(),
        ethers.parseEther("100")
      );
      await expect(
        transferReference
          .connect(nonOwner)
          [
            "crossTransferFrom(uint64,address,address,uint256,(uint256,bool),string)"
          ](
            ccipLocalSimulatorConfig.chainSelector_,
            await owner.getAddress(),
            recipient,
            ethers.parseEther("100"),
            {
              gasLimit: 1,
              allowOutOfOrderExecution: true,
            },
            "test"
          )
      ).revertedWithCustomError(transferReference, "InfiniteAllowanceRequired");
    });

    it("should transfer and emit (bytes recipient)", async () => {
      const {
        transferReference,
        frankencoin,
        owner,
        nonOwner,
        ccipLocalSimulatorConfig,
      } = await loadFixture(deployFixture);
      const recipient = ethers.Wallet.createRandom().address;
      await frankencoin.mint(
        await owner.getAddress(),
        ethers.parseEther("100")
      );
      await frankencoin.approve(
        await nonOwner.getAddress(),
        BigInt(1) << BigInt(255)
      );
      const tx = await transferReference
        .connect(nonOwner)
        ["crossTransferFrom(uint64,address,bytes,uint256,bytes,string)"](
          ccipLocalSimulatorConfig.chainSelector_,
          await owner.getAddress(),
          ethers.AbiCoder.defaultAbiCoder().encode(["address"], [recipient]),
          ethers.parseEther("100"),
          "0x",
          "test"
        );
      await expect(tx).changeTokenBalance(
        frankencoin,
        await owner.getAddress(),
        -ethers.parseEther("100")
      );
      await expect(tx).changeTokenBalance(
        frankencoin,
        recipient,
        ethers.parseEther("100")
      );
      await expect(tx)
        .to.emit(transferReference, "CrossTransfer")
        .withArgs(
          await nonOwner.getAddress(),
          await owner.getAddress(),
          ccipLocalSimulatorConfig.chainSelector_,
          ethers.AbiCoder.defaultAbiCoder().encode(["address"], [recipient]),
          ethers.parseEther("100"),
          "test"
        );
    });

    it("should revert with no allowance (bytes recipient)", async () => {
      const {
        transferReference,
        frankencoin,
        owner,
        nonOwner,
        ccipLocalSimulatorConfig,
      } = await loadFixture(deployFixture);
      const recipient = ethers.Wallet.createRandom().address;
      await frankencoin.mint(
        await owner.getAddress(),
        ethers.parseEther("100")
      );
      await expect(
        transferReference
          .connect(nonOwner)
          ["crossTransferFrom(uint64,address,bytes,uint256,bytes,string)"](
            ccipLocalSimulatorConfig.chainSelector_,
            await owner.getAddress(),
            ethers.AbiCoder.defaultAbiCoder().encode(["address"], [recipient]),
            ethers.parseEther("100"),
            "0x",
            "test"
          )
      ).revertedWithCustomError(transferReference, "InfiniteAllowanceRequired");
    });

    it("should revert with non infinite allowance (bytes recipient)", async () => {
      const {
        transferReference,
        frankencoin,
        owner,
        nonOwner,
        ccipLocalSimulatorConfig,
      } = await loadFixture(deployFixture);
      const recipient = ethers.Wallet.createRandom().address;
      await frankencoin.mint(
        await owner.getAddress(),
        ethers.parseEther("100")
      );
      await frankencoin.approve(
        await nonOwner.getAddress(),
        ethers.parseEther("100")
      );
      await expect(
        transferReference
          .connect(nonOwner)
          ["crossTransferFrom(uint64,address,bytes,uint256,bytes,string)"](
            ccipLocalSimulatorConfig.chainSelector_,
            await owner.getAddress(),
            ethers.AbiCoder.defaultAbiCoder().encode(["address"], [recipient]),
            ethers.parseEther("100"),
            "0x",
            "test"
          )
      ).revertedWithCustomError(transferReference, "InfiniteAllowanceRequired");
    });
  });
});
