export const IInterestSourceABI = [
  {
    inputs: [
      {
        internalType: "address",
        name: "source",
        type: "address",
      },
      {
        internalType: "uint256",
        name: "amount",
        type: "uint256",
      },
    ],
    name: "coverLoss",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
] as const;
