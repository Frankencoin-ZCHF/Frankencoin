import { ethers, network } from "hardhat";
import { expect } from "chai";
import { runCollateralChecks } from "../helper/collateralChecks";

/**
 * eNear, the Rainbow Bridge ERC20 representation of NEAR (24 decimals, same as yoctoNEAR).
 * https://etherscan.io/token/0x85F17Cf997934a597031b2E18a9aB6ebD4B9f6a4
 *
 * Plain OpenZeppelin 3.x ERC20 (solc 0.6.12) plus a bridge. Not upgradeable, no transfer fee,
 * no blacklist. The admin (AdminControlled) pauses the bridge in/out, never ERC20 transfers, but can also
 * write arbitrary storage and delegatecall (adminSstore, adminDelegatecall).
 * Funding impersonates a holder, minting requires a NEAR light client proof.
 */
const ENEAR = "0x85F17Cf997934a597031b2E18a9aB6ebD4B9f6a4";
const HOLDER = "0xee8aaa362a75fbf8e0a38a50ddc27f38551e16ea"; // Uniswap V3 NEAR/USDC 0.3% pool, ~141k eNear at the fork block (impersonated as funder)

const ENEAR_ABI = [
  "function admin() view returns (address)",
  "function paused() view returns (uint256)",
  "function adminPause(uint256)",
  "function adminSstore(uint256,uint256)",
  "event TransferToNearInitiated(address indexed sender, uint256 amount, string accountId)",
  "function transferToNear(uint256,string)",
  "function decimals() view returns (uint8)",
  "function totalSupply() view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
  "function transfer(address,uint256) returns (bool)",
];

const UNIT = 10n ** 24n;

runCollateralChecks({
  name: "eNear (NEAR bridged via Rainbow Bridge)",
  token: ENEAR,
  forkBlock: 26376900,
  maxFunding: 10_000n * UNIT,
  position: {
    // the hub requires minCollateral * price >= 5000 ZCHF, i.e. at least 2500 NEAR at this price
    minCollateral: 3000n * UNIT,
    initialCollateral: 3000n * UNIT + 17n,
    liqPrice: 2n * 10n ** 12n, // 24 decimals collateral -> 12 decimals price, i.e. 2 ZCHF per NEAR
  },
  fund: async (token, to, amount) => {
    const missing = amount - (await token.balanceOf(to.address));
    if (missing <= 0n) return;
    await network.provider.send("hardhat_setBalance", [HOLDER, "0x56BC75E2D63100000"]);
    const holder = await ethers.getImpersonatedSigner(HOLDER);
    await token.connect(holder).transfer(to.address, missing);
  },
});

describe("eNear specific checks", () => {
  it("has 24 decimals and is not upgradeable", async () => {
    const t = new ethers.Contract(ENEAR, ENEAR_ABI, ethers.provider);
    expect(await t.decimals()).to.equal(24);
    const implSlot = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
    expect(BigInt(await ethers.provider.getStorage(ENEAR, implSlot))).to.equal(0n);
  });

  it("has the bridge paused in both directions, which does not affect ERC20 transfers", async () => {
    // bit 0: finalise from NEAR (mint), bit 1: transfer to NEAR (burn). Plain transfers have no pause check.
    const [, alice, bob] = await ethers.getSigners();
    const t = new ethers.Contract(ENEAR, ENEAR_ABI, ethers.provider);
    expect(await t.paused()).to.equal(3n);

    await network.provider.send("hardhat_setBalance", [HOLDER, "0x56BC75E2D63100000"]);
    const holder = await ethers.getImpersonatedSigner(HOLDER);
    await t.connect(holder).transfer(alice.address, UNIT);
    await t.connect(alice).transfer(bob.address, UNIT / 2n);
    expect(await t.balanceOf(bob.address)).to.equal(UNIT / 2n);
  });

  it("exit to NEAR reverts while paused and works after the admin unlocks the bridge", async () => {
    const [, alice] = await ethers.getSigners();
    const t = new ethers.Contract(ENEAR, ENEAR_ABI, ethers.provider);
    expect(await t.paused()).to.equal(3n);

    await network.provider.send("hardhat_setBalance", [HOLDER, "0x56BC75E2D63100000"]);
    const holder = await ethers.getImpersonatedSigner(HOLDER);
    await t.connect(holder).transfer(alice.address, UNIT);
    const bal = await t.balanceOf(alice.address);
    await expect(t.connect(alice).transferToNear(bal, "alice.near")).to.be.reverted;

    const admin = await ethers.getImpersonatedSigner(await t.admin());
    await network.provider.send("hardhat_setBalance", [admin.address, "0x56BC75E2D63100000"]);
    await t.connect(admin).adminPause(0);
    expect(await t.paused()).to.equal(0n);

    const supply = await t.totalSupply();
    await expect(t.connect(alice).transferToNear(bal, "alice.near"))
      .to.emit(t, "TransferToNearInitiated")
      .withArgs(alice.address, bal, "alice.near");
    expect(await t.totalSupply()).to.equal(supply - bal);
    expect(await t.balanceOf(alice.address)).to.equal(0n);
  });

  it("documents the admin risk: admin can write any storage slot, i.e. mint or rewrite balances", async () => {
    // AdminControlled exposes adminSstore and adminDelegatecall, so the admin is not limited to pausing the bridge.
    // eNear is not upgradeable, but this gives the admin the same power as an upgrade key.
    const [, alice] = await ethers.getSigners();
    const t = new ethers.Contract(ENEAR, ENEAR_ABI, ethers.provider);
    const admin = await ethers.getImpersonatedSigner(await t.admin());
    await network.provider.send("hardhat_setBalance", [admin.address, "0x56BC75E2D63100000"]);

    const slot = BigInt(ethers.solidityPackedKeccak256(["uint256", "uint256"], [alice.address, 0])); // _balances is slot 0
    const before = await t.balanceOf(alice.address);
    await t.connect(admin).adminSstore(slot, 1_000_000n * UNIT);
    expect(await t.balanceOf(alice.address)).to.equal(1_000_000n * UNIT);
    expect(before).to.not.equal(await t.balanceOf(alice.address));
  });
});
