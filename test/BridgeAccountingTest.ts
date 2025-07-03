import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";

describe("BridgeAccounting", () => {
  async function deployFixture() {
    const [owner, remoteFrankencoin, remotePool, router] =
      await ethers.getSigners();
    const chainSelector = 123456789;

    const frankencoinFactory = await ethers.getContractFactory("Frankencoin");
    const frankencoin = await frankencoinFactory.deploy(0);

    const tokenAdminRegistryFactory = await ethers.getContractFactory(
      "TokenAdminRegistry"
    );
    const tokenAdminRegistry = await tokenAdminRegistryFactory.deploy();

    const bridgeAccountingFactory = await ethers.getContractFactory(
      "BridgeAccounting"
    );
    const bridgeAccounting = await bridgeAccountingFactory.deploy(
      await frankencoin.getAddress(),
      await tokenAdminRegistry.getAddress(),
      await router.getAddress()
    );

    const tokenPoolFactory = await ethers.getContractFactory(
      "BurnMintTokenPool"
    );
    const tokenPool = await tokenPoolFactory.deploy(
      await frankencoin.getAddress(),
      18,
      [],
      await owner.getAddress(),
      await router.getAddress()
    );

    await tokenAdminRegistry.proposeAdministrator(
      await frankencoin.getAddress(),
      owner.address
    );
    await tokenAdminRegistry.acceptAdminRole(await frankencoin.getAddress());
    await tokenAdminRegistry.setPool(
      await frankencoin.getAddress(),
      await tokenPool.getAddress()
    );
    await frankencoin.initialize(
      await bridgeAccounting.getAddress(),
      "BridgeAccounting"
    );
    await frankencoin.initialize(await owner.getAddress(), "Owner");
    await tokenPool.applyChainUpdates(
      [],
      [
        {
          inboundRateLimiterConfig: {
            capacity: 0,
            rate: 0,
            isEnabled: false,
          },
          outboundRateLimiterConfig: {
            capacity: 0,
            rate: 0,
            isEnabled: false,
          },
          remoteChainSelector: chainSelector,
          remoteTokenAddress: ethers.AbiCoder.defaultAbiCoder().encode(
            ["address"],
            [await remoteFrankencoin.getAddress()]
          ),
          remotePoolAddresses: [
            ethers.AbiCoder.defaultAbiCoder().encode(
              ["address"],
              [await remotePool.getAddress()]
            ),
          ],
        },
      ]
    );

    return {
      frankencoin,
      tokenAdminRegistry,
      bridgeAccounting,
      router,
      chainSelector,
      tokenPool,
      remotePool,
      remoteFrankencoin,
      owner,
    };
  }

  it("should validate the sender", async () => {
    const { owner, bridgeAccounting, router, chainSelector } =
      await loadFixture(deployFixture);
    const abicoder = ethers.AbiCoder.defaultAbiCoder();

    await expect(
      bridgeAccounting.connect(router).ccipReceive({
        messageId:
          "0x0000000000000000000000000000000000000000000000000000000000000001",
        sourceChainSelector: chainSelector,
        sender: abicoder.encode(["address"], [await owner.getAddress()]),
        data: abicoder.encode(["uint256", "uint256"], [0, 0]),
        destTokenAmounts: [],
      })
    ).revertedWithCustomError(bridgeAccounting, "InvalidSender");
  });

  it("should fail if the remote sender is 0x00 and the chain is not supported", async () => {
    const { bridgeAccounting, router } =
    await loadFixture(deployFixture);


    const abicoder = ethers.AbiCoder.defaultAbiCoder();

    await expect(
      bridgeAccounting.connect(router).ccipReceive({
        messageId:
          "0x0000000000000000000000000000000000000000000000000000000000000001",
        sourceChainSelector: '12345',
        sender: abicoder.encode(["address"], [ethers.ZeroAddress]),
        data: abicoder.encode(["uint256", "uint256"], [0, 0]),
        destTokenAmounts: [],
      })
    ).revertedWithCustomError(bridgeAccounting, "InvalidSender");
  })

  it("should handle profits", async () => {
    const {
      bridgeAccounting,
      router,
      chainSelector,
      remoteFrankencoin,
      frankencoin,
    } = await loadFixture(deployFixture);
    const abicoder = ethers.AbiCoder.defaultAbiCoder();
    await frankencoin.mint(
      await bridgeAccounting.getAddress(),
      ethers.parseEther("10")
    );
    const tx = bridgeAccounting.connect(router).ccipReceive({
      messageId:
        "0x0000000000000000000000000000000000000000000000000000000000000001",
      sourceChainSelector: chainSelector,
      sender: abicoder.encode(
        ["address"],
        [await remoteFrankencoin.getAddress()]
      ),
      data: abicoder.encode(["uint256", "uint256"], [50, 0]),
      destTokenAmounts: [],
    });

    await expect(tx)
      .to.emit(bridgeAccounting, "ReceivedProfits")
      .withArgs(ethers.parseEther("10"))
      .emit(frankencoin, "Profit")
      .withArgs(await bridgeAccounting.getAddress(), ethers.parseEther("10"));
    await expect(tx).changeTokenBalance(
      frankencoin,
      await bridgeAccounting.getAddress(),
      ethers.parseEther("-10")
    );
    await expect(tx).changeTokenBalance(
      frankencoin,
      await frankencoin.reserve(),
      ethers.parseEther("10")
    );
  });

  it("should handle losses", async () => {
    const {
      bridgeAccounting,
      router,
      chainSelector,
      remoteFrankencoin,
      frankencoin,
    } = await loadFixture(deployFixture);
    const abicoder = ethers.AbiCoder.defaultAbiCoder();
    await frankencoin.mint(
      await frankencoin.reserve(),
      ethers.parseEther("10.0")
    );

    const tx = bridgeAccounting.connect(router).ccipReceive({
      messageId:
        "0x0000000000000000000000000000000000000000000000000000000000000001",
      sourceChainSelector: chainSelector,
      sender: abicoder.encode(
        ["address"],
        [await remoteFrankencoin.getAddress()]
      ),
      data: abicoder.encode(
        ["uint256", "uint256"],
        [0, ethers.parseEther("50.0")]
      ),
      destTokenAmounts: [],
    });

    await expect(tx)
      .to.emit(bridgeAccounting, "ReceivedLosses")
      .withArgs(ethers.parseEther("50.0"))
      .emit(frankencoin, "Loss")
      .withArgs(await bridgeAccounting.getAddress(), ethers.parseEther("50.0"));
    await expect(tx).changeTokenBalance(
      frankencoin,
      await frankencoin.reserve(),
      ethers.parseEther("-10.0")
    );
    await expect(tx).changeTokenBalance(
      frankencoin,
      await bridgeAccounting.getAddress(),
      0
    );
  });
});
