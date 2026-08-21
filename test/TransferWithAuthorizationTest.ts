import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

const INITIALIZER = "0x045a8395FE21CE34f0eC34d242c342ade4Ded5be";

const transferTypes = {
  TransferWithAuthorization: [
    { name: "from", type: "address" },
    { name: "to", type: "address" },
    { name: "value", type: "uint256" },
    { name: "validAfter", type: "uint256" },
    { name: "validBefore", type: "uint256" },
    { name: "nonce", type: "bytes32" },
  ],
};

const receiveTypes = {
  ReceiveWithAuthorization: [
    { name: "from", type: "address" },
    { name: "to", type: "address" },
    { name: "value", type: "uint256" },
    { name: "validAfter", type: "uint256" },
    { name: "validBefore", type: "uint256" },
    { name: "nonce", type: "bytes32" },
  ],
};

const cancelTypes = {
  CancelAuthorization: [
    { name: "authorizer", type: "address" },
    { name: "nonce", type: "bytes32" },
  ],
};

async function domainFor(verifyingContract: string) {
  const { chainId } = await ethers.provider.getNetwork();
  return {
    name: "Frankencoin",
    version: "1",
    chainId,
    verifyingContract,
  };
}

function packedSignature(sig: string) {
  const parsed = ethers.Signature.from(sig);
  return ethers.concat([parsed.r, parsed.s, ethers.toBeHex(parsed.v, 1)]);
}

async function impersonateInitializer() {
  await ethers.provider.send("hardhat_impersonateAccount", [INITIALIZER]);
  await ethers.provider.send("hardhat_setBalance", [
    INITIALIZER,
    "0x56BC75E2D63100000",
  ]);
  return ethers.getSigner(INITIALIZER);
}

