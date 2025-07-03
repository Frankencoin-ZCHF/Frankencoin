export const IGovernanceABI = [
  {
    inputs: [
      {
        internalType: "address",
        name: "sender",
        type: "address",
      },
      {
        internalType: "address[]",
        name: "helpers",
        type: "address[]",
      },
    ],
    name: "checkQualified",
    outputs: [],
    stateMutability: "view",
    type: "function",
  },
] as const;
