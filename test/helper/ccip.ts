import { ethers } from "hardhat";
import {
  LinkToken,
} from "../../typechain/@chainlink/local/src/shared/LinkToken";

export async function getLinkTokenContract(
  address: string
): Promise<LinkToken> {
  const linkTokenFactory = await ethers.getContractFactory("LinkToken");
  return linkTokenFactory.attach(address) as LinkToken;
}
