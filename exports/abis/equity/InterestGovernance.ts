export const InterestGovernanceABI = [
  {
    inputs: [
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
        name: "fcsmainnet",
        type: "address",
      },
      {
        internalType: "contract ILeadrateProposal",
        name: "borrowingLeadrate_",
        type: "address",
      },
      {
        internalType: "contract ILeadrateProposal",
        name: "savingsLeadrate_",
        type: "address",
      },
      {
        internalType: "address",
        name: "delegate",
        type: "address",
      },
    ],
    stateMutability: "nonpayable",
    type: "constructor",
  },
  {
    inputs: [],
    name: "BORROWING_LEADRATE",
    outputs: [
      {
        internalType: "contract ILeadrateProposal",
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
    inputs: [],
    name: "SAVINGS_LEADRATE",
    outputs: [
      {
        internalType: "contract ILeadrateProposal",
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
        internalType: "uint24",
        name: "newRatePPM",
        type: "uint24",
      },
      {
        internalType: "address[]",
        name: "helpers",
        type: "address[]",
      },
    ],
    name: "proposeBorrowingRate",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "uint24",
        name: "newRatePPM",
        type: "uint24",
      },
      {
        internalType: "address[]",
        name: "helpers",
        type: "address[]",
      },
    ],
    name: "proposeSavingsRate",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
] as const;
