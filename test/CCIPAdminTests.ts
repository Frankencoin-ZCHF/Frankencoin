import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import { Interface, Log } from "ethers";
import { ethers } from "hardhat";
import { evm_increaseTime } from "./helper";

describe("CCIP Admin Tests", () => {
  const abiCoder = ethers.AbiCoder.defaultAbiCoder();
  const remotePoolUpdate = {
    chain: 1234,
    poolAddress: "0x",
    add: false,
  };
  const chainLimiterUpdate = {
    chain: 1234,
    outboundConfig: {
      isEnabled: true,
      capacity: 1234,
      rate: 5678,
    },
    inboundConfig: {
      isEnabled: true,
      capacity: 1234,
      rate: 5678,
    },
  };
  const remoteChainUpdate = {
    chainToRemove: 1234,
    chainToAdd: {
      remoteChainSelector: 1234,
      remotePoolAddresses: ["0x"],
      remoteTokenAddress: "0x",
      outboundRateLimiterConfig: {
        isEnabled: true,
        capacity: 1234,
        rate: 5678,
      },
      inboundRateLimiterConfig: {
        isEnabled: true,
        capacity: 1234,
        rate: 5678,
      },
    },
  };
  const newAdmin = "0xc6ea8445A781a78be5892fA6c7F1856f0E44333F";

  async function deployFixture() {
    const [minter, singleVoter, delegatee, delegator] =
      await ethers.getSigners();

    const frankenCoinFactory = await ethers.getContractFactory("Frankencoin");
    const zchf = await frankenCoinFactory.deploy(10 * 864000);
    await zchf.initialize(minter.address, "");

    const tokenPoolFactory = await ethers.getContractFactory("TestTokenPool");
    const tokenPool = await tokenPoolFactory.deploy();

    const tokenAdminRegistryFactory = await ethers.getContractFactory(
      "TestTokenAdminRegistry"
    );
    const tokenAdminRegistry = await tokenAdminRegistryFactory.deploy();

    const registryModuleFactory = await ethers.getContractFactory(
      "TestRegistryModule"
    );
    const registryModule = await registryModuleFactory.deploy();

    const equity = await ethers.getContractAt("Equity", await zchf.reserve());

    const ccipAdminFactory = await ethers.getContractFactory("CCIPAdmin");
    const ccipAdmin = await ccipAdminFactory.deploy(
      await tokenAdminRegistry.getAddress(),
      await zchf.getAddress()
    );

    // Setup users
    await zchf.mintWithReserve(
      singleVoter.address,
      ethers.parseEther("10000"),
      "10000",
      "0"
    );
    await zchf.mintWithReserve(
      delegatee.address,
      ethers.parseEther("100"),
      "1",
      "0"
    );
    await zchf.mintWithReserve(
      delegator.address,
      ethers.parseEther("10000"),
      "10000",
      "0"
    );

    await equity
      .connect(singleVoter)
      .invest(await zchf.balanceOf(singleVoter.address), 0);
    await equity
      .connect(delegatee)
      .invest(await zchf.balanceOf(delegatee.address), 0);
    await equity
      .connect(delegator)
      .invest(await zchf.balanceOf(delegator.address), 0);

    await equity.connect(delegator).delegateVoteTo(delegatee.address);
    await expect(equity.checkQualified(delegatee.address, [])).to.eventually.be
      .rejected;
    await expect(
      await equity.checkQualified(delegatee.address, [delegator.address])
    );

    return {
      minter,
      singleVoter,
      delegatee,
      delegator,
      zchf,
      tokenPool,
      tokenAdminRegistry,
      ccipAdmin,
      equity,
      registryModule,
    };
  }

  function decodeFunctionCalledEvents(
    logs: Log[],
    contractInterface: Interface
  ) {
    const decoded = [];
    for (const log of logs) {
      const parsed = contractInterface.parseLog(log);
      if (parsed && parsed.name == "FunctionCalled") {
        decoded.push(parsed);
      }
    }

    return decoded;
  }

  describe("registerToken", () => {
    it("should register a token", async () => {
      const { ccipAdmin, registryModule, tokenPool, zchf } = await loadFixture(
        deployFixture
      );
      await expect(
        ccipAdmin.registerToken(
          await registryModule.getAddress(),
          await tokenPool.getAddress(),
          []
        )
      )
        .emit(registryModule, "FunctionCalled")
        .withArgs(
          "registerAdminViaGetCCIPAdmin",
          abiCoder.encode(["address"], [await zchf.getAddress()])
        );
    });

    it("should revert with AlreadyRegistered", async () => {
      const { ccipAdmin, registryModule, tokenAdminRegistry, zchf, tokenPool } =
        await loadFixture(deployFixture);
      await tokenAdminRegistry.setTokenConfig(await zchf.getAddress(), {
        administrator: await ccipAdmin.getAddress(),
        tokenPool: await tokenPool.getAddress(),
        pendingAdministrator: ethers.ZeroAddress,
      });
      await expect(
        ccipAdmin.registerToken(
          await registryModule.getAddress(),
          await tokenPool.getAddress(),
          []
        )
      ).revertedWithCustomError(ccipAdmin, "AlreadyRegistered");
    });

    it("should set the token pool", async () => {
      const { zchf, tokenAdminRegistry, tokenPool, registryModule } =
        await loadFixture(deployFixture);
      const ccipAdminFactory = await ethers.getContractFactory("CCIPAdmin");
      const ccipAdmin = await ccipAdminFactory.deploy(
        await tokenAdminRegistry.getAddress(),
        await zchf.getAddress()
      );

      await ccipAdmin.registerToken(
        await registryModule.getAddress(),
        await tokenPool.getAddress(),
        []
      );
      expect(await ccipAdmin.tokenPool()).to.equal(
        await tokenPool.getAddress()
      );
    });

    it("should call the tokenAdminRegistry", async () => {
      const { zchf, tokenAdminRegistry, tokenPool, registryModule } =
        await loadFixture(deployFixture);
      const ccipAdminFactory = await ethers.getContractFactory("CCIPAdmin");
      const ccipAdmin = await ccipAdminFactory.deploy(
        await tokenAdminRegistry.getAddress(),
        await zchf.getAddress()
      );

      const tx = ccipAdmin.registerToken(
        await registryModule.getAddress(),
        await tokenPool.getAddress(),
        []
      );
      await expect(tx)
        .emit(tokenAdminRegistry, "FunctionCalled")
        .withArgs(
          "setPool",
          abiCoder.encode(
            ["address", "address"],
            [await zchf.getAddress(), await tokenPool.getAddress()]
          )
        );
    });

    it("should apply the chain update", async () => {
      const { zchf, tokenAdminRegistry, tokenPool, registryModule } =
        await loadFixture(deployFixture);
      const ccipAdminFactory = await ethers.getContractFactory("CCIPAdmin");
      const ccipAdmin = await ccipAdminFactory.deploy(
        await tokenAdminRegistry.getAddress(),
        await zchf.getAddress()
      );

      const tx = ccipAdmin.registerToken(
        await registryModule.getAddress(),
        await tokenPool.getAddress(),
        [remoteChainUpdate.chainToAdd]
      );
      expect(tx)
        .emit(tokenPool, "FunctionCalled")
        .withArgs("applyChainUpdates");
    });
  });

  describe("acceptAdmin", () => {
    it("should accept admin", async () => {
      const { tokenAdminRegistry, ccipAdmin, tokenPool, zchf } =
        await loadFixture(deployFixture);

      const tx = ccipAdmin.acceptAdmin(await tokenPool.getAddress(), []);
      await expect(tx)
        .emit(tokenAdminRegistry, "FunctionCalled")
        .withArgs(
          "acceptAdminRole",
          abiCoder.encode(["address"], [await zchf.getAddress()])
        );
    });

    it("should set the token pool", async () => {
      const { zchf, tokenAdminRegistry, tokenPool } = await loadFixture(
        deployFixture
      );
      const ccipAdminFactory = await ethers.getContractFactory("CCIPAdmin");
      const ccipAdmin = await ccipAdminFactory.deploy(
        await tokenAdminRegistry.getAddress(),
        await zchf.getAddress()
      );

      await ccipAdmin.acceptAdmin(await tokenPool.getAddress(), []);
      expect(await ccipAdmin.tokenPool()).to.equal(
        await tokenPool.getAddress()
      );
    });

    it("should call the tokenAdminRegistry", async () => {
      const { zchf, tokenAdminRegistry, tokenPool } = await loadFixture(
        deployFixture
      );
      const ccipAdminFactory = await ethers.getContractFactory("CCIPAdmin");
      const ccipAdmin = await ccipAdminFactory.deploy(
        await tokenAdminRegistry.getAddress(),
        await zchf.getAddress()
      );

      const tx = ccipAdmin.acceptAdmin(await tokenPool.getAddress(), []);
      await expect(tx)
        .emit(tokenAdminRegistry, "FunctionCalled")
        .withArgs(
          "setPool",
          abiCoder.encode(
            ["address", "address"],
            [await zchf.getAddress(), await tokenPool.getAddress()]
          )
        );
    });

    it("should apply the chain update", async () => {
      const { zchf, tokenAdminRegistry, tokenPool } = await loadFixture(
        deployFixture
      );
      const ccipAdminFactory = await ethers.getContractFactory("CCIPAdmin");
      const ccipAdmin = await ccipAdminFactory.deploy(
        await tokenAdminRegistry.getAddress(),
        await zchf.getAddress()
      );

      const tx = ccipAdmin.acceptAdmin(await tokenPool.getAddress(), [
        remoteChainUpdate.chainToAdd,
      ]);
      expect(tx)
        .emit(tokenPool, "FunctionCalled")
        .withArgs("applyChainUpdates");
    });
  });

  describe("deny", () => {
    const hash = ethers.keccak256(
      abiCoder.encode(["string", "uint64"], ["removeChain", ethers.ZeroAddress])
    );

    it("should deny", async () => {
      const { ccipAdmin, singleVoter } = await loadFixture(deployFixture);
      await ccipAdmin
        .connect(singleVoter)
        .proposeRemoveChain(ethers.ZeroAddress, []);
      expect(await ccipAdmin.proposals(hash)).to.be.greaterThan(0);
      await expect(ccipAdmin.connect(singleVoter).deny(hash, [])).to.emit(
        ccipAdmin,
        "ProposalDenied"
      );
      expect(await ccipAdmin.proposals(hash)).to.equal(0);
    });

    it("should revert if proposal is unknown", async () => {
      const { ccipAdmin, singleVoter } = await loadFixture(deployFixture);
      await expect(
        ccipAdmin.connect(singleVoter).deny(hash, [])
      ).to.revertedWithCustomError(ccipAdmin, "UnknownProposal");
    });

    it("should forward helpers", async () => {
      const { ccipAdmin, delegatee, delegator } = await loadFixture(
        deployFixture
      );
      await expect(
        ccipAdmin.connect(delegatee).deny(hash, [delegator.address])
      ).to.revertedWithCustomError(ccipAdmin, "UnknownProposal");
    });

    it("should revert if not qualified", async () => {
      const { ccipAdmin, equity } = await loadFixture(deployFixture);
      await expect(ccipAdmin.deny(hash, [])).to.revertedWithCustomError(
        equity,
        "NotQualified"
      );
    });
  });

  describe("proposeRemotePoolUpdate", () => {
    const hash = ethers.keccak256(
      abiCoder.encode(
        ["string", "(bool add,uint64 chain,bytes poolAddress)"],
        ["remotePoolUpdate", remotePoolUpdate]
      )
    );

    it("should propose", async () => {
      const { ccipAdmin, singleVoter } = await loadFixture(deployFixture);
      await ccipAdmin
        .connect(singleVoter)
        .proposeRemotePoolUpdate(remotePoolUpdate, []);
      expect(await ccipAdmin.proposals(hash)).to.be.greaterThan(0);
    });

    it("should revert if already proposed", async () => {
      const { ccipAdmin, singleVoter } = await loadFixture(deployFixture);
      await ccipAdmin
        .connect(singleVoter)
        .proposeRemotePoolUpdate(remotePoolUpdate, []);
      await expect(
        ccipAdmin
          .connect(singleVoter)
          .proposeRemotePoolUpdate(remotePoolUpdate, [])
      ).to.revertedWithCustomError(ccipAdmin, "ProposalAlreadyMade");
    });

    it("should forward helpers", async () => {
      const { ccipAdmin, delegatee, delegator } = await loadFixture(
        deployFixture
      );
      await ccipAdmin
        .connect(delegatee)
        .proposeRemotePoolUpdate(remotePoolUpdate, [delegator.address]);
      expect(await ccipAdmin.proposals(hash)).to.be.greaterThan(0);
    });

    it("should revert if not qualified", async () => {
      const { ccipAdmin, equity } = await loadFixture(deployFixture);
      await expect(
        ccipAdmin.proposeRemotePoolUpdate(remotePoolUpdate, [])
      ).to.revertedWithCustomError(equity, "NotQualified");
    });

    it("should set the correct deadline", async () => {
      const { ccipAdmin, singleVoter } = await loadFixture(deployFixture);
      const tx = await ccipAdmin
        .connect(singleVoter)
        .proposeRemotePoolUpdate(remotePoolUpdate, []);
      const block = await tx.getBlock();
      expect(await ccipAdmin.proposals(hash)).to.be.greaterThan(
        block?.timestamp ?? 0 + 7 * 24 * 3600
      );
    });
  });

  describe("applyRemotePoolUpdate", () => {
    it("should apply (add)", async () => {
      const { ccipAdmin, singleVoter, tokenPool, registryModule } =
        await loadFixture(deployFixture);
      remotePoolUpdate.add = true;
      await ccipAdmin.registerToken(
        await registryModule.getAddress(),
        await tokenPool.getAddress(),
        []
      );

      await ccipAdmin
        .connect(singleVoter)
        .proposeRemotePoolUpdate(remotePoolUpdate, []);
      await evm_increaseTime(7 * 24 * 3600);
      const tx = ccipAdmin.applyRemotePoolUpdate(remotePoolUpdate);
      await expect(tx)
        .emit(tokenPool, "FunctionCalled")
        .withArgs(
          "addRemotePool",
          abiCoder.encode(
            ["uint64", "bytes"],
            [remotePoolUpdate.chain, remotePoolUpdate.poolAddress]
          )
        );
    });

    it("should apply (remove)", async () => {
      const { ccipAdmin, singleVoter, tokenPool, registryModule } =
        await loadFixture(deployFixture);
      remotePoolUpdate.add = false;
      await ccipAdmin.registerToken(
        await registryModule.getAddress(),
        await tokenPool.getAddress(),
        []
      );

      await ccipAdmin
        .connect(singleVoter)
        .proposeRemotePoolUpdate(remotePoolUpdate, []);
      await evm_increaseTime(7 * 24 * 3600);
      const tx = ccipAdmin.applyRemotePoolUpdate(remotePoolUpdate);
      await expect(tx)
        .emit(tokenPool, "FunctionCalled")
        .withArgs(
          "removeRemotePool",
          abiCoder.encode(
            ["uint64", "bytes"],
            [remotePoolUpdate.chain, remotePoolUpdate.poolAddress]
          )
        );
    });

    it("should revert if deadline not passed", async () => {
      const { ccipAdmin, singleVoter, registryModule, tokenPool } =
        await loadFixture(deployFixture);
      await ccipAdmin.registerToken(
        await registryModule.getAddress(),
        await tokenPool.getAddress(),
        []
      );

      await ccipAdmin
        .connect(singleVoter)
        .proposeRemotePoolUpdate(remotePoolUpdate, []);
      await expect(
        ccipAdmin.connect(singleVoter).applyRemotePoolUpdate(remotePoolUpdate)
      ).to.revertedWithCustomError(ccipAdmin, "TooEarly");
    });

    it("should revert if proposal is not known", async () => {
      const { ccipAdmin, singleVoter, registryModule, tokenPool } =
        await loadFixture(deployFixture);
      await ccipAdmin.registerToken(
        await registryModule.getAddress(),
        await tokenPool.getAddress(),
        []
      );

      await expect(
        ccipAdmin.connect(singleVoter).applyRemotePoolUpdate(remotePoolUpdate)
      ).to.revertedWithCustomError(ccipAdmin, "UnknownProposal");
    });

    it("should remove the deadline", async () => {
      const { ccipAdmin, singleVoter, registryModule, tokenPool } =
        await loadFixture(deployFixture);
      const hash = ethers.keccak256(
        abiCoder.encode(
          ["string", "(bool add,uint64 chain,bytes poolAddress)"],
          ["remotePoolUpdate", remotePoolUpdate]
        )
      );
      await ccipAdmin.registerToken(
        await registryModule.getAddress(),
        await tokenPool.getAddress(),
        []
      );

      await ccipAdmin
        .connect(singleVoter)
        .proposeRemotePoolUpdate(remotePoolUpdate, []);
      await evm_increaseTime(7 * 24 * 3600);
      await ccipAdmin.applyRemotePoolUpdate(remotePoolUpdate);
      expect(await ccipAdmin.proposals(hash)).to.equal(0);
    });

    it("should revert if tokenpool is not set", async () => {
      const { ccipAdmin, singleVoter } = await loadFixture(deployFixture);
      const hash = ethers.keccak256(
        abiCoder.encode(
          ["string", "(bool add,uint64 chain,bytes poolAddress)"],
          ["remotePoolUpdate", remotePoolUpdate]
        )
      );

      await ccipAdmin
        .connect(singleVoter)
        .proposeRemotePoolUpdate(remotePoolUpdate, []);
      await evm_increaseTime(7 * 24 * 3600);
      await expect(
        ccipAdmin.applyRemotePoolUpdate(remotePoolUpdate)
      ).revertedWithCustomError(ccipAdmin, "TokenPoolNotSet");
    });
  });

  describe("applyRateLimit", () => {
    it("should apply", async () => {
      const { ccipAdmin, singleVoter, tokenPool, registryModule } =
        await loadFixture(deployFixture);
      await ccipAdmin.registerToken(
        await registryModule.getAddress(),
        await tokenPool.getAddress(),
        []
      );
      const tx = await ccipAdmin
        .connect(singleVoter)
        .applyRateLimit(
          chainLimiterUpdate.chain,
          chainLimiterUpdate.inboundConfig,
          chainLimiterUpdate.outboundConfig,
          []
        );

      await expect(tx)
        .emit(tokenPool, "FunctionCalled")
        .withArgs(
          "setChainRateLimiterConfig",
          abiCoder.encode(
            [
              "uint64",
              "(bool isEnabled, uint128 capacity, uint128 rate)",
              "(bool isEnabled, uint128 capacity, uint128 rate)",
            ],
            [
              chainLimiterUpdate.chain,
              chainLimiterUpdate.inboundConfig,
              chainLimiterUpdate.outboundConfig,
            ]
          )
        );
    });

    it("should forward helpers", async () => {
      const { ccipAdmin, delegatee, delegator, tokenPool, registryModule } =
        await loadFixture(deployFixture);
      await ccipAdmin.registerToken(
        await registryModule.getAddress(),
        await tokenPool.getAddress(),
        []
      );
      const tx = await ccipAdmin
        .connect(delegatee)
        .applyRateLimit(
          chainLimiterUpdate.chain,
          chainLimiterUpdate.inboundConfig,
          chainLimiterUpdate.outboundConfig,
          [delegator.address]
        );
      await expect(tx)
        .emit(tokenPool, "FunctionCalled")
        .withArgs(
          "setChainRateLimiterConfig",
          abiCoder.encode(
            [
              "uint64",
              "(bool isEnabled, uint128 capacity, uint128 rate)",
              "(bool isEnabled, uint128 capacity, uint128 rate)",
            ],
            [
              chainLimiterUpdate.chain,
              chainLimiterUpdate.inboundConfig,
              chainLimiterUpdate.outboundConfig,
            ]
          )
        );
    });

    it("should revert if not qualified", async () => {
      const { ccipAdmin, equity } = await loadFixture(deployFixture);
      await expect(
        ccipAdmin.applyRateLimit(
          chainLimiterUpdate.chain,
          chainLimiterUpdate.inboundConfig,
          chainLimiterUpdate.outboundConfig,
          []
        )
      ).to.revertedWithCustomError(equity, "NotQualified");
    });

    it("should revert if tokenpool is not set", async () => {
      const { ccipAdmin, singleVoter } = await loadFixture(deployFixture);
      await expect(
        ccipAdmin
          .connect(singleVoter)
          .applyRateLimit(
            chainLimiterUpdate.chain,
            chainLimiterUpdate.inboundConfig,
            chainLimiterUpdate.outboundConfig,
            []
          )
      ).to.revertedWithCustomError(ccipAdmin, "TokenPoolNotSet");
    });
  });

  describe("proposeRemoveChain", async () => {
    const hash = ethers.keccak256(
      abiCoder.encode(
        ["string", "uint64"],
        ["removeChain", remoteChainUpdate.chainToRemove]
      )
    );

    it("should propose", async () => {
      const { ccipAdmin, singleVoter } = await loadFixture(deployFixture);
      await ccipAdmin
        .connect(singleVoter)
        .proposeRemoveChain(remoteChainUpdate.chainToRemove, []);
      expect(await ccipAdmin.proposals(hash)).to.be.greaterThan(0);
    });

    it("should revert if already proposed", async () => {
      const { ccipAdmin, singleVoter } = await loadFixture(deployFixture);

      await ccipAdmin
        .connect(singleVoter)
        .proposeRemoveChain(remoteChainUpdate.chainToRemove, []);
      await expect(
        ccipAdmin
          .connect(singleVoter)
          .proposeRemoveChain(remoteChainUpdate.chainToRemove, [])
      ).to.revertedWithCustomError(ccipAdmin, "ProposalAlreadyMade");
    });

    it("should forward helpers", async () => {
      const { ccipAdmin, delegatee, delegator } = await loadFixture(
        deployFixture
      );
      await ccipAdmin
        .connect(delegatee)
        .proposeRemoveChain(remoteChainUpdate.chainToRemove, [delegator]);
      expect(await ccipAdmin.proposals(hash)).to.be.greaterThan(0);
    });

    it("should revert if not qualified", async () => {
      const { ccipAdmin, equity } = await loadFixture(deployFixture);
      await expect(
        ccipAdmin.proposeRemoveChain(remoteChainUpdate.chainToRemove, [])
      ).to.revertedWithCustomError(equity, "NotQualified");
    });

    it("should set the correct deadline", async () => {
      const { ccipAdmin, singleVoter } = await loadFixture(deployFixture);
      const tx = await ccipAdmin
        .connect(singleVoter)
        .proposeRemoveChain(remoteChainUpdate.chainToRemove, []);
      const block = await tx.getBlock();
      expect(await ccipAdmin.proposals(hash)).to.be.greaterThan(
        block?.timestamp ?? 0 + 7 * 24 * 3600
      );
    });
  });

  describe("applyRemoveChain", () => {
    it("should apply", async () => {
      const { ccipAdmin, singleVoter, tokenPool, registryModule } =
        await loadFixture(deployFixture);
      await ccipAdmin.registerToken(
        await registryModule.getAddress(),
        await tokenPool.getAddress(),
        []
      );

      remotePoolUpdate.add = true;
      await ccipAdmin
        .connect(singleVoter)
        .proposeRemoveChain(remoteChainUpdate.chainToRemove, []);
      await evm_increaseTime(7 * 24 * 3600);

      const tx = ccipAdmin.applyRemoveChain(remoteChainUpdate.chainToRemove);
      expect(tx)
        .emit(tokenPool, "FunctionCalled")
        .withArgs(
          "applyChainUpdates",
          abiCoder.encode(
            ["uint64[]", "uint64[]"],
            [[remoteChainUpdate.chainToRemove], []]
          )
        );
    });

    it("should revert if deadline not passed", async () => {
      const { ccipAdmin, singleVoter, registryModule, tokenPool } =
        await loadFixture(deployFixture);
      await ccipAdmin.registerToken(
        await registryModule.getAddress(),
        await tokenPool.getAddress(),
        []
      );

      await ccipAdmin
        .connect(singleVoter)
        .proposeRemoveChain(remoteChainUpdate.chainToRemove, []);
      await expect(
        ccipAdmin
          .connect(singleVoter)
          .applyRemoveChain(remoteChainUpdate.chainToRemove)
      ).to.revertedWithCustomError(ccipAdmin, "TooEarly");
    });

    it("should revert if proposal is not known", async () => {
      const { ccipAdmin, singleVoter, registryModule, tokenPool } =
        await loadFixture(deployFixture);
      await ccipAdmin.registerToken(
        await registryModule.getAddress(),
        await tokenPool.getAddress(),
        []
      );

      await expect(
        ccipAdmin
          .connect(singleVoter)
          .applyRemoveChain(remoteChainUpdate.chainToRemove)
      ).to.revertedWithCustomError(ccipAdmin, "UnknownProposal");
    });

    it("should remove the deadline", async () => {
      const { ccipAdmin, singleVoter, registryModule, tokenPool } =
        await loadFixture(deployFixture);
      const hash = ethers.keccak256(
        abiCoder.encode(
          ["string", "uint64"],
          ["removeChain", remoteChainUpdate.chainToRemove]
        )
      );
      await ccipAdmin.registerToken(
        await registryModule.getAddress(),
        await tokenPool.getAddress(),
        []
      );

      await ccipAdmin
        .connect(singleVoter)
        .proposeRemoveChain(remoteChainUpdate.chainToRemove, []);
      await evm_increaseTime(7 * 24 * 3600);
      await ccipAdmin.applyRemoveChain(remoteChainUpdate.chainToRemove);
      expect(await ccipAdmin.proposals(hash)).to.equal(0);
    });

    it("should revert if tokenpool is not set", async () => {
      const { ccipAdmin, singleVoter } = await loadFixture(deployFixture);
      await ccipAdmin
        .connect(singleVoter)
        .proposeRemoveChain(remoteChainUpdate.chainToRemove, []);
      await evm_increaseTime(7 * 24 * 3600);
      await expect(
        ccipAdmin.applyRemoveChain(remoteChainUpdate.chainToRemove)
      ).to.revertedWithCustomError(ccipAdmin, "TokenPoolNotSet");
    });
  });

  describe("proposeAddChain", async () => {
    const hash = ethers.keccak256(
      abiCoder.encode(
        [
          "string",
          "(uint64 remoteChainSelector,bytes[] remotePoolAddresses,bytes remoteTokenAddress,(bool isEnabled,uint128 capacity,uint128 rate) outboundRateLimiterConfig,(bool isEnabled,uint128 capacity,uint128 rate) inboundRateLimiterConfig)",
        ],
        ["addChain", remoteChainUpdate.chainToAdd]
      )
    );

    it("should propose", async () => {
      const { ccipAdmin, singleVoter } = await loadFixture(deployFixture);
      await ccipAdmin
        .connect(singleVoter)
        .proposeAddChain(remoteChainUpdate.chainToAdd, []);
      expect(await ccipAdmin.proposals(hash)).to.be.greaterThan(0);
    });

    it("should revert if already proposed", async () => {
      const { ccipAdmin, singleVoter } = await loadFixture(deployFixture);
      await ccipAdmin
        .connect(singleVoter)
        .proposeAddChain(remoteChainUpdate.chainToAdd, []);
      await expect(
        ccipAdmin
          .connect(singleVoter)
          .proposeAddChain(remoteChainUpdate.chainToAdd, [])
      ).to.revertedWithCustomError(ccipAdmin, "ProposalAlreadyMade");
    });

    it("should forward helpers", async () => {
      const { ccipAdmin, delegatee, delegator } = await loadFixture(
        deployFixture
      );
      await ccipAdmin
        .connect(delegatee)
        .proposeAddChain(remoteChainUpdate.chainToAdd, [delegator]);
      expect(await ccipAdmin.proposals(hash)).to.be.greaterThan(0);
    });

    it("should revert if not qualified", async () => {
      const { ccipAdmin, equity } = await loadFixture(deployFixture);
      await expect(
        ccipAdmin.proposeAddChain(remoteChainUpdate.chainToAdd, [])
      ).to.revertedWithCustomError(equity, "NotQualified");
    });

    it("should set the correct deadline", async () => {
      const { ccipAdmin, singleVoter } = await loadFixture(deployFixture);
      const tx = await ccipAdmin
        .connect(singleVoter)
        .proposeAddChain(remoteChainUpdate.chainToAdd, []);
      const block = await tx.getBlock();
      expect(await ccipAdmin.proposals(hash)).to.be.greaterThan(
        block?.timestamp ?? 0 + 7 * 24 * 3600
      );
    });
  });

  describe("applyAddChain", () => {
    it("should apply", async () => {
      const { ccipAdmin, singleVoter, tokenPool, registryModule } =
        await loadFixture(deployFixture);
      await ccipAdmin.registerToken(
        await registryModule.getAddress(),
        await tokenPool.getAddress(),
        []
      );
      await ccipAdmin
        .connect(singleVoter)
        .proposeAddChain(remoteChainUpdate.chainToAdd, []);

      await evm_increaseTime(7 * 24 * 3600);

      const tx = ccipAdmin.applyAddChain(remoteChainUpdate.chainToAdd);
      await expect(tx)
        .emit(tokenPool, "FunctionCalled")
        .withArgs(
          "applyChainUpdates",
          abiCoder.encode(
            [
              "uint64[]",
              "(uint64 remoteChainSelector,bytes[] remotePoolAddresses,bytes remoteTokenAddress,(bool isEnabled,uint128 capacity,uint128 rate) outboundRateLimiterConfig,(bool isEnabled,uint128 capacity,uint128 rate) inboundRateLimiterConfig)[]",
            ],
            [[], [remoteChainUpdate.chainToAdd]]
          )
        );
    });

    it("should revert if deadline not passed", async () => {
      const { ccipAdmin, singleVoter, registryModule, tokenPool } =
        await loadFixture(deployFixture);
      await ccipAdmin.registerToken(
        await registryModule.getAddress(),
        await tokenPool.getAddress(),
        []
      );
      await ccipAdmin
        .connect(singleVoter)
        .proposeAddChain(remoteChainUpdate.chainToAdd, []);

      await expect(
        ccipAdmin
          .connect(singleVoter)
          .applyAddChain(remoteChainUpdate.chainToAdd)
      ).to.revertedWithCustomError(ccipAdmin, "TooEarly");
    });

    it("should revert if proposal is not known", async () => {
      const { ccipAdmin, singleVoter, registryModule, tokenPool } =
        await loadFixture(deployFixture);
      await ccipAdmin.registerToken(
        await registryModule.getAddress(),
        await tokenPool.getAddress(),
        []
      );

      await expect(
        ccipAdmin
          .connect(singleVoter)
          .applyAddChain(remoteChainUpdate.chainToAdd)
      ).to.revertedWithCustomError(ccipAdmin, "UnknownProposal");
    });

    it("should remove the deadline", async () => {
      const { ccipAdmin, singleVoter, registryModule, tokenPool } =
        await loadFixture(deployFixture);
      const hash = ethers.keccak256(
        abiCoder.encode(
          [
            "string",
            "(uint64 remoteChainSelector,bytes[] remotePoolAddresses,bytes remoteTokenAddress,(bool isEnabled,uint128 capacity,uint128 rate) outboundRateLimiterConfig,(bool isEnabled,uint128 capacity,uint128 rate) inboundRateLimiterConfig)",
          ],
          ["addChain", remoteChainUpdate.chainToAdd]
        )
      );
      await ccipAdmin.registerToken(
        await registryModule.getAddress(),
        await tokenPool.getAddress(),
        []
      );

      await ccipAdmin
        .connect(singleVoter)
        .proposeAddChain(remoteChainUpdate.chainToAdd, []);
      await evm_increaseTime(7 * 24 * 3600);
      await ccipAdmin.applyAddChain(remoteChainUpdate.chainToAdd);
      expect(await ccipAdmin.proposals(hash)).to.equal(0);
    });

    it("should revert if tokenpool is not set", async () => {
      const { ccipAdmin, singleVoter } = await loadFixture(deployFixture);
      await ccipAdmin
        .connect(singleVoter)
        .proposeAddChain(remoteChainUpdate.chainToAdd, []);

      await evm_increaseTime(7 * 24 * 3600);
      await expect(
        ccipAdmin.applyAddChain(remoteChainUpdate.chainToAdd)
      ).revertedWithCustomError(ccipAdmin, "TokenPoolNotSet");
    });
  });

  describe("proposeAdminTransfer", async () => {
    const hash = ethers.keccak256(
      abiCoder.encode(["string", "address"], ["adminTransfer", newAdmin])
    );

    it("should propose", async () => {
      const { ccipAdmin, singleVoter } = await loadFixture(deployFixture);
      await ccipAdmin.connect(singleVoter).proposeAdminTransfer(newAdmin, []);
      expect(await ccipAdmin.proposals(hash)).to.be.greaterThan(0);
    });

    it("should revert if already proposed", async () => {
      const { ccipAdmin, singleVoter } = await loadFixture(deployFixture);
      await ccipAdmin.connect(singleVoter).proposeAdminTransfer(newAdmin, []);
      await expect(
        ccipAdmin.connect(singleVoter).proposeAdminTransfer(newAdmin, [])
      ).to.revertedWithCustomError(ccipAdmin, "ProposalAlreadyMade");
    });

    it("should forward helpers", async () => {
      const { ccipAdmin, delegatee, delegator } = await loadFixture(
        deployFixture
      );
      await ccipAdmin
        .connect(delegatee)
        .proposeAdminTransfer(newAdmin, [delegator]);
      expect(await ccipAdmin.proposals(hash)).to.be.greaterThan(0);
    });

    it("should revert if not qualified", async () => {
      const { ccipAdmin, equity } = await loadFixture(deployFixture);
      await expect(
        ccipAdmin.proposeAdminTransfer(newAdmin, [])
      ).to.revertedWithCustomError(equity, "NotQualified");
    });

    it("should set the correct deadline", async () => {
      const { ccipAdmin, singleVoter } = await loadFixture(deployFixture);
      const tx = await ccipAdmin
        .connect(singleVoter)
        .proposeAdminTransfer(newAdmin, []);
      const block = await tx.getBlock();
      expect(await ccipAdmin.proposals(hash)).to.be.greaterThan(
        block?.timestamp ?? 0 + 21 * 24 * 3600
      );
    });
  });

  describe("applyAdminTransfer", () => {
    it("should apply", async () => {
      const {
        ccipAdmin,
        singleVoter,
        tokenPool,
        tokenAdminRegistry,
        zchf,
        registryModule,
      } = await loadFixture(deployFixture);

      await ccipAdmin.registerToken(
        await registryModule.getAddress(),
        await tokenPool.getAddress(),
        []
      );
      await ccipAdmin.connect(singleVoter).proposeAdminTransfer(newAdmin, []);

      await evm_increaseTime(21 * 24 * 3600);

      const tx = ccipAdmin.applyAdminTransfer(newAdmin);
      await expect(tx)
        .emit(tokenAdminRegistry, "FunctionCalled")
        .withArgs(
          "transferAdminRole",
          abiCoder.encode(
            ["address", "address"],
            [await zchf.getAddress(), newAdmin]
          )
        );
      await expect(tx)
        .emit(tokenPool, "FunctionCalled")
        .withArgs(
          "transferOwnership",
          abiCoder.encode(["address"], [newAdmin])
        );
    });

    it("should revert if deadline not passed", async () => {
      const { ccipAdmin, singleVoter } = await loadFixture(deployFixture);
      await ccipAdmin.connect(singleVoter).proposeAdminTransfer(newAdmin, []);
      await expect(
        ccipAdmin.connect(singleVoter).applyAdminTransfer(newAdmin)
      ).to.revertedWithCustomError(ccipAdmin, "TooEarly");
    });

    it("should revert if proposal is not known", async () => {
      const { ccipAdmin, singleVoter } = await loadFixture(deployFixture);
      await expect(
        ccipAdmin.connect(singleVoter).applyAdminTransfer(newAdmin)
      ).to.revertedWithCustomError(ccipAdmin, "UnknownProposal");
    });

    it("should remove the deadline", async () => {
      const { ccipAdmin, singleVoter } = await loadFixture(deployFixture);
      const hash = ethers.keccak256(
        abiCoder.encode(["string", "address"], ["adminTransfer", newAdmin])
      );

      await ccipAdmin.connect(singleVoter).proposeAdminTransfer(newAdmin, []);
      await evm_increaseTime(21 * 24 * 3600);
      await ccipAdmin.applyAdminTransfer(newAdmin);
      expect(await ccipAdmin.proposals(hash)).to.equal(0);
    });
  });

  describe("deny", () => {
    const hash = ethers.keccak256(
      abiCoder.encode(["string", "address"], ["adminTransfer", newAdmin])
    );

    it("should deny", async () => {
      const { ccipAdmin, singleVoter } = await loadFixture(deployFixture);
      await ccipAdmin.connect(singleVoter).proposeAdminTransfer(newAdmin, []);

      expect(await ccipAdmin.proposals(hash)).to.be.greaterThan(0);
      await expect(ccipAdmin.connect(singleVoter).deny(hash, [])).to.emit(
        ccipAdmin,
        "ProposalDenied"
      );
      expect(await ccipAdmin.proposals(hash)).to.equal(0);
    });

    it("should forward helpers", async () => {
      const { ccipAdmin, delegatee, delegator } = await loadFixture(
        deployFixture
      );
      await ccipAdmin
        .connect(delegatee)
        .proposeAdminTransfer(newAdmin, [delegator]);
      expect(await ccipAdmin.proposals(hash)).to.be.greaterThan(0);
      await expect(
        ccipAdmin.connect(delegatee).deny(hash, [delegator])
      ).to.emit(ccipAdmin, "ProposalDenied");
      expect(await ccipAdmin.proposals(hash)).to.equal(0);
    });

    it("should revert if proposal is unknown", async () => {
      const { ccipAdmin, singleVoter } = await loadFixture(deployFixture);
      await expect(
        ccipAdmin.connect(singleVoter).deny(hash, [])
      ).to.revertedWithCustomError(ccipAdmin, "UnknownProposal");
    });

    it("should revert if not qualified", async () => {
      const { ccipAdmin, equity } = await loadFixture(deployFixture);
      await expect(ccipAdmin.deny(hash, [])).to.revertedWithCustomError(
        equity,
        "NotQualified"
      );
    });
  });

  describe("migration", () => {
    it("migrate to new admin deployment", async () => {
      const {
        ccipAdmin,
        singleVoter,
        tokenPool,
        tokenAdminRegistry,
        zchf,
        registryModule,
      } = await loadFixture(deployFixture);

      await ccipAdmin.registerToken(
        await registryModule.getAddress(),
        await tokenPool.getAddress(),
        []
      );
      const ccipAdminFactory = await ethers.getContractFactory("CCIPAdmin");
      const newCcipAdmin = await ccipAdminFactory.deploy(
        await tokenAdminRegistry.getAddress(),
        await zchf.getAddress()
      );
      await ccipAdmin
        .connect(singleVoter)
        .proposeAdminTransfer(await ccipAdmin.getAddress(), []);

      await evm_increaseTime(21 * 24 * 3600);

      await ccipAdmin.applyAdminTransfer(await ccipAdmin.getAddress());
      await expect(newCcipAdmin.acceptAdmin(await tokenPool.getAddress(), []))
        .emit(tokenAdminRegistry, "FunctionCalled")
        .withArgs(
          "acceptAdminRole",
          abiCoder.encode(["address"], [await zchf.getAddress()])
        )
        .emit(tokenPool, "FunctionCalled")
        .withArgs("acceptOwnership", "0x");
    });
  });
});
