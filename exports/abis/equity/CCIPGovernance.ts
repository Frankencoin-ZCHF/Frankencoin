export const CCIPGovernanceABI = [
  {
    inputs: [
      {
        internalType: "contract IGovernance",
        name: "gov",
        type: "address",
      },
      {
        internalType: "address",
        name: "mainnetFCS_",
        type: "address",
      },
      {
        internalType: "contract ICCIPAdmin",
        name: "ccipAdmin_",
        type: "address",
      },
    ],
    stateMutability: "nonpayable",
    type: "constructor",
  },
  {
    inputs: [],
    name: "CCIP_ADMIN",
    outputs: [
      {
        internalType: "contract ICCIPAdmin",
        name: "",
        type: "address",
      },
    ],
    stateMutability: "view",
    type: "function",
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
    inputs: [
      {
        internalType: "uint64[]",
        name: "chains",
        type: "uint64[]",
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
        name: "outbound",
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
        name: "inbound",
        type: "tuple",
      },
      {
        internalType: "address[]",
        name: "helpers",
        type: "address[]",
      },
    ],
    name: "applyRateLimit",
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
        name: "outbound",
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
        name: "inbound",
        type: "tuple",
      },
      {
        internalType: "address[]",
        name: "helpers",
        type: "address[]",
      },
    ],
    name: "applyRateLimit",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "bytes32[]",
        name: "hashes",
        type: "bytes32[]",
      },
      {
        internalType: "address[]",
        name: "helpers",
        type: "address[]",
      },
    ],
    name: "deny",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "bytes32",
        name: "hash",
        type: "bytes32",
      },
      {
        internalType: "address[]",
        name: "helpers",
        type: "address[]",
      },
    ],
    name: "deny",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
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
        internalType: "struct ITokenPool.ChainUpdate",
        name: "config",
        type: "tuple",
      },
      {
        internalType: "address[]",
        name: "helpers",
        type: "address[]",
      },
    ],
    name: "proposeAddChain",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "address",
        name: "newAdmin",
        type: "address",
      },
      {
        internalType: "address[]",
        name: "helpers",
        type: "address[]",
      },
    ],
    name: "proposeAdminTransfer",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        components: [
          {
            internalType: "bool",
            name: "add",
            type: "bool",
          },
          {
            internalType: "uint64",
            name: "chain",
            type: "uint64",
          },
          {
            internalType: "bytes",
            name: "poolAddress",
            type: "bytes",
          },
        ],
        internalType: "struct ICCIPAdmin.RemotePoolUpdate",
        name: "update",
        type: "tuple",
      },
      {
        internalType: "address[]",
        name: "helpers",
        type: "address[]",
      },
    ],
    name: "proposeRemotePoolUpdate",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "uint64",
        name: "chainId",
        type: "uint64",
      },
      {
        internalType: "address[]",
        name: "helpers",
        type: "address[]",
      },
    ],
    name: "proposeRemoveChain",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
] as const;
