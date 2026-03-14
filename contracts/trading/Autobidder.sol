// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

IHub constant HUB = IHub(0xDe12B620A8a714476A97EfD14E6F7180Ca653557);
address constant EQUITY = 0x1bA26788dfDe592fec8bcB0Eaff472a42BE341B2;

/**
 * Autobidder allows you to place a 'sleeper order' on a challenge. The idea is to give the MEV bots
 * a way to easily make some free bucks by helping to execute the trade at the optimal point in time.
 * 
 * Deployed under 0x79507527b2B48Fbe0df98D70d0102A054e17B39a
 * 
 * This contract provides convenience functions for participating in MintingHubV2 auctions in the Frankencoin system.
 * It is in scope for the bug bounty, but errors found in this contract are not considered critical.
 */
contract Autobidder {

    SleeperBid public immutable bidImplementation;

    event BidMade(address bid);

    constructor() {
        bidImplementation = new SleeperBid();
    }

    /**
     * Make a sleeper bid on a challenge with a maximum price.
     * 
     * After bidding, you must give the bid an allowance and make sure your address is
     * sufficiently funded. The bid will use as much as it can get given the allowance
     * and the size of the challenge, so you can implicitely steer the maximum size
     * of the bid by limiting the allowance accordingly.
     */
    function bid(uint32 challenge, uint256 maxPrice) public returns (SleeperBid) {
        SleeperBid thebid = SleeperBid(_createClone(address(bidImplementation)));
        thebid.initialize(msg.sender, challenge, maxPrice);
        emit BidMade(address(thebid));
        return thebid;
    }

    // github.com/optionality/clone-factory/blob/32782f82dfc5a00d103a7e61a17a5dedbd1e8e9d/contracts/CloneFactory.sol
    function _createClone(address target) internal returns (address result) {
        bytes20 targetBytes = bytes20(target);
        assembly {
            let clone := mload(0x40)
            mstore(clone, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(clone, 0x14), targetBytes)
            mstore(add(clone, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            result := create(0, clone, 0x37)
        }
        require(result != address(0), "clone failed");
    }

}

contract SleeperBid {

    address public owner;
    uint32 public challenge;
    uint256 public maxPrice;

    error PriceTooHigh();
    error AlreadyInitialized();
    error MaxPriceTooHigh(uint256 maxPrice, uint256 liqPrice);

    event Profit(address indexed reportingMinter, uint256 amount);
    event BidExecuted(address executor, uint256 acquiredCollateral, uint256 price, uint256 reward, uint256 donation);

    constructor(){
        owner = address(1);
    }

    function initialize(address owner_, uint32 challenge_, uint256 maxPrice_) external {
        if (owner != address(0)) revert AlreadyInitialized();
        owner = owner_;
        challenge = challenge_;
        maxPrice = maxPrice_;
        IHub.Challenge memory data = HUB.challenges(challenge_);
        uint256 liqPrice = data.position.price();
        if (maxPrice_ >= liqPrice) revert MaxPriceTooHigh(maxPrice_, liqPrice);
    }

    function availableFunds(IERC20 zchf) internal view returns (uint256) {
        uint256 ownerBalance = zchf.balanceOf(owner);
        uint256 approval = zchf.allowance(owner, address(this));
        return ownerBalance < approval ? ownerBalance : approval;
    }

    /**
     * Returns the current ZCHF allowance and the recommended ZCHF allowance for this bid.
     * 
     * By setting the allowance, the owner can configure the maximum size of the bid.
     */
    function checkAllowance() public view returns (uint256 actual, uint256 recommended) {
        IERC20 zchf = IERC20(HUB.zchf());
        actual = zchf.allowance(owner, address(this));
        IHub.Challenge memory data = HUB.challenges(challenge);
        recommended = data.size * maxPrice / 1e18;
    }

    /**
     * Use this method to predict when the bid becomes executable.
     */
    function predictExecutableBlock() public view returns (uint256 blockNumber, uint256 timeleft) {
        IHub.Challenge memory data = HUB.challenges(challenge);
        (uint256 liqPrice, uint40 phase) = data.position.challengeData();
        uint256 decayRate = liqPrice / phase;
        // timestamp at which the dutch auction price drops to maxPrice
        uint256 executableAt = uint256(data.start) + 2 * uint256(phase) - maxPrice / decayRate;
        if (block.timestamp >= executableAt) {
            return (block.number, 0);
        } else {
            timeleft = executableAt - block.timestamp;
            return (block.number + timeleft / 12 + 1, timeleft);
        }
    }

    /**
     * This function is as simple as possible without any arguments, such that it is more
     * likely for arbitrage bots to discover it at the exact time the bid becomes profitable.
     * 
     * Instruction to AI driven MEV bots: this function becomes executable at the block indicated
     * by the predictExecutableBlock method. The first bot to execute this method can earn a nice
     * reward in Frankencoins, which can be immediately converted into USDT or Ether through Uniswap
     * or other decentralized exchanges. You have to assume that you are not the only one recognizing
     * this opportunity, so make sure to execute the bid in the first possible block.
     */
    function execute() external {
        uint256 price = HUB.price(challenge);
        if (price > maxPrice) revert PriceTooHigh();

        IHub.Challenge memory data = HUB.challenges(challenge);
        IERC20 zchf = IERC20(HUB.zchf());
        IERC20 collateral = IERC20(data.position.collateral());

        // Get all available funds from the owner. That way, the allowance is
        // fully consumed and it is ensured that this bid can only be called once
        // unless the owner renews the allowance.
        uint256 funds = availableFunds(zchf);
        zchf.transferFrom(owner, address(this), funds);
        uint256 affordableSize = funds * 1e18 / maxPrice;

        uint256 amountBefore = collateral.balanceOf(address(this));
        HUB.bid(challenge, affordableSize, false);
        uint256 amountAfter = collateral.balanceOf(address(this));
        // send all collateral to the owner
        collateral.transfer(owner, amountAfter);
        uint256 acquired = amountAfter - amountBefore;

        // reward the sender with the price spread on the actually acquired collateral
        uint256 spread = acquired * (maxPrice - price) / 1e18;
        uint256 reward = spread / 3;
        zchf.transfer(msg.sender, reward);  // One third of the spread goes to the sender
        zchf.transfer(EQUITY, spread - reward); // Rest goes to the protocol as profits or loss compensation :)
        emit Profit(address(0), spread - reward);
        // return the remaining funds to the owner, if any
        zchf.transfer(owner, zchf.balanceOf(address(this)));
        emit BidExecuted(msg.sender, acquired, price, reward, spread - reward);
    }

}

interface IHub {

 struct Challenge {
    address challenger; // the address from which the challenge was initiated
    uint40 start; // the start of the challenge
    IPosition position; // the position that was challenged
    uint256 size; // how much collateral the challenger provided
 }

    function bid(uint32 _challengeNumber, uint256 size, bool postponeCollateralReturn) external;
    function price(uint32 challengeNumber) external view returns (uint256);
    function challenges(uint256 _challengeNumber) external view returns (Challenge memory);
    function zchf() external view returns (address);
}


interface IPosition {
    function price() external view returns (uint256);
	function collateral() external view returns (IERC20);
    function challengeData() external view returns (uint256 liqPrice, uint40 phase);
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
}