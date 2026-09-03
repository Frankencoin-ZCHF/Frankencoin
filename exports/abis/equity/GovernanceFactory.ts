export const GovernanceFactoryABI = [
  {
    inputs: [],
    name: "InnerFactoryDeploymentFailed",
    type: "error",
  },
  {
    inputs: [],
    name: "ARACHNID_DEPLOYER",
    outputs: [
      {
        internalType: "address",
        name: "",
        type: "address",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "INNER_SALT",
    outputs: [
      {
        internalType: "bytes32",
        name: "",
        type: "bytes32",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "address",
        name: "fcsmainnet",
        type: "address",
      },
    ],
    name: "deploy",
    outputs: [
      {
        internalType: "address",
        name: "helper",
        type: "address",
      },
    ],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [],
    name: "innerFactoryAddress",
    outputs: [
      {
        internalType: "address",
        name: "",
        type: "address",
      },
    ],
    stateMutability: "pure",
    type: "function",
  },
] as const;
