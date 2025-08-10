# Frankencoin's Cross-Chain Governance

Lean cross-chain governance for decentralized protocols.

## The Challenge

The challenge is to build a decentralized stablecoin whose functionality spans across chains.

Often, decentralized protocols are bound to their native chain. This limits their reach and fragments their ecosystem. An ideal decentralized protocol spans across multiple chains, with its full functionality available for all users on all supported chains. For Frankencoin, this means that merely bridging the stablecoin using one of the available standard bridges does not cut it. We want direct support of all protocol functions across chains. This requires a cross-chain governance system that allows the governance process to project its decision taking power across chains. Fortunately, the Frankencoin's veto-based governance system lends itself perfectly to such use cases. It allows very efficient cross-chain governance with minimal interventions and maximal versatility.
 
## Veto-Based Governance

Let us first look at how the Frankencoin stays modular and extensible without resorting to a centralized authority.

Some decentralized protocols are immutable. They cannot be changed or extended. In that case, no governance system is needed. However, this makes them static and often they struggle at competing with more adaptable protocols. That is why many decentralized protocols come with a governance token whose owners can collectively steer the fate of the protocol. The typical decision taking process revolves around some form of democratic vote. However, conducting public votes is a heavy-weight process that is often dominated by a few large players. Most system participatns do not bother to vote, exposing the protocol to the risk of last-minute vote swings through bad actors. Frankencoin has found a way to escape these problems by basing its governance processes on vetoes.

In the Frankencoin system, holders of at least 2% of the governance token gain veto power over time. Proposals to amend the system can be made by anyone paying a small fee. The proposals pass automatically if no one casts a veto. This leads to a process that is extremely lean: most of the time, new proposals pass without anyone having to cast a vote or veto ever. If everyone behaves rationally, no one makes a bad proposal and good new ideas just pass without much ado. There are some safeguards against griefing, but their presence suffices to deter bad actors. Fortunately, this light-weight process lends itself extraordinarily well to decentralized cross-chain governance.

## Projecting Power Across Chains

The Frankencoin system consists of almost identical smart contracts across all chains. The bridged ERC-20 contract that represents the stablecoin on Base has the same modular extensibility as the original contract on Ethereum mainnet. Base users can propose new functionality directly on the base blockchain and pass them without ever performing a mainnet transaction. Only if someone wants to veto a proposal, they need to first prove their veto power through a cross-chain message that is routed using Chainlink CCIP. Once it has been proven that someone possesses veto power, that veto power can be used to cast any number of vetoes on the given chain, until someone else proves that the user's address no longer has veto power in a new cross-chain message.

As long as all system participants behave rationally and only reasonable proposals are made, no action ever needs to be taken. This is similar to optimistic roll-ups, which are based on the optimistic assumption that the vast majority of transactions are valid and that the threat of slashing or other counter-measures suffices to deter bad actors. In case of the Frankencoin system, the deterrence comes from the proposal fees that are lost in case a proposal is vetoed. It ensures that only proposals are made that enjoy broad community support.

## Conclusion

The Frankencoin pushes the frontier of the possible in multiple dimensnions. It has a unique collateralized minting mechanism that does not depend on oracles. It has a built-in bonding curve for the issuance and redemption of governance tokens that stands on deep economic foundations. And it has a governance system that is extraordinarily lean and extensible across chains. It is the Swiss army knife among decentralized stablecoins. And it is now also [available on Base](https://basescan.org/address/0xD4dD9e2F021BB459D5A5f6c24C12fE09c5D45553), offering an excellent 3% yield on Swiss francs.