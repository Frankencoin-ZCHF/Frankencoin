export function getRpc(network: string, key: string): string {
  switch (network) {
    case "amoy":
      return `https://polygon-amoy.g.alchemy.com/v2/${key}`;
    case "sepolia":
      return `https://eth-sepolia.g.alchemy.com/v2/${key}`;
    default:
      throw new Error(`RPC for ${network} not found`);
  }
}
