export const AmplifiedPositionABI = [
  {
    inputs: [
      {
        internalType: "contract UniswapAmplifier",
        name: "parent",
        type: "address",
      },
    ],
    stateMutability: "nonpayable",
    type: "constructor",
  },
  {
    inputs: [{ internalType: "address", name: "sender", type: "address" }],
    name: "AccessDenied",
    type: "error",
  },
  { inputs: [], name: "NotExpired", type: "error" },
  { inputs: [], name: "NotOwner", type: "error" },
  {
    anonymous: false,
    inputs: [
      {
        indexed: false,
        internalType: "uint128",
        name: "liquidityRemoved",
        type: "uint128",
      },
      {
        indexed: false,
        internalType: "uint256",
        name: "token0",
        type: "uint256",
      },
      {
        indexed: false,
        internalType: "uint256",
        name: "token1",
        type: "uint256",
      },
      {
        indexed: false,
        internalType: "uint256",
        name: "repaid",
        type: "uint256",
      },
    ],
    name: "Burn",
    type: "event",
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: false,
        internalType: "uint128",
        name: "liquidityAdded",
        type: "uint128",
      },
      {
        indexed: false,
        internalType: "uint256",
        name: "token0",
        type: "uint256",
      },
      {
        indexed: false,
        internalType: "uint256",
        name: "token1",
        type: "uint256",
      },
      {
        indexed: false,
        internalType: "uint256",
        name: "borrowed",
        type: "uint256",
      },
    ],
    name: "Mint",
    type: "event",
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: true,
        internalType: "address",
        name: "previousOwner",
        type: "address",
      },
      {
        indexed: true,
        internalType: "address",
        name: "newOwner",
        type: "address",
      },
    ],
    name: "OwnershipTransferred",
    type: "event",
  },
  {
    inputs: [],
    name: "borrowed",
    outputs: [{ internalType: "uint256", name: "", type: "uint256" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [
      { internalType: "uint128", name: "burnedLiquidity", type: "uint128" },
      { internalType: "uint256", name: "expectedPriceX96", type: "uint256" },
    ],
    name: "burn",
    outputs: [
      { internalType: "uint256", name: "", type: "uint256" },
      { internalType: "uint256", name: "", type: "uint256" },
    ],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      { internalType: "uint128", name: "burnedLiquidity", type: "uint128" },
      { internalType: "uint256", name: "expectedPriceX96", type: "uint256" },
    ],
    name: "expiredPublicBurn",
    outputs: [
      { internalType: "uint256", name: "", type: "uint256" },
      { internalType: "uint256", name: "", type: "uint256" },
    ],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      { internalType: "address", name: "owner_", type: "address" },
      { internalType: "int24", name: "tickLow_", type: "int24" },
      { internalType: "int24", name: "tickHigh_", type: "int24" },
    ],
    name: "initialize",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      { internalType: "uint128", name: "amount", type: "uint128" },
      { internalType: "uint256", name: "expectedPriceX96", type: "uint256" },
    ],
    name: "mint",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [],
    name: "owner",
    outputs: [{ internalType: "address", name: "", type: "address" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "tickHigh",
    outputs: [{ internalType: "int24", name: "", type: "int24" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "tickLow",
    outputs: [{ internalType: "int24", name: "", type: "int24" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "totalLiquidity",
    outputs: [{ internalType: "uint128", name: "liquidity", type: "uint128" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [{ internalType: "address", name: "newOwner", type: "address" }],
    name: "transferOwnership",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      { internalType: "uint256", name: "amount0Owed", type: "uint256" },
      { internalType: "uint256", name: "amount1Owed", type: "uint256" },
      { internalType: "bytes", name: "", type: "bytes" },
    ],
    name: "uniswapV3MintCallback",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
] as const;
