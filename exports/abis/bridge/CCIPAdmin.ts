export const CCIPAdminABI = [
  {
    inputs: [
      {
        internalType: "contract TokenAdminRegistry",
        name: "tokenAdminRegistry",
        type: "address",
      },
      {
        internalType: "contract IBasicFrankencoin",
        name: "zchf",
        type: "address",
      },
    ],
    stateMutability: "nonpayable",
    type: "constructor",
  },
  {
    inputs: [],
    name: "AlreadyRegistered",
    type: "error",
  },
  {
    inputs: [
      {
        internalType: "bytes32",
        name: "hash",
        type: "bytes32",
      },
    ],
    name: "ProposalAlreadyMade",
    type: "error",
  },
  {
    inputs: [],
    name: "TokenPoolNotSet",
    type: "error",
  },
  {
    inputs: [
      {
        internalType: "uint64",
        name: "deadline",
        type: "uint64",
      },
    ],
    name: "TooEarly",
    type: "error",
  },
  {
    inputs: [
      {
        internalType: "bytes32",
        name: "hash",
        type: "bytes32",
      },
    ],
    name: "UnknownProposal",
    type: "error",
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: false,
        internalType: "bytes32",
        name: "hash",
        type: "bytes32",
      },
      {
        indexed: true,
        internalType: "address",
        name: "proposer",
        type: "address",
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
        indexed: false,
        internalType: "struct ITokenPool.ChainUpdate",
        name: "update",
        type: "tuple",
      },
    ],
    name: "AddChainProposed",
    type: "event",
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: false,
        internalType: "bytes32",
        name: "hash",
        type: "bytes32",
      },
      {
        indexed: true,
        internalType: "address",
        name: "proposer",
        type: "address",
      },
      {
        indexed: false,
        internalType: "address",
        name: "newAdmin",
        type: "address",
      },
    ],
    name: "AdminTransferProposed",
    type: "event",
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: false,
        internalType: "address",
        name: "newAdmin",
        type: "address",
      },
    ],
    name: "AdminTransferred",
    type: "event",
  },
  {
    anonymous: false,
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
        indexed: false,
        internalType: "struct ITokenPool.ChainUpdate",
        name: "config",
        type: "tuple",
      },
    ],
    name: "ChainAdded",
    type: "event",
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: false,
        internalType: "uint64",
        name: "id",
        type: "uint64",
      },
    ],
    name: "ChainRemoved",
    type: "event",
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: false,
        internalType: "bytes32",
        name: "hash",
        type: "bytes32",
      },
    ],
    name: "ProposalDenied",
    type: "event",
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: false,
        internalType: "bytes32",
        name: "hash",
        type: "bytes32",
      },
    ],
    name: "ProposalEnacted",
    type: "event",
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: false,
        internalType: "bytes32",
        name: "hash",
        type: "bytes32",
      },
      {
        indexed: false,
        internalType: "uint64",
        name: "deadline",
        type: "uint64",
      },
    ],
    name: "ProposalMade",
    type: "event",
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: false,
        internalType: "uint64",
        name: "remoteChain",
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
        indexed: false,
        internalType: "struct RateLimiter.Config",
        name: "inboundConfigs",
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
        indexed: false,
        internalType: "struct RateLimiter.Config",
        name: "outboundConfig",
        type: "tuple",
      },
    ],
    name: "RateLimit",
    type: "event",
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
        indexed: true,
        internalType: "bytes",
        name: "poolAddress",
        type: "bytes",
      },
    ],
    name: "RemotePoolAdded",
    type: "event",
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
        indexed: true,
        internalType: "bytes",
        name: "poolAddress",
        type: "bytes",
      },
    ],
    name: "RemotePoolRemoved",
    type: "event",
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: false,
        internalType: "bytes32",
        name: "hash",
        type: "bytes32",
      },
      {
        indexed: true,
        internalType: "address",
        name: "proposer",
        type: "address",
      },
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
        indexed: false,
        internalType: "struct CCIPAdmin.RemotePoolUpdate",
        name: "update",
        type: "tuple",
      },
    ],
    name: "RemotePoolUpdateProposed",
    type: "event",
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: false,
        internalType: "bytes32",
        name: "hash",
        type: "bytes32",
      },
      {
        indexed: true,
        internalType: "address",
        name: "proposer",
        type: "address",
      },
      {
        indexed: false,
        internalType: "uint64",
        name: "chain",
        type: "uint64",
      },
    ],
    name: "RemoveChainProposed",
    type: "event",
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: true,
        internalType: "address",
        name: "tokenPool",
        type: "address",
      },
    ],
    name: "TokenPoolSet",
    type: "event",
  },
  {
    inputs: [],
    name: "DAY",
    outputs: [
      {
        internalType: "uint64",
        name: "",
        type: "uint64",
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
    inputs: [],
    name: "TOKEN_ADMIN_REGISTRY",
    outputs: [
      {
        internalType: "contract TokenAdminRegistry",
        name: "",
        type: "address",
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
        internalType: "address",
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
        internalType: "contract ITokenPool",
        name: "_tokenPool",
        type: "address",
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
    name: "acceptAdmin",
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
    ],
    name: "applyAddChain",
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
    ],
    name: "applyAdminTransfer",
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
        name: "inbound",
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
        name: "outbound",
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
        internalType: "struct CCIPAdmin.RemotePoolUpdate",
        name: "update",
        type: "tuple",
      },
    ],
    name: "applyRemotePoolUpdate",
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
    ],
    name: "applyRemoveChain",
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
        internalType: "bytes32",
        name: "hash",
        type: "bytes32",
      },
    ],
    name: "proposals",
    outputs: [
      {
        internalType: "uint64",
        name: "deadline",
        type: "uint64",
      },
    ],
    stateMutability: "view",
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
        internalType: "struct CCIPAdmin.RemotePoolUpdate",
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
  {
    inputs: [
      {
        internalType: "contract RegistryModuleOwnerCustom",
        name: "registry",
        type: "address",
      },
      {
        internalType: "contract ITokenPool",
        name: "_tokenPool",
        type: "address",
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
    name: "registerToken",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [],
    name: "tokenPool",
    outputs: [
      {
        internalType: "contract ITokenPool",
        name: "",
        type: "address",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
] as const;
