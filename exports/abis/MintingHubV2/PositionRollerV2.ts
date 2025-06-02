export const PositionRollerV2ABI = [
  {
    inputs: [
      {
        internalType: "address",
        name: "zchf_",
        type: "address",
      },
    ],
    stateMutability: "nonpayable",
    type: "constructor",
  },
  {
    inputs: [
      {
        internalType: "uint256",
        name: "",
        type: "uint256",
      },
      {
        internalType: "uint256",
        name: "",
        type: "uint256",
      },
      {
        internalType: "uint256",
        name: "",
        type: "uint256",
      },
    ],
    name: "Log",
    type: "error",
  },
  {
    inputs: [
      {
        internalType: "address",
        name: "pos",
        type: "address",
      },
    ],
    name: "NotOwner",
    type: "error",
  },
  {
    inputs: [
      {
        internalType: "address",
        name: "pos",
        type: "address",
      },
    ],
    name: "NotPosition",
    type: "error",
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: false,
        internalType: "address",
        name: "source",
        type: "address",
      },
      {
        indexed: false,
        internalType: "uint256",
        name: "collWithdraw",
        type: "uint256",
      },
      {
        indexed: false,
        internalType: "uint256",
        name: "repay",
        type: "uint256",
      },
      {
        indexed: false,
        internalType: "address",
        name: "target",
        type: "address",
      },
      {
        indexed: false,
        internalType: "uint256",
        name: "collDeposit",
        type: "uint256",
      },
      {
        indexed: false,
        internalType: "uint256",
        name: "mint",
        type: "uint256",
      },
    ],
    name: "Roll",
    type: "event",
  },
  {
    inputs: [
      {
        internalType: "contract IPosition",
        name: "pos",
        type: "address",
      },
    ],
    name: "findRepaymentAmount",
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
        internalType: "contract IPosition",
        name: "source",
        type: "address",
      },
      {
        internalType: "uint256",
        name: "repay",
        type: "uint256",
      },
      {
        internalType: "uint256",
        name: "collWithdraw",
        type: "uint256",
      },
      {
        internalType: "contract IPosition",
        name: "target",
        type: "address",
      },
      {
        internalType: "uint256",
        name: "mint",
        type: "uint256",
      },
      {
        internalType: "uint256",
        name: "collDeposit",
        type: "uint256",
      },
      {
        internalType: "uint40",
        name: "expiration",
        type: "uint40",
      },
    ],
    name: "roll",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "contract IPosition",
        name: "source",
        type: "address",
      },
      {
        internalType: "contract IPosition",
        name: "target",
        type: "address",
      },
    ],
    name: "rollFully",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "contract IPosition",
        name: "source",
        type: "address",
      },
      {
        internalType: "contract IPosition",
        name: "target",
        type: "address",
      },
      {
        internalType: "uint40",
        name: "expiration",
        type: "uint40",
      },
    ],
    name: "rollFullyWithExpiration",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
] as const;
