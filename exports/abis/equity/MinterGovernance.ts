export const MinterGovernanceABI = [
  {
    inputs: [
      {
        internalType: "contract IFrankencoin",
        name: "zchf_",
        type: "address",
      },
      {
        internalType: "contract IGovernance",
        name: "fps1Gov",
        type: "address",
      },
      {
        internalType: "contract IGovernance",
        name: "fcsGov",
        type: "address",
      },
      {
        internalType: "address",
        name: "delegate",
        type: "address",
      },
      {
        internalType: "address",
        name: "helper",
        type: "address",
      },
    ],
    stateMutability: "nonpayable",
    type: "constructor",
  },
  {
    inputs: [],
    name: "FeeTooLow",
    type: "error",
  },
  {
    inputs: [],
    name: "MinterCorrectlyAnnounced",
    type: "error",
  },
  {
    inputs: [],
    name: "PeriodTooShort",
    type: "error",
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: true,
        internalType: "address",
        name: "who",
        type: "address",
      },
      {
        indexed: true,
        internalType: "address",
        name: "minter",
        type: "address",
      },
      {
        indexed: false,
        internalType: "uint256",
        name: "timestamp",
        type: "uint256",
      },
    ],
    name: "MinterAnnounced",
    type: "event",
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: true,
        internalType: "address",
        name: "caller",
        type: "address",
      },
      {
        indexed: false,
        internalType: "uint256",
        name: "amount",
        type: "uint256",
      },
      {
        indexed: false,
        internalType: "address",
        name: "token",
        type: "address",
      },
    ],
    name: "Rewarded",
    type: "event",
  },
  {
    inputs: [],
    name: "GOVERNANCE",
    outputs: [
      {
        internalType: "contract IGovernance",
        name: "",
        type: "address",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "MIN_APPLICATION_FEE",
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
    inputs: [],
    name: "MIN_APPLICATION_PERIOD",
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
    inputs: [],
    name: "ZCHF",
    outputs: [
      {
        internalType: "contract IFrankencoin",
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
        name: "minter",
        type: "address",
      },
    ],
    name: "announcements",
    outputs: [
      {
        internalType: "uint256",
        name: "timestamp",
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
        name: "minter",
        type: "address",
      },
    ],
    name: "checkReward",
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
        name: "minter",
        type: "address",
      },
      {
        internalType: "address[]",
        name: "helpers",
        type: "address[]",
      },
      {
        internalType: "string",
        name: "message",
        type: "string",
      },
    ],
    name: "denyMinter",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "address",
        name: "position",
        type: "address",
      },
      {
        internalType: "address[]",
        name: "helpers",
        type: "address[]",
      },
      {
        internalType: "string",
        name: "message",
        type: "string",
      },
    ],
    name: "denyPosition",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "address",
        name: "minter",
        type: "address",
      },
    ],
    name: "denyUnannouncedMinter",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [],
    name: "rewardPool",
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
        name: "_minter",
        type: "address",
      },
      {
        internalType: "uint256",
        name: "_applicationPeriod",
        type: "uint256",
      },
      {
        internalType: "uint256",
        name: "_applicationFee",
        type: "uint256",
      },
      {
        internalType: "string",
        name: "_message",
        type: "string",
      },
    ],
    name: "suggestMinter",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
] as const;
