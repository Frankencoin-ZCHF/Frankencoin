export const SavingsABI = [
	{
		inputs: [
			{
				internalType: 'contract IFrankencoin',
				name: 'zchf_',
				type: 'address',
			},
			{
				internalType: 'uint24',
				name: 'initialRatePPM',
				type: 'uint24',
			},
		],
		stateMutability: 'nonpayable',
		type: 'constructor',
	},
	{
		inputs: [],
		name: 'ChangeNotReady',
		type: 'error',
	},
	{
		inputs: [
			{
				internalType: 'uint40',
				name: 'remainingSeconds',
				type: 'uint40',
			},
		],
		name: 'FundsLocked',
		type: 'error',
	},
	{
		inputs: [],
		name: 'ModuleDisabled',
		type: 'error',
	},
	{
		inputs: [],
		name: 'NoPendingChange',
		type: 'error',
	},
	{
		anonymous: false,
		inputs: [
			{
				indexed: true,
				internalType: 'address',
				name: 'account',
				type: 'address',
			},
			{
				indexed: false,
				internalType: 'uint256',
				name: 'interest',
				type: 'uint256',
			},
		],
		name: 'InterestCollected',
		type: 'event',
	},
	{
		anonymous: false,
		inputs: [
			{
				indexed: false,
				internalType: 'uint24',
				name: 'newRate',
				type: 'uint24',
			},
		],
		name: 'RateChanged',
		type: 'event',
	},
	{
		anonymous: false,
		inputs: [
			{
				indexed: false,
				internalType: 'address',
				name: 'who',
				type: 'address',
			},
			{
				indexed: false,
				internalType: 'uint24',
				name: 'nextRate',
				type: 'uint24',
			},
			{
				indexed: false,
				internalType: 'uint40',
				name: 'nextChange',
				type: 'uint40',
			},
		],
		name: 'RateProposed',
		type: 'event',
	},
	{
		anonymous: false,
		inputs: [
			{
				indexed: true,
				internalType: 'address',
				name: 'account',
				type: 'address',
			},
			{
				indexed: false,
				internalType: 'uint192',
				name: 'amount',
				type: 'uint192',
			},
		],
		name: 'Saved',
		type: 'event',
	},
	{
		anonymous: false,
		inputs: [
			{
				indexed: true,
				internalType: 'address',
				name: 'account',
				type: 'address',
			},
			{
				indexed: false,
				internalType: 'uint192',
				name: 'amount',
				type: 'uint192',
			},
		],
		name: 'Withdrawn',
		type: 'event',
	},
	{
		inputs: [],
		name: 'INTEREST_DELAY',
		outputs: [
			{
				internalType: 'uint64',
				name: '',
				type: 'uint64',
			},
		],
		stateMutability: 'view',
		type: 'function',
	},
	{
		inputs: [
			{
				internalType: 'address',
				name: 'accountOwner',
				type: 'address',
			},
		],
		name: 'accruedInterest',
		outputs: [
			{
				internalType: 'uint192',
				name: '',
				type: 'uint192',
			},
		],
		stateMutability: 'view',
		type: 'function',
	},
	{
		inputs: [
			{
				internalType: 'address',
				name: 'accountOwner',
				type: 'address',
			},
			{
				internalType: 'uint256',
				name: 'timestamp',
				type: 'uint256',
			},
		],
		name: 'accruedInterest',
		outputs: [
			{
				internalType: 'uint192',
				name: '',
				type: 'uint192',
			},
		],
		stateMutability: 'view',
		type: 'function',
	},
	{
		inputs: [
			{
				internalType: 'uint192',
				name: 'targetAmount',
				type: 'uint192',
			},
		],
		name: 'adjust',
		outputs: [],
		stateMutability: 'nonpayable',
		type: 'function',
	},
	{
		inputs: [],
		name: 'applyChange',
		outputs: [],
		stateMutability: 'nonpayable',
		type: 'function',
	},
	{
		inputs: [
			{
				components: [
					{
						internalType: 'uint192',
						name: 'saved',
						type: 'uint192',
					},
					{
						internalType: 'uint64',
						name: 'ticks',
						type: 'uint64',
					},
				],
				internalType: 'struct Savings.Account',
				name: 'account',
				type: 'tuple',
			},
			{
				internalType: 'uint64',
				name: 'ticks',
				type: 'uint64',
			},
		],
		name: 'calculateInterest',
		outputs: [
			{
				internalType: 'uint192',
				name: '',
				type: 'uint192',
			},
		],
		stateMutability: 'view',
		type: 'function',
	},
	{
		inputs: [],
		name: 'currentRatePPM',
		outputs: [
			{
				internalType: 'uint24',
				name: '',
				type: 'uint24',
			},
		],
		stateMutability: 'view',
		type: 'function',
	},
	{
		inputs: [],
		name: 'currentTicks',
		outputs: [
			{
				internalType: 'uint64',
				name: '',
				type: 'uint64',
			},
		],
		stateMutability: 'view',
		type: 'function',
	},
	{
		inputs: [],
		name: 'equity',
		outputs: [
			{
				internalType: 'contract IReserve',
				name: '',
				type: 'address',
			},
		],
		stateMutability: 'view',
		type: 'function',
	},
	{
		inputs: [],
		name: 'nextChange',
		outputs: [
			{
				internalType: 'uint40',
				name: '',
				type: 'uint40',
			},
		],
		stateMutability: 'view',
		type: 'function',
	},
	{
		inputs: [],
		name: 'nextRatePPM',
		outputs: [
			{
				internalType: 'uint24',
				name: '',
				type: 'uint24',
			},
		],
		stateMutability: 'view',
		type: 'function',
	},
	{
		inputs: [
			{
				internalType: 'uint24',
				name: 'newRatePPM_',
				type: 'uint24',
			},
			{
				internalType: 'address[]',
				name: 'helpers',
				type: 'address[]',
			},
		],
		name: 'proposeChange',
		outputs: [],
		stateMutability: 'nonpayable',
		type: 'function',
	},
	{
		inputs: [
			{
				internalType: 'address',
				name: 'owner',
				type: 'address',
			},
		],
		name: 'refreshBalance',
		outputs: [
			{
				internalType: 'uint192',
				name: '',
				type: 'uint192',
			},
		],
		stateMutability: 'nonpayable',
		type: 'function',
	},
	{
		inputs: [],
		name: 'refreshMyBalance',
		outputs: [
			{
				internalType: 'uint192',
				name: '',
				type: 'uint192',
			},
		],
		stateMutability: 'nonpayable',
		type: 'function',
	},
	{
		inputs: [
			{
				internalType: 'address',
				name: 'owner',
				type: 'address',
			},
			{
				internalType: 'uint192',
				name: 'amount',
				type: 'uint192',
			},
		],
		name: 'save',
		outputs: [],
		stateMutability: 'nonpayable',
		type: 'function',
	},
	{
		inputs: [
			{
				internalType: 'uint192',
				name: 'amount',
				type: 'uint192',
			},
		],
		name: 'save',
		outputs: [],
		stateMutability: 'nonpayable',
		type: 'function',
	},
	{
		inputs: [
			{
				internalType: 'address',
				name: '',
				type: 'address',
			},
		],
		name: 'savings',
		outputs: [
			{
				internalType: 'uint192',
				name: 'saved',
				type: 'uint192',
			},
			{
				internalType: 'uint64',
				name: 'ticks',
				type: 'uint64',
			},
		],
		stateMutability: 'view',
		type: 'function',
	},
	{
		inputs: [
			{
				internalType: 'uint256',
				name: 'timestamp',
				type: 'uint256',
			},
		],
		name: 'ticks',
		outputs: [
			{
				internalType: 'uint64',
				name: '',
				type: 'uint64',
			},
		],
		stateMutability: 'view',
		type: 'function',
	},
	{
		inputs: [
			{
				internalType: 'address',
				name: 'target',
				type: 'address',
			},
			{
				internalType: 'uint192',
				name: 'amount',
				type: 'uint192',
			},
		],
		name: 'withdraw',
		outputs: [
			{
				internalType: 'uint256',
				name: '',
				type: 'uint256',
			},
		],
		stateMutability: 'nonpayable',
		type: 'function',
	},
	{
		inputs: [],
		name: 'zchf',
		outputs: [
			{
				internalType: 'contract IERC20',
				name: '',
				type: 'address',
			},
		],
		stateMutability: 'view',
		type: 'function',
	},
] as const;
