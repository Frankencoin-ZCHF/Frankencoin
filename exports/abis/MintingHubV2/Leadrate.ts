export const LeadrateABI = [
	{
		inputs: [
			{
				internalType: 'contract IReserve',
				name: 'equity_',
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
		inputs: [],
		name: 'NoPendingChange',
		type: 'error',
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
		inputs: [],
		name: 'applyChange',
		outputs: [],
		stateMutability: 'nonpayable',
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
] as const;
