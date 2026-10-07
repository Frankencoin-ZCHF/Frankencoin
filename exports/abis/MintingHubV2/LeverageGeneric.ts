export const LeverageGenericABI = [
  {
    inputs: [{ internalType: "address", name: "router", type: "address" }],
    stateMutability: "nonpayable",
    type: "constructor",
  },
  {
    inputs: [
      { internalType: "uint256", name: "got", type: "uint256" },
      { internalType: "uint256", name: "required", type: "uint256" },
    ],
    name: "InsufficientSwapOutput",
    type: "error",
  },
  { inputs: [], name: "InvalidAmount", type: "error" },
  { inputs: [], name: "InvalidExpiration", type: "error" },
  { inputs: [], name: "NotMorpho", type: "error" },
  {
    inputs: [{ internalType: "address", name: "token", type: "address" }],
    name: "SafeERC20FailedOperation",
    type: "error",
  },
  {
    inputs: [{ internalType: "bytes", name: "reason", type: "bytes" }],
    name: "SwapFailed",
    type: "error",
  },
  {
    inputs: [],
    name: "HUB",
    outputs: [
      {
        internalType: "contract IMintingHubGeneric",
        name: "",
        type: "address",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "MORPHO",
    outputs: [
      { internalType: "contract IMorphoFlashloan", name: "", type: "address" },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "ROUTER",
    outputs: [{ internalType: "address", name: "", type: "address" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "ZCHF",
    outputs: [{ internalType: "contract IERC20", name: "", type: "address" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [
      { internalType: "address", name: "source", type: "address" },
      { internalType: "uint256", name: "equityAmount", type: "uint256" },
      { internalType: "uint256", name: "collateralAmount", type: "uint256" },
      { internalType: "uint40", name: "expiration", type: "uint40" },
      { internalType: "bytes", name: "swapData", type: "bytes" },
    ],
    name: "executeWithCollateral",
    outputs: [
      { internalType: "address", name: "leveragedPosition", type: "address" },
    ],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      { internalType: "address", name: "source", type: "address" },
      { internalType: "uint256", name: "equityAmount", type: "uint256" },
      { internalType: "uint256", name: "collateralAmount", type: "uint256" },
      { internalType: "uint40", name: "expiration", type: "uint40" },
      { internalType: "bytes", name: "swapData", type: "bytes" },
    ],
    name: "executeWithZCHF",
    outputs: [
      { internalType: "address", name: "leveragedPosition", type: "address" },
    ],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      { internalType: "uint256", name: "assets", type: "uint256" },
      { internalType: "bytes", name: "data", type: "bytes" },
    ],
    name: "onMorphoFlashLoan",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      { internalType: "address", name: "source", type: "address" },
      { internalType: "uint40", name: "expiration", type: "uint40" },
      { internalType: "uint256", name: "collateralAmount", type: "uint256" },
    ],
    name: "preview",
    outputs: [
      {
        components: [
          { internalType: "uint256", name: "mintGross", type: "uint256" },
          { internalType: "uint256", name: "reserveAmount", type: "uint256" },
          { internalType: "uint256", name: "feeAmount", type: "uint256" },
          { internalType: "uint256", name: "mintNet", type: "uint256" },
        ],
        internalType: "struct LeverageGeneric.Preview",
        name: "p",
        type: "tuple",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
] as const;