describe("TransferWithAuthorizationV2", () => {
  async function deployV2() {
    const [owner, payer, payee, relayer] = await ethers.getSigners();
    const frankencoin = await ethers.deployContract("Frankencoin", [0]);
    await frankencoin.initialize(owner.address, "");

    const sidecar = await ethers.deployContract("TransferWithAuthorizationV2");
    const initializer = await impersonateInitializer();
    await sidecar.connect(initializer).initialize(await frankencoin.getAddress());

    await frankencoin.mint(owner.address, ethers.parseEther("1000"));
    await frankencoin.mint(payer.address, ethers.parseEther("1000"));
    await frankencoin.suggestMinter(
      await sidecar.getAddress(),
      await frankencoin.MIN_APPLICATION_PERIOD(),
      await frankencoin.MIN_FEE(),
      "EIP-3009 sidecar V2"
    );

    return { owner, payer, payee, relayer, frankencoin, sidecar };
  }

  // secp256k1 group order, used to build the malleable counterpart of a signature.
  const SECP256K1N =
    0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;

  function malleate(sig: string) {
    const parsed = ethers.Signature.from(sig);
    return {
      v: parsed.v === 27 ? 28 : 27,
      r: parsed.r,
      s: ethers.toBeHex(SECP256K1N - BigInt(parsed.s), 32),
    };
  }

  async function signTransfer(
    payer: SignerWithAddress,
    sidecarAddress: string,
    to: string,
    value: bigint,
    validAfter = 0n,
    validBefore?: bigint,
    nonce?: Uint8Array
  ) {
    const usedNonce = nonce ?? ethers.randomBytes(32);
    const usedValidBefore =
      validBefore ?? BigInt((await time.latest()) + 3600);
    const signature = await payer.signTypedData(
      await domainFor(sidecarAddress),
      transferTypes,
      {
        from: payer.address,
        to,
        value,
        validAfter,
        validBefore: usedValidBefore,
        nonce: usedNonce,
      }
    );
    return {
      signature,
      packed: packedSignature(signature),
      parsed: ethers.Signature.from(signature),
      nonce: usedNonce,
      validAfter,
      validBefore: usedValidBefore,
    };
  }

    it("exposes eip712Domain and forwards balanceOf", async () => {
    const { sidecar, payer, frankencoin } = await loadFixture(deployV2);
    const domain = await sidecar.eip712Domain();
    expect(domain.fields).to.equal("0x0f");
    expect(domain.name).to.equal("Frankencoin");
    expect(domain.version).to.equal("1");
    expect(domain.verifyingContract).to.equal(await sidecar.getAddress());
    expect(await sidecar.balanceOf(payer.address)).to.equal(
      await frankencoin.balanceOf(payer.address)
    );
  });

  it("executes transferWithAuthorization via v,r,s and bytes overloads", async () => {
    const { payer, payee, relayer, frankencoin, sidecar } =
      await loadFixture(deployV2);
    const value = ethers.parseEther("5");
    const first = await signTransfer(
      payer,
      await sidecar.getAddress(),
      payee.address,
      value
    );
    await sidecar
      .connect(relayer)
      [
        "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)"
      ](
        payer.address,
        payee.address,
        value,
        first.validAfter,
        first.validBefore,
        first.nonce,
        first.parsed.v,
        first.parsed.r,
        first.parsed.s
      );

    const second = await signTransfer(
      payer,
      await sidecar.getAddress(),
      payee.address,
      value
    );
    await expect(
      sidecar
        .connect(relayer)
        [
          "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)"
        ](
          payer.address,
          payee.address,
          value,
          second.validAfter,
          second.validBefore,
          second.nonce,
          second.packed
        )
    ).to.changeTokenBalances(frankencoin, [payer, payee], [-value, value]);
  });

  it("rejects replayed nonces", async () => {
    const { payer, payee, sidecar } = await loadFixture(deployV2);
    const value = ethers.parseEther("1");
    const auth = await signTransfer(
      payer,
      await sidecar.getAddress(),
      payee.address,
      value
    );
    const args = [
      payer.address,
      payee.address,
      value,
      auth.validAfter,
      auth.validBefore,
      auth.nonce,
      auth.packed,
    ] as const;
    await sidecar[
      "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)"
    ](...args);
    await expect(
      sidecar[
        "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)"
      ](...args)
    ).to.be.revertedWithCustomError(sidecar, "AuthorizationAlreadyUsed");
  });

  it("enforces validity window", async () => {
    const { payer, payee, sidecar } = await loadFixture(deployV2);
    const value = ethers.parseEther("1");
    const future = await signTransfer(
      payer,
      await sidecar.getAddress(),
      payee.address,
      value,
      BigInt((await time.latest()) + 1000)
    );
    await expect(
      sidecar[
        "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)"
      ](
        payer.address,
        payee.address,
        value,
        future.validAfter,
        future.validBefore,
        future.nonce,
        future.packed
      )
    ).to.be.revertedWithCustomError(sidecar, "AuthorizationNotYetValid");

    const expired = await signTransfer(
      payer,
      await sidecar.getAddress(),
      payee.address,
      value,
      0n,
      BigInt((await time.latest()) - 1)
    );
    await expect(
      sidecar[
        "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)"
      ](
        payer.address,
        payee.address,
        value,
        expired.validAfter,
        expired.validBefore,
        expired.nonce,
        expired.packed
      )
    ).to.be.revertedWithCustomError(sidecar, "AuthorizationExpired");
  });

  it("requires msg.sender == to for receiveWithAuthorization", async () => {
    const { payer, payee, relayer, frankencoin, sidecar } =
      await loadFixture(deployV2);
    const value = ethers.parseEther("3");
    const nonce = ethers.randomBytes(32);
    const validAfter = 0n;
    const validBefore = BigInt((await time.latest()) + 3600);
    const signature = await payer.signTypedData(
      await domainFor(await sidecar.getAddress()),
      receiveTypes,
      {
        from: payer.address,
        to: payee.address,
        value,
        validAfter,
        validBefore,
        nonce,
      }
    );
    const packed = packedSignature(signature);
    await expect(
      sidecar
        .connect(relayer)
        [
          "receiveWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)"
        ](
          payer.address,
          payee.address,
          value,
          validAfter,
          validBefore,
          nonce,
          packed
        )
    ).to.be.revertedWithCustomError(sidecar, "CallerMustBePayee");

    await expect(
      sidecar
        .connect(payee)
        [
          "receiveWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)"
        ](
          payer.address,
          payee.address,
          value,
          validAfter,
          validBefore,
          nonce,
          packed
        )
    ).to.changeTokenBalances(frankencoin, [payer, payee], [-value, value]);
  });

  it("cancels an unused nonce", async () => {
    const { payer, payee, sidecar } = await loadFixture(deployV2);
    const nonce = ethers.randomBytes(32);
    const cancelSig = await payer.signTypedData(
      await domainFor(await sidecar.getAddress()),
      cancelTypes,
      { authorizer: payer.address, nonce }
    );
    await sidecar["cancelAuthorization(address,bytes32,bytes)"](
      payer.address,
      nonce,
      packedSignature(cancelSig)
    );
    expect(await sidecar.authorizationState(payer.address, nonce)).to.equal(
      true
    );

    const value = ethers.parseEther("1");
    const auth = await signTransfer(
      payer,
      await sidecar.getAddress(),
      payee.address,
      value,
      0n,
      undefined,
      nonce
    );
    await expect(
      sidecar[
        "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)"
      ](
        payer.address,
        payee.address,
        value,
        auth.validAfter,
        auth.validBefore,
        auth.nonce,
        auth.packed
      )
    ).to.be.revertedWithCustomError(sidecar, "AuthorizationAlreadyUsed");
  });

  it("accepts ERC-1271 on the bytes overload and rejects it on EIP-3009 v,r,s", async () => {
    const { owner, payee, frankencoin, sidecar } = await loadFixture(deployV2);
    const wallet = await ethers.deployContract("TestContractWallet", [
      owner.address,
    ]);
    await frankencoin.mint(await wallet.getAddress(), ethers.parseEther("50"));

    const value = ethers.parseEther("8");
    const nonce = ethers.randomBytes(32);
    const validAfter = 0n;
    const validBefore = BigInt((await time.latest()) + 3600);
    const from = await wallet.getAddress();
    const signature = await owner.signTypedData(
      await domainFor(await sidecar.getAddress()),
      transferTypes,
      {
        from,
        to: payee.address,
        value,
        validAfter,
        validBefore,
        nonce,
      }
    );

    const parsed = ethers.Signature.from(signature);
    await expect(
      sidecar[
        "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)"
      ](
        from,
        payee.address,
        value,
        validAfter,
        validBefore,
        nonce,
        parsed.v,
        parsed.r,
        parsed.s
      )
    ).to.be.revertedWithCustomError(sidecar, "InvalidSignature");

    await expect(
      sidecar[
        "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)"
      ](
        from,
        payee.address,
        value,
        validAfter,
        validBefore,
        nonce,
        packedSignature(signature)
      )
    ).to.changeTokenBalances(
      frankencoin,
      [from, payee.address],
      [-value, value]
    );
  });

  it("turns reverting, short, and malformed ERC-1271 responses into InvalidSignature", async () => {
    const { payee, sidecar } = await loadFixture(deployV2);
    const validBefore = BigInt((await time.latest()) + 3600);

    for (const contractName of [
      "TestRevertingWallet",
      "TestShortReturnWallet",
      "TestMalformedReturnWallet",
    ]) {
      const wallet = await ethers.deployContract(contractName);
      const from = await wallet.getAddress();
      const nonce = ethers.randomBytes(32);

      await expect(
        sidecar[
          "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)"
        ](
          from,
          payee.address,
          0n,
          0n,
          validBefore,
          nonce,
          "0x1234"
        )
      ).to.be.revertedWithCustomError(sidecar, "InvalidSignature");
      expect(await sidecar.authorizationState(from, nonce)).to.equal(false);
    }
  });

  it("accepts a valid ERC-1271 magic value without copying oversized return data", async () => {
    const { payee, frankencoin, sidecar } = await loadFixture(deployV2);
    const wallet = await ethers.deployContract("TestOversizedReturnWallet");
    const from = await wallet.getAddress();
    const value = ethers.parseEther("2");
    const nonce = ethers.randomBytes(32);
    const validBefore = BigInt((await time.latest()) + 3600);
    await frankencoin.mint(from, value);

    await expect(
      sidecar[
        "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)"
      ](
        from,
        payee.address,
        value,
        0n,
        validBefore,
        nonce,
        "0x1234",
        { gasLimit: 3_500_000 }
      )
    ).to.changeTokenBalances(frankencoin, [from, payee.address], [-value, value]);
  });

  it("routes a delegated EOA through ERC-1271 while keeping classic v,r,s on ECDSA", async () => {
    const { payer, payee, relayer, sidecar } = await loadFixture(deployV2);
    const value = ethers.parseEther("4");
    const auth = await signTransfer(
      payer,
      await sidecar.getAddress(),
      payee.address,
      value
    );

    const rejecting = await ethers.deployContract("TestRejectingWallet");
    const authorization = await payer.authorize({
      address: await rejecting.getAddress(),
    });
    await (
      await relayer.sendTransaction({
        to: relayer.address,
        authorizationList: [authorization],
      })
    ).wait();

    expect(await ethers.provider.getCode(payer.address)).to.equal(
      ethers.concat(["0xef0100", await rejecting.getAddress()])
    );

    await expect(
      sidecar[
        "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)"
      ](
        payer.address,
        payee.address,
        value,
        auth.validAfter,
        auth.validBefore,
        auth.nonce,
        auth.packed
      )
    ).to.be.revertedWithCustomError(sidecar, "InvalidSignature");

    expect(await sidecar.authorizationState(payer.address, auth.nonce)).to.equal(
      false
    );

    await sidecar[
      "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)"
    ](
      payer.address,
      payee.address,
      value,
      auth.validAfter,
      auth.validBefore,
      auth.nonce,
      auth.parsed.v,
      auth.parsed.r,
      auth.parsed.s
    );
    expect(await sidecar.authorizationState(payer.address, auth.nonce)).to.equal(
      true
    );
  });

  it("does not let an always-valid 1271 wallet spend another account", async () => {
    const { payer, payee, frankencoin, sidecar } = await loadFixture(deployV2);
    const evil = await ethers.deployContract("TestAlwaysValidWallet");
    const value = ethers.parseEther("1");
    const nonce = ethers.randomBytes(32);
    const validAfter = 0n;
    const validBefore = BigInt((await time.latest()) + 3600);
    await expect(
      sidecar[
        "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)"
      ](
        payer.address,
        payee.address,
        value,
        validAfter,
        validBefore,
        nonce,
        "0x1234"
      )
    ).to.be.revertedWithCustomError(sidecar, "InvalidSignature");

    // A wallet whose own ERC-1271 policy accepts everything can only ever authorize its own
    // balance, so this stops at the token's balance check rather than at signature validation.
    await expect(
      sidecar[
        "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)"
      ](
        await evil.getAddress(),
        payee.address,
        value,
        validAfter,
        validBefore,
        nonce,
        "0x1234"
      )
    )
      .to.be.revertedWithCustomError(frankencoin, "ERC20InsufficientBalance")
      .withArgs(await evil.getAddress(), 0n, value);
  });

  it("rejects zero-address malformed signatures for transfer, receive, and cancel on both paths", async () => {
    const { payee, sidecar } = await loadFixture(deployV2);
    const nonce = ethers.randomBytes(32);
    const validBefore = BigInt((await time.latest()) + 3600);
    const zeroWord = ethers.ZeroHash;
    const malformed = "0x" + "00".repeat(65);

    await expect(
      sidecar[
        "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)"
      ](
        ethers.ZeroAddress,
        payee.address,
        0n,
        0n,
        validBefore,
        nonce,
        27,
        zeroWord,
        zeroWord
      )
    ).to.be.revertedWithCustomError(sidecar, "InvalidSignature");
    await expect(
      sidecar[
        "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)"
      ](
        ethers.ZeroAddress,
        payee.address,
        0n,
        0n,
        validBefore,
        nonce,
        malformed
      )
    ).to.be.revertedWithCustomError(sidecar, "InvalidSignature");

    await expect(
      sidecar
        .connect(payee)
        [
          "receiveWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)"
        ](
          ethers.ZeroAddress,
          payee.address,
          0n,
          0n,
          validBefore,
          nonce,
          27,
          zeroWord,
          zeroWord
        )
    ).to.be.revertedWithCustomError(sidecar, "InvalidSignature");
    await expect(
      sidecar
        .connect(payee)
        [
          "receiveWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)"
        ](
          ethers.ZeroAddress,
          payee.address,
          0n,
          0n,
          validBefore,
          nonce,
          malformed
        )
    ).to.be.revertedWithCustomError(sidecar, "InvalidSignature");

    await expect(
      sidecar["cancelAuthorization(address,bytes32,uint8,bytes32,bytes32)"](
        ethers.ZeroAddress,
        nonce,
        27,
        zeroWord,
        zeroWord
      )
    ).to.be.revertedWithCustomError(sidecar, "InvalidSignature");
    await expect(
      sidecar["cancelAuthorization(address,bytes32,bytes)"](
        ethers.ZeroAddress,
        nonce,
        malformed
      )
    ).to.be.revertedWithCustomError(sidecar, "InvalidSignature");

    expect(
      await sidecar.authorizationState(ethers.ZeroAddress, nonce)
    ).to.equal(false);
  });

  it("rejects malleable high-s signatures for transfer, receive, and cancel on both paths", async () => {
    const { payer, payee, sidecar } = await loadFixture(deployV2);
    const value = ethers.parseEther("1");
    const auth = await signTransfer(
      payer,
      await sidecar.getAddress(),
      payee.address,
      value
    );
    const flipped = malleate(auth.signature);

    await expect(
      sidecar[
        "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)"
      ](
        payer.address,
        payee.address,
        value,
        auth.validAfter,
        auth.validBefore,
        auth.nonce,
        flipped.v,
        flipped.r,
        flipped.s
      )
    ).to.be.revertedWithCustomError(sidecar, "InvalidSignature");

    await expect(
      sidecar[
        "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)"
      ](
        payer.address,
        payee.address,
        value,
        auth.validAfter,
        auth.validBefore,
        auth.nonce,
        ethers.concat([flipped.r, flipped.s, ethers.toBeHex(flipped.v, 1)])
      )
    ).to.be.revertedWithCustomError(sidecar, "InvalidSignature");

    expect(await sidecar.authorizationState(payer.address, auth.nonce)).to.equal(
      false
    );

    const receiveNonce = ethers.randomBytes(32);
    const receiveSignature = await payer.signTypedData(
      await domainFor(await sidecar.getAddress()),
      receiveTypes,
      {
        from: payer.address,
        to: payee.address,
        value,
        validAfter: 0n,
        validBefore: auth.validBefore,
        nonce: receiveNonce,
      }
    );
    const flippedReceive = malleate(receiveSignature);
    await expect(
      sidecar
        .connect(payee)
        [
          "receiveWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)"
        ](
          payer.address,
          payee.address,
          value,
          0n,
          auth.validBefore,
          receiveNonce,
          flippedReceive.v,
          flippedReceive.r,
          flippedReceive.s
        )
    ).to.be.revertedWithCustomError(sidecar, "InvalidSignature");
    await expect(
      sidecar
        .connect(payee)
        [
          "receiveWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)"
        ](
          payer.address,
          payee.address,
          value,
          0n,
          auth.validBefore,
          receiveNonce,
          ethers.concat([
            flippedReceive.r,
            flippedReceive.s,
            ethers.toBeHex(flippedReceive.v, 1),
          ])
        )
    ).to.be.revertedWithCustomError(sidecar, "InvalidSignature");
    expect(
      await sidecar.authorizationState(payer.address, receiveNonce)
    ).to.equal(false);

    const cancelNonce = ethers.randomBytes(32);
    const cancelSignature = await payer.signTypedData(
      await domainFor(await sidecar.getAddress()),
      cancelTypes,
      { authorizer: payer.address, nonce: cancelNonce }
    );
    const flippedCancel = malleate(cancelSignature);
    await expect(
      sidecar["cancelAuthorization(address,bytes32,uint8,bytes32,bytes32)"](
        payer.address,
        cancelNonce,
        flippedCancel.v,
        flippedCancel.r,
        flippedCancel.s
      )
    ).to.be.revertedWithCustomError(sidecar, "InvalidSignature");
    await expect(
      sidecar["cancelAuthorization(address,bytes32,bytes)"](
        payer.address,
        cancelNonce,
        ethers.concat([
          flippedCancel.r,
          flippedCancel.s,
          ethers.toBeHex(flippedCancel.v, 1),
        ])
      )
    ).to.be.revertedWithCustomError(sidecar, "InvalidSignature");
    expect(
      await sidecar.authorizationState(payer.address, cancelNonce)
    ).to.equal(false);
  });

  it("rejects malformed encodings and v outside {27, 28} for every authorization operation", async () => {
    const { payer, payee, sidecar } = await loadFixture(deployV2);
    const value = ethers.parseEther("1");
    const auth = await signTransfer(
      payer,
      await sidecar.getAddress(),
      payee.address,
      value
    );
    const legacyV = auth.parsed.v - 27; // 0 or 1, as some libraries still emit

    await expect(
      sidecar[
        "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)"
      ](
        payer.address,
        payee.address,
        value,
        auth.validAfter,
        auth.validBefore,
        auth.nonce,
        legacyV,
        auth.parsed.r,
        auth.parsed.s
      )
    ).to.be.revertedWithCustomError(sidecar, "InvalidSignature");

    await expect(
      sidecar[
        "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)"
      ](
        payer.address,
        payee.address,
        value,
        auth.validAfter,
        auth.validBefore,
        auth.nonce,
        ethers.concat([
          auth.parsed.r,
          auth.parsed.s,
          ethers.toBeHex(legacyV, 1),
        ])
      )
    ).to.be.revertedWithCustomError(sidecar, "InvalidSignature");

    for (const length of [0, 64, 66]) {
      const malformedNonce = ethers.randomBytes(32);
      await expect(
        sidecar[
          "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)"
        ](
          payer.address,
          payee.address,
          value,
          auth.validAfter,
          auth.validBefore,
          malformedNonce,
          ethers.hexlify(ethers.randomBytes(length))
        )
      ).to.be.revertedWithCustomError(sidecar, "InvalidSignature");
      expect(
        await sidecar.authorizationState(payer.address, malformedNonce)
      ).to.equal(false);
    }

    const receiveNonce = ethers.randomBytes(32);
    const receiveSignature = ethers.Signature.from(
      await payer.signTypedData(
        await domainFor(await sidecar.getAddress()),
        receiveTypes,
        {
          from: payer.address,
          to: payee.address,
          value,
          validAfter: 0n,
          validBefore: auth.validBefore,
          nonce: receiveNonce,
        }
      )
    );
    const receiveLegacyV = receiveSignature.v - 27;
    await expect(
      sidecar
        .connect(payee)
        [
          "receiveWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)"
        ](
          payer.address,
          payee.address,
          value,
          0n,
          auth.validBefore,
          receiveNonce,
          receiveLegacyV,
          receiveSignature.r,
          receiveSignature.s
        )
    ).to.be.revertedWithCustomError(sidecar, "InvalidSignature");
    await expect(
      sidecar
        .connect(payee)
        [
          "receiveWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)"
        ](
          payer.address,
          payee.address,
          value,
          0n,
          auth.validBefore,
          receiveNonce,
          ethers.concat([
            receiveSignature.r,
            receiveSignature.s,
            ethers.toBeHex(receiveLegacyV, 1),
          ])
        )
    ).to.be.revertedWithCustomError(sidecar, "InvalidSignature");
    expect(
      await sidecar.authorizationState(payer.address, receiveNonce)
    ).to.equal(false);

    const cancelNonce = ethers.randomBytes(32);
    const cancelSignature = ethers.Signature.from(
      await payer.signTypedData(
        await domainFor(await sidecar.getAddress()),
        cancelTypes,
        { authorizer: payer.address, nonce: cancelNonce }
      )
    );
    const cancelLegacyV = cancelSignature.v - 27;
    await expect(
      sidecar["cancelAuthorization(address,bytes32,uint8,bytes32,bytes32)"](
        payer.address,
        cancelNonce,
        cancelLegacyV,
        cancelSignature.r,
        cancelSignature.s
      )
    ).to.be.revertedWithCustomError(sidecar, "InvalidSignature");
    await expect(
      sidecar["cancelAuthorization(address,bytes32,bytes)"](
        payer.address,
        cancelNonce,
        ethers.concat([
          cancelSignature.r,
          cancelSignature.s,
          ethers.toBeHex(cancelLegacyV, 1),
        ])
      )
    ).to.be.revertedWithCustomError(sidecar, "InvalidSignature");
    expect(
      await sidecar.authorizationState(payer.address, cancelNonce)
    ).to.equal(false);
  });

  it("matches the off-chain EIP-712 domain separator", async () => {
    const { sidecar } = await loadFixture(deployV2);
    const domain = await domainFor(await sidecar.getAddress());
    expect(await sidecar.DOMAIN_SEPARATOR()).to.equal(
      ethers.TypedDataEncoder.hashDomain(domain)
    );
  });

  it("executes receiveWithAuthorization via the v,r,s overload", async () => {
    const { payer, payee, frankencoin, sidecar } = await loadFixture(deployV2);
    const value = ethers.parseEther("2");
    const nonce = ethers.randomBytes(32);
    const validBefore = BigInt((await time.latest()) + 3600);
    const signature = await payer.signTypedData(
      await domainFor(await sidecar.getAddress()),
      receiveTypes,
      {
        from: payer.address,
        to: payee.address,
        value,
        validAfter: 0n,
        validBefore,
        nonce,
      }
    );
    const parsed = ethers.Signature.from(signature);

    await expect(
      sidecar
        .connect(payer)
        [
          "receiveWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)"
        ](
          payer.address,
          payee.address,
          value,
          0n,
          validBefore,
          nonce,
          parsed.v,
          parsed.r,
          parsed.s
        )
    ).to.be.revertedWithCustomError(sidecar, "CallerMustBePayee");

    await expect(
      sidecar
        .connect(payee)
        [
          "receiveWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)"
        ](
          payer.address,
          payee.address,
          value,
          0n,
          validBefore,
          nonce,
          parsed.v,
          parsed.r,
          parsed.s
        )
    ).to.changeTokenBalances(frankencoin, [payer, payee], [-value, value]);
  });

  it("cancels via the classic v,r,s overload", async () => {
    const { payer, sidecar } = await loadFixture(deployV2);
    const nonce = ethers.randomBytes(32);
    const signature = await payer.signTypedData(
      await domainFor(await sidecar.getAddress()),
      cancelTypes,
      { authorizer: payer.address, nonce }
    );
    const parsed = ethers.Signature.from(signature);

    await expect(
      sidecar["cancelAuthorization(address,bytes32,uint8,bytes32,bytes32)"](
        payer.address,
        nonce,
        parsed.v,
        parsed.r,
        parsed.s
      )
    )
      .to.emit(sidecar, "AuthorizationCanceled")
      .withArgs(payer.address, ethers.hexlify(nonce));
    expect(await sidecar.authorizationState(payer.address, nonce)).to.equal(
      true
    );

    // Cancelling twice must not be possible, on either overload.
    await expect(
      sidecar["cancelAuthorization(address,bytes32,uint8,bytes32,bytes32)"](
        payer.address,
        nonce,
        parsed.v,
        parsed.r,
        parsed.s
      )
    ).to.be.revertedWithCustomError(sidecar, "AuthorizationAlreadyUsed");
    await expect(
      sidecar["cancelAuthorization(address,bytes32,bytes)"](
        payer.address,
        nonce,
        packedSignature(signature)
      )
    ).to.be.revertedWithCustomError(sidecar, "AuthorizationAlreadyUsed");
  });

  it("rejects a contract wallet on the classic v,r,s cancel overload", async () => {
    const { owner, sidecar } = await loadFixture(deployV2);
    const wallet = await ethers.deployContract("TestContractWallet", [
      owner.address,
    ]);
    const authorizer = await wallet.getAddress();
    const nonce = ethers.randomBytes(32);
    const signature = await owner.signTypedData(
      await domainFor(await sidecar.getAddress()),
      cancelTypes,
      { authorizer, nonce }
    );
    const parsed = ethers.Signature.from(signature);

    // ERC-1271 belongs to the ERC-7598 bytes overloads only.
    await expect(
      sidecar["cancelAuthorization(address,bytes32,uint8,bytes32,bytes32)"](
        authorizer,
        nonce,
        parsed.v,
        parsed.r,
        parsed.s
      )
    ).to.be.revertedWithCustomError(sidecar, "InvalidSignature");

    await sidecar["cancelAuthorization(address,bytes32,bytes)"](
      authorizer,
      nonce,
      packedSignature(signature)
    );
    expect(await sidecar.authorizationState(authorizer, nonce)).to.equal(true);
  });

  it("rejects a contract wallet on classic receive and honours it on the bytes overload", async () => {
    const { owner, payee, frankencoin, sidecar } = await loadFixture(deployV2);
    const wallet = await ethers.deployContract("TestContractWallet", [
      owner.address,
    ]);
    const from = await wallet.getAddress();
    await frankencoin.mint(from, ethers.parseEther("50"));

    const value = ethers.parseEther("6");
    const nonce = ethers.randomBytes(32);
    const validBefore = BigInt((await time.latest()) + 3600);
    const signature = await owner.signTypedData(
      await domainFor(await sidecar.getAddress()),
      receiveTypes,
      { from, to: payee.address, value, validAfter: 0n, validBefore, nonce }
    );
    const parsed = ethers.Signature.from(signature);

    await expect(
      sidecar
        .connect(payee)
        [
          "receiveWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)"
        ](
          from,
          payee.address,
          value,
          0n,
          validBefore,
          nonce,
          parsed.v,
          parsed.r,
          parsed.s
        )
    ).to.be.revertedWithCustomError(sidecar, "InvalidSignature");
    expect(await sidecar.authorizationState(from, nonce)).to.equal(false);

    await expect(
      sidecar
        .connect(payee)
        [
          "receiveWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)"
        ](
          from,
          payee.address,
          value,
          0n,
          validBefore,
          nonce,
          packedSignature(signature)
        )
    ).to.changeTokenBalances(frankencoin, [from, payee.address], [-value, value]);
  });

  it("rejects an authorization replayed across the two signature paths", async () => {
    const { payer, payee, sidecar } = await loadFixture(deployV2);
    const value = ethers.parseEther("1");

    const viaVrs = await signTransfer(
      payer,
      await sidecar.getAddress(),
      payee.address,
      value
    );
    await sidecar[
      "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)"
    ](
      payer.address,
      payee.address,
      value,
      viaVrs.validAfter,
      viaVrs.validBefore,
      viaVrs.nonce,
      viaVrs.parsed.v,
      viaVrs.parsed.r,
      viaVrs.parsed.s
    );
    await expect(
      sidecar[
        "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)"
      ](
        payer.address,
        payee.address,
        value,
        viaVrs.validAfter,
        viaVrs.validBefore,
        viaVrs.nonce,
        viaVrs.packed
      )
    ).to.be.revertedWithCustomError(sidecar, "AuthorizationAlreadyUsed");

    const viaBytes = await signTransfer(
      payer,
      await sidecar.getAddress(),
      payee.address,
      value
    );
    await sidecar[
      "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)"
    ](
      payer.address,
      payee.address,
      value,
      viaBytes.validAfter,
      viaBytes.validBefore,
      viaBytes.nonce,
      viaBytes.packed
    );
    await expect(
      sidecar[
        "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)"
      ](
        payer.address,
        payee.address,
        value,
        viaBytes.validAfter,
        viaBytes.validBefore,
        viaBytes.nonce,
        viaBytes.parsed.v,
        viaBytes.parsed.r,
        viaBytes.parsed.s
      )
    ).to.be.revertedWithCustomError(sidecar, "AuthorizationAlreadyUsed");
  });

  it("rejects initialize from a non-deployer and a second initialize", async () => {
    const [owner] = await ethers.getSigners();
    const frankencoin = await ethers.deployContract("Frankencoin", [0]);
    await frankencoin.initialize(owner.address, "");
    const sidecar = await ethers.deployContract("TransferWithAuthorizationV2");
    await expect(
      sidecar.initialize(await frankencoin.getAddress())
    ).to.be.revertedWithCustomError(sidecar, "CallerMustBeDeployer");

    const initializer = await impersonateInitializer();
    await sidecar.connect(initializer).initialize(await frankencoin.getAddress());
    await expect(
      sidecar.connect(initializer).initialize(await frankencoin.getAddress())
    ).to.be.revertedWithCustomError(sidecar, "AlreadyInitialized");
  });
});
