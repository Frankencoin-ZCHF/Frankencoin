export const ITokenPoolABI = [
  {
    inputs: [],
    name: "acceptOwnership",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "uint64",
        name: "remoteChainSelector",
        type: "uint64",
      },
      {
        internalType: "bytes",
        name: "remotePoolAddress",
        type: "bytes",
      },
    ],
    name: "addRemotePool",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "uint64[]",
        name: "remoteChainSelectorsToRemove",
        type: "uint64[]",
      },
      {
        components: [
          {
            internalType: "uint64",
            name: "remoteChainSelector",
            type: "uint64",
          },
          {
            internalType: "bytes[]",
            name: "remotePoolAddresses",
            type: "bytes[]",
          },
          {
            internalType: "bytes",
            name: "remoteTokenAddress",
            type: "bytes",
          },
          {
            components: [
              {
                internalType: "bool",
                name: "isEnabled",
                type: "bool",
              },
              {
                internalType: "uint128",
                name: "capacity",
                type: "uint128",
              },
              {
                internalType: "uint128",
                name: "rate",
                type: "uint128",
              },
            ],
            internalType: "struct RateLimiter.Config",
            name: "outboundRateLimiterConfig",
            type: "tuple",
          },
          {
            components: [
              {
                internalType: "bool",
                name: "isEnabled",
                type: "bool",
              },
              {
                internalType: "uint128",
                name: "capacity",
                type: "uint128",
              },
              {
                internalType: "uint128",
                name: "rate",
                type: "uint128",
              },
            ],
            internalType: "struct RateLimiter.Config",
            name: "inboundRateLimiterConfig",
            type: "tuple",
          },
        ],
        internalType: "struct ITokenPool.ChainUpdate[]",
        name: "chainsToAdd",
        type: "tuple[]",
      },
    ],
    name: "applyChainUpdates",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "uint64",
        name: "remoteChainSelector",
        type: "uint64",
      },
      {
        internalType: "bytes",
        name: "remotePoolAddress",
        type: "bytes",
      },
    ],
    name: "removeRemotePool",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "uint64",
        name: "remoteChainSelectors",
        type: "uint64",
      },
      {
        components: [
          {
            internalType: "bool",
            name: "isEnabled",
            type: "bool",
          },
          {
            internalType: "uint128",
            name: "capacity",
            type: "uint128",
          },
          {
            internalType: "uint128",
            name: "rate",
            type: "uint128",
          },
        ],
        internalType: "struct RateLimiter.Config",
        name: "outboundConfigs",
        type: "tuple",
      },
      {
        components: [
          {
            internalType: "bool",
            name: "isEnabled",
            type: "bool",
          },
          {
            internalType: "uint128",
            name: "capacity",
            type: "uint128",
          },
          {
            internalType: "uint128",
            name: "rate",
            type: "uint128",
          },
        ],
        internalType: "struct RateLimiter.Config",
        name: "inboundConfigs",
        type: "tuple",
      },
    ],
    name: "setChainRateLimiterConfig",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "address",
        name: "to",
        type: "address",
      },
    ],
    name: "transferOwnership",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
] as const;
