export const MainnetVotesABI = [
  {
    inputs: [
      {
        internalType: "address",
        name: "fcs_",
        type: "address",
      },
      {
        internalType: "contract IRouterClient",
        name: "router_",
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
    inputs: [],
    name: "NotQualified",
    type: "error",
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: true,
        internalType: "address",
        name: "from",
        type: "address",
      },
      {
        indexed: true,
        internalType: "address",
        name: "to",
        type: "address",
      },
    ],
    name: "Delegation",
    type: "event",
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: false,
        internalType: "uint64",
        name: "chain",
        type: "uint64",
      },
      {
        indexed: true,
        internalType: "address",
        name: "receiver",
        type: "address",
      },
      {
        indexed: false,
        internalType: "address[]",
        name: "syncedVoters",
        type: "address[]",
      },
    ],
    name: "FCSVotesSynced",
    type: "event",
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
    inputs: [],
    name: "VOTES",
    outputs: [
      {
        internalType: "contract IFCSVotes",
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
  {
    inputs: [
      {
        internalType: "address",
        name: "delegate_",
        type: "address",
      },
    ],
    name: "delegateVoteTo",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "address",
        name: "owner",
        type: "address",
      },
    ],
    name: "delegates",
    outputs: [
      {
        internalType: "address",
        name: "delegate",
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
    name: "getFCSSyncFee",
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
    name: "getFCSSyncFee",
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
    name: "pushFCSVotes",
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
    name: "pushFCSVotes",
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
    ],
    name: "pushFCSVotes",
    outputs: [],
    stateMutability: "payable",
    type: "function",
  },
  {
    inputs: [],
    name: "totalVotes",
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
        internalType: "address",
        name: "holder",
        type: "address",
      },
    ],
    name: "votes",
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
    name: "votesDelegated",
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
] as const;
