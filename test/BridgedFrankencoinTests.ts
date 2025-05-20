import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import { AddressLike, BigNumberish, ContractRunner } from "ethers";
import { ethers } from "hardhat";

describe("BridgedFrankencoin", () => {
  async function deployFixture() {
    const [owner, bridgeAccounting, mainnetGovernance, newMinter, ccipAdmin] =
      await ethers.getSigners();

    const ccipLocalSimualtorFactory = await ethers.getContractFactory(
      "CCIPLocalSimulator"
    );
    const ccipLocalSimulator = await ccipLocalSimualtorFactory.deploy();
    const ccipLocalSimulatorConfig = await ccipLocalSimulator.configuration();

    const bridgedFrankencoinFactory = await ethers.getContractFactory(
      "BridgedFrankencoin"
    );
    const bridgedGovernanceFactory = await ethers.getContractFactory(
      "BridgedGovernance"
    );
    const bridgedGovernance = await bridgedGovernanceFactory.deploy(
      ccipLocalSimulatorConfig.destinationRouter_,
      ccipLocalSimulatorConfig.chainSelector_,
      await mainnetGovernance.getAddress()
    );
    const bridgedFrankencoin = await bridgedFrankencoinFactory.deploy(
      await bridgedGovernance.getAddress(),
      ccipLocalSimulatorConfig.destinationRouter_,
      864000,
      ccipLocalSimulatorConfig.linkToken_,
      ccipLocalSimulatorConfig.chainSelector_,
      await bridgeAccounting.getAddress(),
      await ccipAdmin.getAddress()
    );

    return {
      owner,
      bridgeAccounting,
      mainnetGovernance,
      ccipLocalSimulatorConfig,
      bridgedFrankencoin,
      bridgedGovernance,
      newMinter,
      ccipAdmin,
    };
  }

  async function getVotes(
    routerAddr: string,
    chainSelector: BigNumberish,
    mainnetGovernance: ContractRunner,
    target: AddressLike,
    voter: AddressLike,
    votes: number
  ) {
    const abicoder = ethers.AbiCoder.defaultAbiCoder();
    const payload = abicoder.encode(
      [
        "((address voter, uint256 votes, address delegatee)[] votes, uint256 totalVotes)",
      ],
      [
        {
          totalVotes: votes,
          votes: [
            {
              voter: voter,
              votes: votes,
              delegatee: ethers.ZeroAddress,
            },
          ],
        },
      ]
    );

    const router = await ethers.getContractAt("MockCCIPRouter", routerAddr);
    await router.connect(mainnetGovernance).ccipSend(chainSelector, {
      feeToken: ethers.ZeroAddress,
      data: payload,
      tokenAmounts: [],
      extraArgs: "0x",
      receiver: ethers.AbiCoder.defaultAbiCoder().encode(["address"], [target]),
    });
  }

  it("should return the correct name", async () => {
    const { bridgedFrankencoin } = await loadFixture(deployFixture);
    expect(await bridgedFrankencoin.name()).to.equal("Frankencoin");
  });

  it("should return the correct symbol", async () => {
    const { bridgedFrankencoin } = await loadFixture(deployFixture);
    expect(await bridgedFrankencoin.symbol()).to.equal("ZCHF");
  });

  describe("initialize", () => {
    it("should set the minters", async () => {
      const { bridgedFrankencoin, owner } = await loadFixture(deployFixture);
      const tx = await bridgedFrankencoin.initialize(
        [await owner.getAddress(), await bridgedFrankencoin.getAddress()],
        ["", ""]
      );
      const block = await tx.getBlock();
      expect(
        await bridgedFrankencoin.minters(await owner.getAddress())
      ).to.equal(block?.timestamp);
      expect(
        await bridgedFrankencoin.minters(await bridgedFrankencoin.getAddress())
      ).to.equal(block?.timestamp);
    });

    it("should initialize only once", async () => {
      const { owner, bridgedFrankencoin } = await loadFixture(deployFixture);
      await bridgedFrankencoin.initialize([await owner.getAddress()], [""]);
      await expect(
        bridgedFrankencoin.initialize([await owner.getAddress()], [""])
      ).revertedWithCustomError(bridgedFrankencoin, "AlreadyInitialized");
    });

    it("should revert when array lenghts don't match", async () => {
      const { bridgedFrankencoin, owner } = await loadFixture(deployFixture);
      await expect(
        bridgedFrankencoin.initialize([await owner.getAddress()], ["", ""])
      ).revertedWithCustomError(bridgedFrankencoin, "InvalidInput");
    });
  });

  describe("suggestMinter", () => {
    it("should revert PeriodTooShort", async () => {
      const { bridgedFrankencoin, newMinter } = await loadFixture(
        deployFixture
      );
      await expect(
        bridgedFrankencoin.suggestMinter(
          await newMinter.getAddress(),
          (await bridgedFrankencoin.MIN_APPLICATION_PERIOD()) - 10n,
          0,
          ""
        )
      ).revertedWithCustomError(bridgedFrankencoin, "PeriodTooShort");
    });

    it("should revert FeeTooLow", async () => {
      const { bridgedFrankencoin, newMinter } = await loadFixture(
        deployFixture
      );
      await expect(
        bridgedFrankencoin.suggestMinter(
          await newMinter.getAddress(),
          await bridgedFrankencoin.MIN_APPLICATION_PERIOD(),
          0,
          ""
        )
      ).revertedWithCustomError(bridgedFrankencoin, "FeeTooLow");
    });

    it("should revert AlreadyRegistered", async () => {
      const { bridgedFrankencoin, owner } = await loadFixture(deployFixture);
      await bridgedFrankencoin.initialize([await owner.getAddress()], [""]);
      await bridgedFrankencoin.mint(
        await owner.getAddress(),
        ethers.parseEther("10000")
      );
      await expect(
        bridgedFrankencoin.suggestMinter(
          await owner.getAddress(),
          await bridgedFrankencoin.MIN_APPLICATION_PERIOD(),
          await bridgedFrankencoin.MIN_FEE(),
          ""
        )
      ).revertedWithCustomError(bridgedFrankencoin, "AlreadyRegistered");
    });

    it("should collect profits", async () => {
      const { bridgedFrankencoin, owner, newMinter, bridgedGovernance } =
        await loadFixture(deployFixture);
      await bridgedFrankencoin.initialize([await owner.getAddress()], [""]);
      await bridgedFrankencoin.mint(
        await owner.getAddress(),
        ethers.parseEther("10000")
      );
      const minFee = await bridgedFrankencoin.MIN_FEE();
      const tx = bridgedFrankencoin.suggestMinter(
        await newMinter.getAddress(),
        await bridgedFrankencoin.MIN_APPLICATION_PERIOD(),
        minFee,
        ""
      );
      await expect(tx).changeTokenBalances(
        bridgedFrankencoin,
        [owner, bridgedGovernance],
        [minFee * -1n, minFee]
      );
      await expect(tx)
        .emit(bridgedFrankencoin, "Profit")
        .withArgs(await bridgedFrankencoin.getAddress(), minFee);
    });

    it("should set the minter pending", async () => {
      const { bridgedFrankencoin, owner, newMinter } = await loadFixture(
        deployFixture
      );
      await bridgedFrankencoin.initialize([await owner.getAddress()], [""]);
      await bridgedFrankencoin.mint(
        await owner.getAddress(),
        ethers.parseEther("10000")
      );

      const tx = await bridgedFrankencoin.suggestMinter(
        await newMinter.getAddress(),
        await bridgedFrankencoin.MIN_APPLICATION_PERIOD(),
        await bridgedFrankencoin.MIN_FEE(),
        "message"
      );
      const block = await tx.getBlock();

      expect(
        await bridgedFrankencoin.minters(await newMinter.getAddress())
      ).to.equal(
        BigInt(block?.timestamp ?? 0) +
          (await bridgedFrankencoin.MIN_APPLICATION_PERIOD())
      );
      expect(tx)
        .emit(bridgedFrankencoin, "MinterApplied")
        .withArgs(
          await newMinter.getAddress(),
          await bridgedFrankencoin.MIN_APPLICATION_PERIOD(),
          await bridgedFrankencoin.MIN_FEE(),
          "message"
        );
    });
  });

  describe("registerPosition", () => {
    it("should revert NotMinter", async () => {
      const { bridgedFrankencoin, owner, newMinter } = await loadFixture(
        deployFixture
      );
      await bridgedFrankencoin.initialize([await owner.getAddress()], [""]);
      await expect(
        bridgedFrankencoin
          .connect(newMinter)
          .registerPosition(await owner.getAddress())
      ).revertedWithCustomError(bridgedFrankencoin, "NotMinter");
    });

    it("should register it", async () => {
      const { bridgedFrankencoin, owner, newMinter } = await loadFixture(
        deployFixture
      );
      await bridgedFrankencoin.initialize([await owner.getAddress()], [""]);
      await bridgedFrankencoin.registerPosition(await newMinter.getAddress());

      expect(
        await bridgedFrankencoin.positions(await newMinter.getAddress())
      ).to.equal(await owner.getAddress());
    });
  });

  describe("denyMinter", () => {
    it("should revert if too late", async () => {
      const { bridgedFrankencoin, owner } = await loadFixture(deployFixture);
      await bridgedFrankencoin.initialize([await owner.getAddress()], [""]);
      await expect(
        bridgedFrankencoin.denyMinter(await owner.getAddress(), [], "")
      ).revertedWithCustomError(bridgedFrankencoin, "TooLate");
    });

    it("should check if qualified", async () => {
      const {
        bridgedFrankencoin,
        owner,
        newMinter,
        bridgedGovernance,
        ccipLocalSimulatorConfig,
        mainnetGovernance,
      } = await loadFixture(deployFixture);
      await bridgedFrankencoin.initialize([await owner.getAddress()], [""]);
      await bridgedFrankencoin.mint(
        await owner.getAddress(),
        ethers.parseEther("10000")
      );
      await getVotes(
        ccipLocalSimulatorConfig.sourceRouter_,
        ccipLocalSimulatorConfig.chainSelector_,
        mainnetGovernance,
        await bridgedGovernance.getAddress(),
        ethers.ZeroAddress,
        10000
      );
      await bridgedFrankencoin.suggestMinter(
        await newMinter.getAddress(),
        await bridgedFrankencoin.MIN_APPLICATION_PERIOD(),
        await bridgedFrankencoin.MIN_FEE(),
        "message"
      );
      await expect(
        bridgedFrankencoin.denyMinter(await newMinter.getAddress(), [], "")
      ).revertedWithCustomError(bridgedGovernance, "NotQualified");
    });

    it("should deny it", async () => {
      const {
        bridgedFrankencoin,
        owner,
        newMinter,
        bridgedGovernance,
        ccipLocalSimulatorConfig,
        mainnetGovernance,
      } = await loadFixture(deployFixture);
      await bridgedFrankencoin.initialize([await owner.getAddress()], [""]);
      await bridgedFrankencoin.mint(
        await owner.getAddress(),
        ethers.parseEther("10000")
      );
      await getVotes(
        ccipLocalSimulatorConfig.sourceRouter_,
        ccipLocalSimulatorConfig.chainSelector_,
        mainnetGovernance,
        await bridgedGovernance.getAddress(),
        await owner.getAddress(),
        10000
      );
      await bridgedFrankencoin.suggestMinter(
        await newMinter.getAddress(),
        await bridgedFrankencoin.MIN_APPLICATION_PERIOD(),
        await bridgedFrankencoin.MIN_FEE(),
        "message"
      );
      await expect(
        bridgedFrankencoin.denyMinter(
          await newMinter.getAddress(),
          [],
          "message"
        )
      )
        .emit(bridgedFrankencoin, "MinterDenied")
        .withArgs(await newMinter.getAddress(), "message");
      expect(
        await bridgedFrankencoin.minters(await newMinter.getAddress())
      ).to.equal(0);
    });
  });

  describe("mint", () => {
    it("should revert", async () => {
      const { bridgedFrankencoin, owner } = await loadFixture(deployFixture);
      await expect(
        bridgedFrankencoin.mint(
          await owner.getAddress(),
          ethers.parseEther("10000")
        )
      ).revertedWithCustomError(bridgedFrankencoin, "NotMinter");
    });

    it("should mint", async () => {
      const { bridgedFrankencoin, owner, newMinter } = await loadFixture(
        deployFixture
      );
      await bridgedFrankencoin.initialize([await owner.getAddress()], [""]);
      await bridgedFrankencoin.registerPosition(await newMinter.getAddress());
      await expect(
        bridgedFrankencoin.mint(
          await owner.getAddress(),
          ethers.parseEther("10000")
        )
      ).changeTokenBalance(
        bridgedFrankencoin,
        await owner.getAddress(),
        ethers.parseEther("10000")
      );
    });
  });

  describe("burn", () => {
    it("should burn", async () => {
      const { bridgedFrankencoin, owner, newMinter } = await loadFixture(
        deployFixture
      );
      await bridgedFrankencoin.initialize([await owner.getAddress()], [""]);
      await bridgedFrankencoin.registerPosition(await newMinter.getAddress());
      await bridgedFrankencoin.mint(
        await owner.getAddress(),
        ethers.parseEther("10000")
      );
      await expect(
        bridgedFrankencoin.burn(ethers.parseEther("10000"))
      ).changeTokenBalance(
        bridgedFrankencoin,
        await owner.getAddress(),
        ethers.parseEther("-10000")
      );
    });
  });

  describe("burnFrom", () => {
    it("should revert", async () => {
      const { bridgedFrankencoin, owner, newMinter } = await loadFixture(
        deployFixture
      );
      await expect(
        bridgedFrankencoin.burnFrom(
          await newMinter.getAddress(),
          ethers.parseEther("10000")
        )
      ).revertedWithCustomError(bridgedFrankencoin, "NotMinter");
    });

    it("should burn from", async () => {
      const { bridgedFrankencoin, owner, newMinter } = await loadFixture(
        deployFixture
      );
      await bridgedFrankencoin.initialize([await owner.getAddress()], [""]);
      await bridgedFrankencoin.mint(
        await newMinter.getAddress(),
        ethers.parseEther("10000")
      );
      await expect(
        bridgedFrankencoin.burnFrom(
          await newMinter.getAddress(),
          ethers.parseEther("10000")
        )
      ).changeTokenBalance(
        bridgedFrankencoin,
        await newMinter.getAddress(),
        ethers.parseEther("-10000")
      );
    });
  });

  describe("canMint", () => {
    it("should return false", async () => {
      const { bridgedFrankencoin, newMinter } = await loadFixture(
        deployFixture
      );
      expect(
        await bridgedFrankencoin.canMint(await newMinter.getAddress())
      ).to.equal(false);
    });

    it("should return true (minter)", async () => {
      const { bridgedFrankencoin, owner } = await loadFixture(deployFixture);
      await bridgedFrankencoin.initialize([await owner.getAddress()], [""]);
      expect(
        await bridgedFrankencoin.canMint(await owner.getAddress())
      ).to.equal(true);
    });

    it("should return true (position)", async () => {
      const { bridgedFrankencoin, owner, newMinter } = await loadFixture(
        deployFixture
      );
      await bridgedFrankencoin.initialize([await owner.getAddress()], [""]);
      await bridgedFrankencoin.registerPosition(await newMinter.getAddress());
      expect(
        await bridgedFrankencoin.canMint(await newMinter.getAddress())
      ).to.equal(true);
    });
  });

  describe("coverLoss", () => {
    it("should revert NotMinter", async () => {
      const { bridgedFrankencoin, newMinter } = await loadFixture(
        deployFixture
      );
      await expect(
        bridgedFrankencoin.coverLoss(
          await newMinter.getAddress(),
          ethers.parseEther("10000")
        )
      ).revertedWithCustomError(bridgedFrankencoin, "NotMinter");
    });

    it("should mint loss and accure it", async () => {
      const { bridgedFrankencoin, owner } = await loadFixture(deployFixture);
      await bridgedFrankencoin.initialize([await owner.getAddress()], [""]);
      const tx = bridgedFrankencoin.coverLoss(
        await owner.getAddress(),
        ethers.parseEther("10000")
      );
      await expect(tx).changeTokenBalance(
        bridgedFrankencoin,
        await owner.getAddress(),
        ethers.parseEther("10000")
      );
      await expect(tx)
        .emit(bridgedFrankencoin, "Loss")
        .withArgs(await owner.getAddress(), ethers.parseEther("10000"));
      expect(await bridgedFrankencoin.accruedLoss()).to.equal(
        ethers.parseEther("10000")
      );
    });

    it("should transfer from the reservice", async () => {
      const { bridgedFrankencoin, owner } = await loadFixture(deployFixture);
      await bridgedFrankencoin.initialize([await owner.getAddress()], [""]);
      await bridgedFrankencoin.mint(
        await bridgedFrankencoin.reserve(),
        ethers.parseEther("10000")
      );
      const tx = bridgedFrankencoin.coverLoss(
        await owner.getAddress(),
        ethers.parseEther("10000")
      );
      await expect(tx).changeTokenBalance(
        bridgedFrankencoin,
        await owner.getAddress(),
        ethers.parseEther("10000")
      );
      await expect(tx).changeTokenBalance(
        bridgedFrankencoin,
        await bridgedFrankencoin.reserve(),
        ethers.parseEther("-10000")
      );
      await expect(tx)
        .emit(bridgedFrankencoin, "Loss")
        .withArgs(await owner.getAddress(), ethers.parseEther("10000"));
      expect(await bridgedFrankencoin.accruedLoss()).to.equal(0);
    });

    it("should empty the reserve and accure the rest", async () => {
      const { bridgedFrankencoin, owner } = await loadFixture(deployFixture);
      await bridgedFrankencoin.initialize([await owner.getAddress()], [""]);
      await bridgedFrankencoin.mint(
        await bridgedFrankencoin.reserve(),
        ethers.parseEther("10000")
      );
      const tx = bridgedFrankencoin.coverLoss(
        await owner.getAddress(),
        ethers.parseEther("20000")
      );
      await expect(tx).changeTokenBalance(
        bridgedFrankencoin,
        await owner.getAddress(),
        ethers.parseEther("20000")
      );
      await expect(tx).changeTokenBalance(
        bridgedFrankencoin,
        await bridgedFrankencoin.reserve(),
        ethers.parseEther("-10000")
      );
      await expect(tx)
        .emit(bridgedFrankencoin, "Loss")
        .withArgs(await owner.getAddress(), ethers.parseEther("20000"));
      expect(await bridgedFrankencoin.accruedLoss()).to.equal(
        ethers.parseEther("10000")
      );
    });
  });

  describe("collectProfits", () => {
    it("should revert NotMinter", async () => {
      const { bridgedFrankencoin, newMinter } = await loadFixture(
        deployFixture
      );
      await expect(
        bridgedFrankencoin.collectProfits(
          await newMinter.getAddress(),
          ethers.parseEther("100")
        )
      ).revertedWithCustomError(bridgedFrankencoin, "NotMinter");
    });

    it("should transfer from the source", async () => {
      const { bridgedFrankencoin, newMinter, owner } = await loadFixture(
        deployFixture
      );
      await bridgedFrankencoin.initialize([await owner.getAddress()], [""]);
      await bridgedFrankencoin.mint(
        await newMinter.getAddress(),
        ethers.parseEther("10000")
      );

      const tx = bridgedFrankencoin.collectProfits(
        await newMinter.getAddress(),
        ethers.parseEther("100")
      );
      await expect(tx).changeTokenBalance(
        bridgedFrankencoin,
        await newMinter.getAddress(),
        ethers.parseEther("-100")
      );
      await expect(tx).changeTokenBalance(
        bridgedFrankencoin,
        await bridgedFrankencoin.reserve(),
        ethers.parseEther("100")
      );
      await expect(tx)
        .emit(bridgedFrankencoin, "Profit")
        .withArgs(await owner.getAddress(), ethers.parseEther("100"));
    });

    it("should reduce accuredLoss", async () => {
      const { bridgedFrankencoin, newMinter, owner } = await loadFixture(
        deployFixture
      );
      await bridgedFrankencoin.initialize([await owner.getAddress()], [""]);
      await bridgedFrankencoin.mint(
        await newMinter.getAddress(),
        ethers.parseEther("10000")
      );
      await bridgedFrankencoin.coverLoss(
        await owner.getAddress(),
        ethers.parseEther("10000")
      );
      const tx = bridgedFrankencoin.collectProfits(
        await newMinter.getAddress(),
        ethers.parseEther("100")
      );
      await expect(tx).changeTokenBalance(
        bridgedFrankencoin,
        await bridgedFrankencoin.reserve(),
        0
      );
      expect(await bridgedFrankencoin.accruedLoss()).to.equal(
        ethers.parseEther("9900")
      );
    });

    it("should set accuredLoss to 0 and put the rest in the reserve", async () => {
      const { bridgedFrankencoin, newMinter, owner } = await loadFixture(
        deployFixture
      );
      await bridgedFrankencoin.initialize([await owner.getAddress()], [""]);
      await bridgedFrankencoin.mint(
        await newMinter.getAddress(),
        ethers.parseEther("10000")
      );
      await bridgedFrankencoin.coverLoss(
        await owner.getAddress(),
        ethers.parseEther("5000")
      );
      const tx = bridgedFrankencoin.collectProfits(
        await newMinter.getAddress(),
        ethers.parseEther("10000")
      );
      await expect(tx).changeTokenBalance(
        bridgedFrankencoin,
        await bridgedFrankencoin.reserve(),
        ethers.parseEther("5000")
      );
      expect(await bridgedFrankencoin.accruedLoss()).to.equal(0);
    });
  });

  describe("synchronizeAccounting", () => {
    it("should transfer the reserve", async () => {
      const { bridgedFrankencoin, owner } = await loadFixture(deployFixture);
      await bridgedFrankencoin.initialize([await owner.getAddress()], [""]);
      await bridgedFrankencoin.mint(
        await bridgedFrankencoin.reserve(),
        ethers.parseEther("10000")
      );

      const tx = bridgedFrankencoin["synchronizeAccounting()"]();
      await expect(tx).changeTokenBalance(
        bridgedFrankencoin,
        await bridgedFrankencoin.reserve(),
        ethers.parseEther("-10000")
      );
      await expect(tx).changeTokenBalance(
        bridgedFrankencoin,
        await bridgedFrankencoin.BRIDGE_ACCOUNTING(),
        ethers.parseEther("10000")
      );
    });

    it("should transfer the stats", async () => {
      const { bridgedFrankencoin, owner } = await loadFixture(deployFixture);
      await bridgedFrankencoin.initialize([await owner.getAddress()], [""]);
      await bridgedFrankencoin.coverLoss(
        await owner.getAddress(),
        ethers.parseEther("500")
      );
      await bridgedFrankencoin.mint(
        await bridgedFrankencoin.reserve(),
        ethers.parseEther("10000")
      );
      await expect(bridgedFrankencoin["synchronizeAccounting()"]())
        .emit(bridgedFrankencoin, "AccountingSynchronized")
        .withArgs(ethers.parseEther("10000"), ethers.parseEther("500"));
    });
  });

  describe("isMinter", () => {
    it("should return false (not minter)", async () => {
      const { bridgedFrankencoin, owner } = await loadFixture(deployFixture);
      expect(
        await bridgedFrankencoin.isMinter(await owner.getAddress())
      ).to.equal(false);
    });

    it("should return false (pending minter)", async () => {
      const { bridgedFrankencoin, owner, newMinter } = await loadFixture(
        deployFixture
      );
      await bridgedFrankencoin.initialize([await owner.getAddress()], [""]);
      await bridgedFrankencoin.mint(
        await owner.getAddress(),
        ethers.parseEther("10000")
      );
      await bridgedFrankencoin.suggestMinter(
        await newMinter.getAddress(),
        await bridgedFrankencoin.MIN_APPLICATION_PERIOD(),
        await bridgedFrankencoin.MIN_FEE(),
        ""
      );
      expect(
        await bridgedFrankencoin.isMinter(await newMinter.getAddress())
      ).to.equal(false);
    });

    it("should return true", async () => {
      const { bridgedFrankencoin, owner } = await loadFixture(deployFixture);
      await bridgedFrankencoin.initialize([await owner.getAddress()], [""]);
      expect(
        await bridgedFrankencoin.isMinter(await owner.getAddress())
      ).to.equal(true);
    });
  });

  describe("ccip transfer", () => {
    it("should transfer tokens from sender", async () => {
      const { bridgedFrankencoin, owner, newMinter, ccipLocalSimulatorConfig } =
        await loadFixture(deployFixture);
      await bridgedFrankencoin.initialize([await owner.getAddress()], [""]);
      await bridgedFrankencoin.mint(
        await owner.getAddress(),
        ethers.parseEther("10000")
      );

      const tx = bridgedFrankencoin["transfer(uint64,address,uint256)"](
        ccipLocalSimulatorConfig.chainSelector_,
        await newMinter.getAddress(),
        ethers.parseEther("100")
      );

      await expect(tx).changeTokenBalance(
        bridgedFrankencoin,
        await owner.getAddress(),
        ethers.parseEther("-100")
      );
      await expect(tx).changeTokenBalance(
        bridgedFrankencoin,
        await newMinter.getAddress(),
        ethers.parseEther("100")
      );
    });
  });

  describe("getCCIPAdmin", () => {
    it("should return the CCIP admin", async () => {
      const { bridgedFrankencoin, owner, ccipAdmin } = await loadFixture(
        deployFixture
      );
      await bridgedFrankencoin.initialize([await owner.getAddress()], [""]);
      expect(await bridgedFrankencoin.getCCIPAdmin()).to.equal(
        await ccipAdmin.getAddress()
      );
    });
  });
});
