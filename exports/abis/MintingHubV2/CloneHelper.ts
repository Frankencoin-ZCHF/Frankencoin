export const CloneHelperABI = [
  {
    inputs: [
      {
        internalType: "address",
        name: "hub_",
        type: "address",
      },
    ],
    stateMutability: "nonpayable",
    type: "constructor",
  },
  {
    inputs: [],
    name: "HUB",
    outputs: [
      {
        internalType: "contract MintingHubV2",
        name: "",
        type: "address",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "address",
        name: "parent",
        type: "address",
      },
      {
        internalType: "uint256",
        name: "initialCollateral",
        type: "uint256",
      },
      {
        internalType: "uint256",
        name: "initialMint",
        type: "uint256",
      },
      {
        internalType: "uint40",
        name: "expiration",
        type: "uint40",
      },
      {
        internalType: "uint256",
        name: "newPrice",
        type: "uint256",
      },
    ],
    name: "cloneWithPrice",
    outputs: [
      {
        internalType: "address",
        name: "",
        type: "address",
      },
    ],
    stateMutability: "nonpayable",
    type: "function",
  },
] as const;
