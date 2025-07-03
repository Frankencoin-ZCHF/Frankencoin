export const GovernanceSenderABI = [
  {
    inputs: [
      {
        internalType: "contract Governance",
        name: "_governance",
        type: "address",
      },
      {
        internalType: "contract IRouterClient",
        name: "_router",
        type: "address",
      },
      {
        internalType: "address",
        name: "_linkToken",
        type: "address",
      },
    ],
    stateMutability: "nonpayable",
    type: "constructor",
  },
  {
    inputs: [
      {
        internalType: "address",
        name: "token",
        type: "address",
      },
      {
        internalType: "uint256",
        name: "fee",
        type: "uint256",
      },
    ],
    name: "InsufficientFeeTokenAllowance",
    type: "error",
  },
  {
    inputs: [
      {
        internalType: "address",
        name: "token",
        type: "address",
      },
      {
        internalType: "uint256",
        name: "fee",
        type: "uint256",
      },
    ],
    name: "InsufficientFeeTokens",
    type: "error",
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: true,
        internalType: "uint64",
        name: "chain",
        type: "uint64",
      },
      {
        indexed: false,
        internalType: "bytes",
        name: "receiver",
        type: "bytes",
      },
      {
        indexed: false,
        internalType: "address[]",
        name: "syncedVoters",
        type: "address[]",
      },
    ],
    name: "VotesSynced",
    type: "event",
  },
  {
    inputs: [],
    name: "GOVERNANCE",
    outputs: [
      {
        internalType: "contract Governance",
        name: "",
        type: "address",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "LINK",
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
    name: "ROUTER",
    outputs: [
      {
        internalType: "contract IRouterClient",
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
        internalType: "uint64",
        name: "chain",
        type: "uint64",
      },
      {
        internalType: "bytes",
        name: "receiver",
        type: "bytes",
      },
      {
        internalType: "address[]",
        name: "voters",
        type: "address[]",
      },
      {
        internalType: "bool",
        name: "nativeToken",
        type: "bool",
      },
      {
        internalType: "bytes",
        name: "extraArgs",
        type: "bytes",
      },
    ],
    name: "getCCIPFee",
    outputs: [
      {
        internalType: "uint256",
        name: "",
        type: "uint256",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "uint64",
        name: "chain",
        type: "uint64",
      },
      {
        internalType: "address",
        name: "receiver",
        type: "address",
      },
      {
        internalType: "address[]",
        name: "voters",
        type: "address[]",
      },
      {
        internalType: "bool",
        name: "useNativeToken",
        type: "bool",
      },
      {
        components: [
          {
            internalType: "uint256",
            name: "gasLimit",
            type: "uint256",
          },
          {
            internalType: "bool",
            name: "allowOutOfOrderExecution",
            type: "bool",
          },
        ],
        internalType: "struct Client.EVMExtraArgsV2",
        name: "extraArgs",
        type: "tuple",
      },
    ],
    name: "getCCIPFee",
    outputs: [
      {
        internalType: "uint256",
        name: "",
        type: "uint256",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "uint64",
        name: "chain",
        type: "uint64",
      },
      {
        internalType: "address",
        name: "receiver",
        type: "address",
      },
      {
        internalType: "address[]",
        name: "voters",
        type: "address[]",
      },
      {
        internalType: "bool",
        name: "useNativeToken",
        type: "bool",
      },
    ],
    name: "getCCIPFee",
    outputs: [
      {
        internalType: "uint256",
        name: "",
        type: "uint256",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "uint64",
        name: "chain",
        type: "uint64",
      },
      {
        internalType: "address",
        name: "receiver",
        type: "address",
      },
      {
        internalType: "address[]",
        name: "voters",
        type: "address[]",
      },
    ],
    name: "pushVotes",
    outputs: [],
    stateMutability: "payable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "uint64",
        name: "chain",
        type: "uint64",
      },
      {
        internalType: "address",
        name: "receiver",
        type: "address",
      },
      {
        internalType: "address[]",
        name: "voters",
        type: "address[]",
      },
      {
        components: [
          {
            internalType: "uint256",
            name: "gasLimit",
            type: "uint256",
          },
          {
            internalType: "bool",
            name: "allowOutOfOrderExecution",
            type: "bool",
          },
        ],
        internalType: "struct Client.EVMExtraArgsV2",
        name: "extraArgs",
        type: "tuple",
      },
    ],
    name: "pushVotes",
    outputs: [],
    stateMutability: "payable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "uint64",
        name: "chain",
        type: "uint64",
      },
      {
        internalType: "bytes",
        name: "receiver",
        type: "bytes",
      },
      {
        internalType: "address[]",
        name: "voters",
        type: "address[]",
      },
      {
        internalType: "bytes",
        name: "extraArgs",
        type: "bytes",
      },
    ],
    name: "pushVotes",
    outputs: [],
    stateMutability: "payable",
    type: "function",
  },
] as const;
