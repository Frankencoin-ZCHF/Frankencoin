import { ethers, network } from "hardhat";
import { expect } from "chai";
import { runCollateralChecks } from "./helper/collateralChecks";

/**
 * wXAUH, wrapper token for Swiss gold (Herculis Gold Coin, XAUH).
 * https://etherscan.io/token/0xC174B12B3195D9887e8dA7aA886EC11c13101060
 *
 * The wrapper has no holders at the fork block, so funding wraps the underlying XAUH,
 * which is taken from a holder via impersonation.
 */
const WXAUH = "0xC174B12B3195D9887e8dA7aA886EC11c13101060";
const XAUH = "0xa9b17f572341219703Bc951725Bdb3CA756B1A65";
const XAUH_HOLDER = "0x03852ae3df6de29ea7b9e4077cd63a3e3e14832c"; // ~710 XAUH at the fork block

const WRAPPER_ABI = [
  "function wrap(uint256)",
  "function unwrap(uint256)",
  "function underlyingERC20() view returns (address)",
  "function paused() view returns (bool)",
  "function isWhitelistModeEnabled() view returns (bool)",
  "function isFrozen(address) view returns (bool)",
  "function owner() view returns (address)",
  "function pause()",
  "function freeze(address)",
  "function enableWhitelistMode()",
  "function setAssetProtectionRole(address)",
];
const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
  "function transfer(address,uint256) returns (bool)",
];

runCollateralChecks({
  name: "wXAUH (Swiss gold wrapper)",
  token: WXAUH,
  forkBlock: 26300157,
  maxFunding: 100n * 10n ** 18n,
  position: {
    minCollateral: 2n * 10n ** 18n,
    initialCollateral: 3n * 10n ** 18n + 17n,
    liqPrice: 3000n * 10n ** 18n, // 18 decimals collateral, 18 decimals price
  },
  fund: async (token, to, amount) => {
    // The underlying XAUH charges a ~0.02% fee on every transfer, so wrapping is lossy.
    // Wrap a surplus from a helper account, then send exactly `amount` of the (fee free) wrapper token.
    const missing = amount - (await token.balanceOf(to.address));
    if (missing <= 0n) return;
    const [, , , , funder] = await ethers.getSigners();
    await network.provider.send("hardhat_setBalance", [XAUH_HOLDER, "0x56BC75E2D63100000"]);
    const holder = await ethers.getImpersonatedSigner(XAUH_HOLDER);
    const gross = missing + missing / 100n + 1000n;
    await new ethers.Contract(XAUH, ERC20_ABI, holder).transfer(funder.address, gross);
    const received = await new ethers.Contract(XAUH, ERC20_ABI, funder).balanceOf(funder.address);
    await new ethers.Contract(XAUH, ERC20_ABI, funder).approve(WXAUH, received);
    await new ethers.Contract(WXAUH, WRAPPER_ABI, funder).wrap(received);
    await token.connect(funder).transfer(to.address, missing);
  },
});

describe("wXAUH specific checks", () => {
  it("wrapper is fully backed even though the underlying XAUH charges a transfer fee", async () => {
    // XAUH takes ~0.02% per transfer. The wrapper mints what it actually received, so supply == underlying held.
    // The fee only hits wrap/unwrap, never transfers of the wrapper token itself.
    const [, alice] = await ethers.getSigners();
    const holder = await ethers.getImpersonatedSigner(XAUH_HOLDER);
    await network.provider.send("hardhat_setBalance", [XAUH_HOLDER, "0x56BC75E2D63100000"]);
    const xauh = new ethers.Contract(XAUH, ERC20_ABI, holder);
    const w = new ethers.Contract(WXAUH, [...WRAPPER_ABI, ...ERC20_ABI], alice);
    await xauh.transfer(alice.address, 10n ** 18n);
    const xauhA = new ethers.Contract(XAUH, ERC20_ABI, alice);
    const bal = await xauhA.balanceOf(alice.address);
    await xauhA.approve(WXAUH, bal);
    await w.wrap(bal);
    const minted = await w.balanceOf(alice.address);
    expect(minted).to.be.lte(bal);
    expect(await w.totalSupply()).to.equal(minted);
    expect(await xauhA.balanceOf(WXAUH)).to.equal(minted); // 1:1 backed
    await w.unwrap(minted);
    expect(await w.balanceOf(alice.address)).to.equal(0n);
    expect(await w.totalSupply()).to.equal(0n);
  });

  it("is currently not paused and has whitelist mode disabled (transfers to the hub are possible)", async () => {
    const w = new ethers.Contract(WXAUH, WRAPPER_ABI, ethers.provider);
    expect(await w.paused()).to.equal(false);
    expect(await w.isWhitelistModeEnabled()).to.equal(false);
  });

  it("documents the admin risk: owner can pause, freeze and enable whitelist mode", async () => {
    // These are centralisation risks for a collateral, positions cannot move collateral while they are active.
    const w = new ethers.Contract(WXAUH, WRAPPER_ABI, ethers.provider);
    const admin = await ethers.getImpersonatedSigner(await w.owner());
    await network.provider.send("hardhat_setBalance", [admin.address, "0x56BC75E2D63100000"]);
    const [, alice] = await ethers.getSigners();
    await w.connect(admin).setAssetProtectionRole(admin.address);
    await w.connect(admin).freeze(alice.address);
    expect(await w.isFrozen(alice.address)).to.equal(true);
    await w.connect(admin).pause();
    expect(await w.paused()).to.equal(true);
  });
});
