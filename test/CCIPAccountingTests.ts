import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";

describe("CCIPAccountingTests", () => {
  async function deployFixture() {
    const [owner, rnmProxy, minter, mainnetUser, bridgedUser] =
      await ethers.getSigners();

    const ccipLocalSimualtorFactory = await ethers.getContractFactory(
      "CCIPLocalSimulator"
    );
    const ccipLocalSimulator = await ccipLocalSimualtorFactory.deploy();
    const ccipLocalSimulatorConfig = await ccipLocalSimulator.configuration();

    // Setup mainnet frankencoin
    const frankencoinFactory = await ethers.getContractFactory("Frankencoin");
    const frankencoin = await frankencoinFactory.deploy(10 * 86400);
    await frankencoin.initialize(await minter.getAddress(), "");

    const tokenPoolFactory = await ethers.getContractFactory(
      "BurnMintTokenPool"
    );
    const mainnetTokenPool = await tokenPoolFactory.deploy(
      await frankencoin.getAddress(),
      18,
      [],
      await rnmProxy.getAddress(),
      ccipLocalSimulatorConfig.sourceRouter_
    );

    const tokenAdminRegistryFactory = await ethers.getContractFactory(
      "TokenAdminRegistry"
    );
    const mainnetTokenAdminRegistry = await tokenAdminRegistryFactory.deploy();

    const ccipAdminFactory = await ethers.getContractFactory("CCIPAdmin");
    const mainnetCcipAdmin = await ccipAdminFactory.deploy(
      await mainnetTokenAdminRegistry.getAddress(),
      await frankencoin.getAddress()
    );

    const governanceSenderFactory = await ethers.getContractFactory(
      "GovernanceSender"
    );
    const governanceSender = await governanceSenderFactory.deploy(
      await frankencoin.reserve(),
      ccipLocalSimulatorConfig.sourceRouter_,
      ccipLocalSimulatorConfig.linkToken_
    );

    const leadrateFactory = await ethers.getContractFactory("Leadrate");
    const leadrate = await leadrateFactory.deploy(
      await frankencoin.reserve(),
      500
    );

    const leadrateSenderFactory = await ethers.getContractFactory(
      "LeadrateSender"
    );
    const leadrateSender = await leadrateSenderFactory.deploy(
      await leadrate.getAddress(),
      ccipLocalSimulatorConfig.sourceRouter_,
      ccipLocalSimulatorConfig.linkToken_
    );

    const bridgeAccountingFactory = await ethers.getContractFactory(
      "BridgeAccounting"
    );
    const bridgeAccounting = await bridgeAccountingFactory.deploy(
      await frankencoin.getAddress(),
      await mainnetTokenAdminRegistry.getAddress(),
      ccipLocalSimulatorConfig.sourceRouter_
    );
    await frankencoin.initialize(await bridgeAccounting.getAddress(), "");

    // Setup l2 frankencoin
    const bridgedGovernanceFactory = await ethers.getContractFactory(
      "BridgedGovernance"
    );
    const bridgedGovernance = await bridgedGovernanceFactory.deploy(
      ccipLocalSimulatorConfig.destinationRouter_,
      ccipLocalSimulatorConfig.chainSelector_,
      await frankencoin.reserve()
    );

    const bridgedTokenAdminRegistry = await tokenAdminRegistryFactory.deploy();
    const registryModuleFactory = await ethers.getContractFactory(
      "RegistryModuleOwnerCustom"
    );
    const bridgedRegistryModule = await registryModuleFactory.deploy(
      await bridgedTokenAdminRegistry.getAddress()
    );
    await bridgedTokenAdminRegistry.addRegistryModule(
      await bridgedRegistryModule.getAddress()
    );

    const bridgedFrankencoinFactory = await ethers.getContractFactory(
      "BridgedFrankencoin"
    );
    const deployerNonce = await ethers.provider.getTransactionCount(
      await owner.getAddress()
    );
    const bridgedCcipAdminAddress = await ethers.getCreateAddress({
      from: await owner.getAddress(),
      nonce: deployerNonce + 1,
    });
    const bridgedFrankencoin = await bridgedFrankencoinFactory.deploy(
      await bridgedGovernance.getAddress(),
      ccipLocalSimulatorConfig.destinationRouter_,
      10 * 86400,
      ccipLocalSimulatorConfig.linkToken_,
      ccipLocalSimulatorConfig.chainSelector_,
      await bridgeAccounting.getAddress(),
      bridgedCcipAdminAddress
    );

    const bridgedCcipAdmin = await ccipAdminFactory.deploy(
      await bridgedTokenAdminRegistry.getAddress(),
      await bridgedFrankencoin.getAddress()
    );

    const bridgedLeadrateFactory = await ethers.getContractFactory(
      "BridgedLeadrate"
    );
    const bridgedLeadrate = await bridgedLeadrateFactory.deploy(
      ccipLocalSimulatorConfig.destinationRouter_,
      500,
      ccipLocalSimulatorConfig.chainSelector_,
      await leadrate.getAddress()
    );

    const bridgedTokenPool = await tokenPoolFactory.deploy(
      await bridgedFrankencoin.getAddress(),
      18,
      [],
      await rnmProxy.getAddress(),
      ccipLocalSimulatorConfig.destinationRouter_
    );

    await bridgedFrankencoin.initialize([await minter.getAddress()], [""]);

    // setup tokenpools
    await mainnetTokenAdminRegistry.proposeAdministrator(
      await frankencoin.getAddress(),
      await mainnetCcipAdmin.getAddress()
    );

    const abicoder = ethers.AbiCoder.defaultAbiCoder();
    await mainnetTokenPool.applyChainUpdates(
      [],
      [
        {
          inboundRateLimiterConfig: {
            capacity: 0,
            isEnabled: false,
            rate: 0,
          },
          outboundRateLimiterConfig: {
            capacity: 0,
            isEnabled: false,
            rate: 0,
          },
          remoteChainSelector: ccipLocalSimulatorConfig.chainSelector_,
          remotePoolAddresses: [
            abicoder.encode(["address"], [await bridgedTokenPool.getAddress()]),
          ],
          remoteTokenAddress: abicoder.encode(
            ["address"],
            [await bridgedFrankencoin.getAddress()]
          ),
        },
      ]
    );

    await bridgedTokenPool.applyChainUpdates(
      [],
      [
        {
          inboundRateLimiterConfig: {
            capacity: 0,
            isEnabled: false,
            rate: 0,
          },
          outboundRateLimiterConfig: {
            capacity: 0,
            isEnabled: false,
            rate: 0,
          },
          remoteChainSelector: ccipLocalSimulatorConfig.chainSelector_,
          remotePoolAddresses: [
            abicoder.encode(["address"], [await mainnetTokenPool.getAddress()]),
          ],
          remoteTokenAddress: abicoder.encode(
            ["address"],
            [await frankencoin.getAddress()]
          ),
        },
      ]
    );

    await mainnetTokenPool.transferOwnership(
      await mainnetCcipAdmin.getAddress()
    );
    await bridgedTokenPool.transferOwnership(
      await bridgedCcipAdmin.getAddress()
    );

    return {
      owner,
      minter,
      mainnetUser,
      bridgedUser,
      frankencoin,
      ccipLocalSimulator,
      ccipLocalSimulatorConfig,
      mainnetTokenPool,
      mainnetTokenAdminRegistry,
      mainnetCcipAdmin,
      governanceSender,
      leadrate,
      leadrateSender,
      bridgeAccounting,
      bridgedGovernance,
      bridgedFrankencoin,
      bridgedLeadrate,
      bridgedTokenPool,
      bridgedTokenAdminRegistry,
      bridgedCcipAdmin,
      bridgedRegistryModule,
    };
  }

  describe("CCIPAdmin", () => {
    describe("setup", () => {
      it("should setup mainnet", async () => {
        const {
          owner,
          mainnetCcipAdmin,
          mainnetTokenPool,
          mainnetTokenAdminRegistry,
          frankencoin,
        } = await loadFixture(deployFixture);
        const frankencoinAddress = await frankencoin.getAddress();
        const ccipAdminAddress = await mainnetCcipAdmin.getAddress();
        const tokenPoolAddress = await mainnetTokenPool.getAddress();

        await expect(
          mainnetCcipAdmin.acceptAdmin(await mainnetTokenPool.getAddress(), [])
        )
          .emit(mainnetTokenAdminRegistry, "AdministratorTransferred")
          .withArgs(frankencoinAddress, ccipAdminAddress)
          .emit(mainnetTokenAdminRegistry, "PoolSet")
          .withArgs(frankencoinAddress, ethers.ZeroAddress, tokenPoolAddress)
          .emit(mainnetTokenPool, "OwnershipTransferred")
          .withArgs(await owner.getAddress(), ccipAdminAddress);
        expect(
          await mainnetTokenAdminRegistry.getPool.staticCall(frankencoinAddress)
        ).to.eq(tokenPoolAddress);
      });

      it("should setup bridged", async () => {
        const {
          owner,
          bridgedCcipAdmin,
          bridgedTokenPool,
          bridgedTokenAdminRegistry,
          bridgedFrankencoin,
          bridgedRegistryModule,
        } = await loadFixture(deployFixture);
        const frankencoinAddress = await bridgedFrankencoin.getAddress();
        const ccipAdminAddress = await bridgedCcipAdmin.getAddress();
        const tokenPoolAddress = await bridgedTokenPool.getAddress();

        await expect(
          bridgedCcipAdmin.registerToken(
            await bridgedRegistryModule.getAddress(),
            await bridgedTokenPool.getAddress(),
            []
          )
        )
          .emit(bridgedRegistryModule, "AdministratorRegistered")
          .withArgs(frankencoinAddress, ccipAdminAddress)
          .emit(bridgedTokenAdminRegistry, "AdministratorTransferred")
          .withArgs(frankencoinAddress, ccipAdminAddress)
          .emit(bridgedTokenAdminRegistry, "PoolSet")
          .withArgs(frankencoinAddress, ethers.ZeroAddress, tokenPoolAddress)
          .emit(bridgedTokenPool, "OwnershipTransferred")
          .withArgs(await owner.getAddress(), ccipAdminAddress);
        expect(
          await bridgedTokenAdminRegistry.getPool.staticCall(frankencoinAddress)
        ).to.eq(tokenPoolAddress);
      });
    });

    describe("token transfers", () => {
      it("should transfer tokens from bridged to mainnet", async () => {
        const {
          bridgedFrankencoin,
          minter,
          ccipLocalSimulatorConfig,
          mainnetUser,
          bridgedUser,
        } = await loadFixture(deployFixture);

        await bridgedFrankencoin
          .connect(minter)
          .mint(await bridgedUser.getAddress(), ethers.parseEther("100000"));

        const tx = bridgedFrankencoin
          .connect(bridgedUser)
          ["transfer(uint64,address,uint256)"](
            ccipLocalSimulatorConfig.chainSelector_,
            await mainnetUser.getAddress(),
            ethers.parseEther("500")
          );

        await expect(tx).changeTokenBalance(
          bridgedFrankencoin,
          await bridgedUser.getAddress(),
          ethers.parseEther("-500")
        );
        // We cannot test if minting with token pools works
        // because the CCIP Local Simulator does not support it
        await expect(tx).changeTokenBalance(
          bridgedFrankencoin,
          await mainnetUser.getAddress(),
          ethers.parseEther("500")
        );
      });
    });

    describe("BridgeAccounting", () => {
      it("should manage losses", async () => {
        const {
          minter,
          bridgedFrankencoin,
          bridgeAccounting,
          frankencoin,
          mainnetCcipAdmin,
          bridgedCcipAdmin,
          mainnetTokenPool,
          bridgedTokenPool,
          bridgedRegistryModule,
        } = await loadFixture(deployFixture);

        await bridgedCcipAdmin.registerToken(
          await bridgedRegistryModule.getAddress(),
          await bridgedTokenPool.getAddress(),
          []
        );
        await mainnetCcipAdmin.acceptAdmin(
          await mainnetTokenPool.getAddress(),
          []
        );

        // report a loss
        const lossTx = bridgedFrankencoin
          .connect(minter)
          .coverLoss(await minter.getAddress(), ethers.parseEther("100"));
        await expect(lossTx).changeTokenBalance(
          bridgedFrankencoin,
          await minter.getAddress(),
          ethers.parseEther("100")
        );
        await expect(lossTx)
          .emit(bridgedFrankencoin, "Loss")
          .withArgs(await minter.getAddress(), ethers.parseEther("100"));

        const syncTx = bridgedFrankencoin["synchronizeAccounting()"]();

        // Check events
        await expect(syncTx)
          .emit(bridgedFrankencoin, "AccountingSynchronized")
          .withArgs(0, ethers.parseEther("100"));
        await expect(syncTx)
          .emit(bridgeAccounting, "ReceivedLosses")
          .withArgs(ethers.parseEther("100"));
        await expect(syncTx)
          .emit(frankencoin, "Loss")
          .withArgs(
            await bridgeAccounting.getAddress(),
            ethers.parseEther("100")
          );
        await expect(syncTx)
          .emit(frankencoin, "Transfer")
          .withArgs(
            await bridgeAccounting.getAddress(),
            ethers.ZeroAddress,
            ethers.parseEther("100")
          );

        // Check balances
        await expect(syncTx).changeTokenBalance(
          bridgedFrankencoin,
          await bridgedFrankencoin.getAddress(),
          0
        );
        await expect(syncTx).changeTokenBalance(
          bridgedFrankencoin,
          await bridgedFrankencoin.reserve(),
          0
        );
        await expect(syncTx).changeTokenBalance(
          frankencoin,
          await bridgeAccounting.getAddress(),
          0
        );
        await expect(syncTx).changeTokenBalance(
          frankencoin,
          await frankencoin.reserve(),
          0
        );

        // Check accounting
        expect(await bridgedFrankencoin.accruedLoss()).to.eq(0);
        expect(
          await bridgedFrankencoin.balanceOf(await bridgedFrankencoin.reserve())
        ).to.eq(0);
      });

      it("should manage profits", async () => {
        const {
          minter,
          bridgedFrankencoin,
          bridgeAccounting,
          frankencoin,
          mainnetCcipAdmin,
          bridgedCcipAdmin,
          mainnetTokenPool,
          bridgedTokenPool,
          bridgedRegistryModule,
        } = await loadFixture(deployFixture);

        await bridgedCcipAdmin.registerToken(
          await bridgedRegistryModule.getAddress(),
          await bridgedTokenPool.getAddress(),
          []
        );
        await mainnetCcipAdmin.acceptAdmin(
          await mainnetTokenPool.getAddress(),
          []
        );
        // mint profits
        await bridgedFrankencoin
          .connect(minter)
          .mint(await minter.getAddress(), ethers.parseEther("100"));
        // Mint needed because CCIP Local Simulator does not support minting with token pools
        await frankencoin
          .connect(minter)
          .mint(await bridgeAccounting.getAddress(), ethers.parseEther("100"));

        // report a profits
        const profitTx = bridgedFrankencoin
          .connect(minter)
          .collectProfits(await minter.getAddress(), ethers.parseEther("100"));

        await expect(profitTx).changeTokenBalance(
          bridgedFrankencoin,
          await minter.getAddress(),
          ethers.parseEther("-100")
        );
        await expect(profitTx).changeTokenBalance(
          bridgedFrankencoin,
          await bridgedFrankencoin.reserve(),
          ethers.parseEther("100")
        );
        await expect(profitTx)
          .emit(bridgedFrankencoin, "Profit")
          .withArgs(await minter.getAddress(), ethers.parseEther("100"));

        const syncTx = bridgedFrankencoin["synchronizeAccounting()"]();

        // Check events
        await expect(syncTx)
          .emit(bridgedFrankencoin, "AccountingSynchronized")
          .withArgs(ethers.parseEther("100"), 0);
        await expect(syncTx)
          .emit(bridgeAccounting, "ReceivedProfits")
          .withArgs(ethers.parseEther("100"));
        await expect(syncTx)
          .emit(frankencoin, "Profit")
          .withArgs(
            await bridgeAccounting.getAddress(),
            ethers.parseEther("100")
          );
        await expect(syncTx)
          .emit(frankencoin, "Transfer")
          .withArgs(
            await bridgeAccounting.getAddress(),
            await frankencoin.reserve(),
            ethers.parseEther("100")
          );

        // Check balances
        await expect(syncTx).changeTokenBalance(
          bridgedFrankencoin,
          await bridgedFrankencoin.getAddress(),
          0
        );
        await expect(syncTx).changeTokenBalance(
          bridgedFrankencoin,
          await bridgedFrankencoin.reserve(),
          ethers.parseEther("-100")
        );
        await expect(syncTx).changeTokenBalance(
          frankencoin,
          await bridgeAccounting.getAddress(),
          ethers.parseEther("-100") // Changed because of ccip local simulator
        );
        await expect(syncTx).changeTokenBalance(
          frankencoin,
          await frankencoin.reserve(),
          ethers.parseEther("100")
        );
        // Because CCIP Local Simulator does not support minting with token pools
        // the bridge account should have bridgedFrankencoin tokens
        await expect(syncTx).changeTokenBalance(
          bridgedFrankencoin,
          await bridgeAccounting.getAddress(),
          ethers.parseEther("100")
        );
      });
    });
  });
});
