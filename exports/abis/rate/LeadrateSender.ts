export const LeadrateSenderABI = [
  {
    inputs: [
      {
        internalType: "contract Leadrate",
        name: "leadrate",
        type: "address",
      },
      {
        internalType: "contract IRouterClient",
        name: "router",
        type: "address",
      },
      {
        internalType: "address",
        name: "linkToken",
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
    inputs: [
      {
        internalType: "uint256",
        name: "expected",
        type: "uint256",
      },
      {
        internalType: "uint256",
        name: "given",
        type: "uint256",
      },
    ],
    name: "LengthMismatch",
    type: "error",
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
        internalType: "bytes",
        name: "bridgedLeadrate",
        type: "bytes",
      },
      {
        indexed: false,
        internalType: "uint24",
        name: "newRatePPM",
        type: "uint24",
      },
    ],
    name: "Pushed",
    type: "event",
  },
  {
    inputs: [],
    name: "LEADRATE",
    outputs: [
      {
        internalType: "contract Leadrate",
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
        name: "target",
        type: "bytes",
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
        name: "target",
        type: "address",
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
        name: "target",
        type: "address",
      },
      {
        internalType: "bool",
        name: "nativeToken",
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
        internalType: "uint64[]",
        name: "chains",
        type: "uint64[]",
      },
      {
        internalType: "bytes[]",
        name: "targets",
        type: "bytes[]",
      },
    ],
    name: "pushLeadrate",
    outputs: [],
    stateMutability: "nonpayable",
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
        name: "target",
        type: "address",
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
    name: "pushLeadrate",
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
        name: "target",
        type: "address",
      },
    ],
    name: "pushLeadrate",
    outputs: [],
    stateMutability: "payable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "uint64[]",
        name: "chains",
        type: "uint64[]",
      },
      {
        internalType: "bytes[]",
        name: "targets",
        type: "bytes[]",
      },
      {
        internalType: "bytes[]",
        name: "extraArgs",
        type: "bytes[]",
      },
    ],
    name: "pushLeadrate",
    outputs: [],
    stateMutability: "nonpayable",
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
        name: "target",
        type: "bytes",
      },
      {
        internalType: "bytes",
        name: "extraArgs",
        type: "bytes",
      },
    ],
    name: "pushLeadrate",
    outputs: [],
    stateMutability: "payable",
    type: "function",
  },
] as const;
