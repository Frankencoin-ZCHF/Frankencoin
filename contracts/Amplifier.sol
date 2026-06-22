// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./interface/IERC20.sol";
import "./interface/IFrankencoin.sol";
import "./interface/IPosition.sol";
import "./interface/IUniswapV3Pool.sol";
import "./utils/Ownable.sol";
import "./utils/Math.sol";
import "./interface/IUniswapV3MintCallback.sol";

/**
 * @title Amplifier
 *
 * Factory contract to create amplified uniswap positions for a hardcoded pool. Amplified positions are positions for which
 * the ZCHF half of the trading pair is borrowed from the Frankencoin protocol and only the other token is provided by the owner.
 * This cuts the capital costs of liquidity provisioning in half, thereby making liquidity provisioning twice as profitable.
 * 
 * The range of the amplified position must be within 20% of the pool price when the amplifier was deployed. For example, if this
 * the amplifier for the ZCHF-USDT pool and it was initialized at an exchange rate of 0.85 CHF/USD, amplified positions must have
 * prices within the range from 0.68 and 1.02 CHF / USD.
 * 
 **/
contract Amplifier {

    uint256 internal constant Q96 = 0x1000000000000000000000000;

    IUniswapV3Pool public immutable UNISWAP_POOL;

    address public immutable TOKEN0;
    IFrankencoin public immutable ZCHF;
    IERC20 public immutable USD;

    int24 public immutable TICK_ANCHOR;
    uint256 public immutable PRICE_ANCHOR_X96; // sqrt(usd/zchf)

    int24 constant TWENTY_PERCENT = 2000; // one tick is 0.01%
    uint40 public immutable EXPIRATION;
    uint256 public immutable LIMIT;

    uint256 public totalBorrowed;

    error AccessDenied();
    error AmplifierExpired();
    error LimitExceeded(uint256 newValue, uint256 limit);
    error PriceChangedTooMuch(uint256 found, uint256 expected);
    error InvalidTick(int24 min, int24 found, int24 max);
    error InsufficientDollarsInRange(uint256 requiredMinimum, uint256 actuallyFoundInProvidedRange);

    event AmplifiedPositionCreated(address position);

    /**
     * Constructs the amplifier for the given pool.
     */
    constructor(address uniswapPool_, address zchf_, uint160 expectedPriceQ96, uint40 expiration, uint256 borrowingLimit){
        UNISWAP_POOL = IUniswapV3Pool(uniswapPool_);
        TOKEN0 = UNISWAP_POOL.token0();
        ZCHF = IFrankencoin(zchf_);
        USD = IERC20(TOKEN0 == zchf_ ? UNISWAP_POOL.token1() : UNISWAP_POOL.token0());
        EXPIRATION = expiration;
        LIMIT = borrowingLimit;
        require(ZCHF.decimals() == 18);
        require(USD.decimals() == 18);
        (uint160 sqrtPriceX96, int24 tick,,,,,) = UNISWAP_POOL.slot0();
        uint256 price = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96); // TODO: figure out within what bounds for token decimals and prices we are safe from overflows or rounding errors
        if (price * 99 / 100 > expectedPriceQ96) revert PriceChangedTooMuch(expectedPriceQ96, price);
        if (price * 101 / 100 < expectedPriceQ96) revert PriceChangedTooMuch(expectedPriceQ96, price);
        TICK_ANCHOR = tick;
        PRICE_ANCHOR_X96 = TOKEN0 == zchf_ ? expectedPriceQ96 : Math.mulDiv(Q96, Q96, expectedPriceQ96);
    }

    /**
     * Verifies that the provided ticks are within the valid range, i.e. +/-20% of the initial price.
     */
    function checkTicks(int24 ticksLow, int24 ticksHigh) external view {
        int24 MINIMUM = TICK_ANCHOR - TWENTY_PERCENT;
        int24 MAXIMUM = TICK_ANCHOR + TWENTY_PERCENT;
        if (ticksLow < MINIMUM || ticksLow > MAXIMUM) revert InvalidTick(MINIMUM, ticksLow, MAXIMUM);
        if (ticksHigh < MINIMUM || ticksHigh > MAXIMUM) revert InvalidTick(MINIMUM, ticksHigh, MAXIMUM);
    }

    function getMinimumDollars(uint256 zchfAmount) public view returns (uint256) {
        // (sqrt(price) * sqrt(price) * zchfAmount) with 96 bit worth of decimals
        return Math.mulDiv(Math.mulDiv(PRICE_ANCHOR_X96, PRICE_ANCHOR_X96, Q96), zchfAmount, Q96); 
    }

    /**
     * Borrows the given amount of zchf into the pool.
     * 
     * The range of the position must be such that there are also a reasonable amount of dollars, ensuring
     * that the owner is better off repaying the position in the end and not just walking away.
     * 
     * For example, if the initial price is 0.85 CHF/USD and borrowing 85 CHF, one needs to choose the range
     * of the position such that it also requires at least 100 USD.
     */
    function borrowIntoPool(address owner, uint256 token0Amount, uint256 token1Amount) external onlyPosition {
        (uint256 zchfAmount, uint256 collateralAmount) = identifyAmounts(token0Amount, token1Amount);
        if (block.timestamp > EXPIRATION) revert AmplifierExpired();
        uint256 required = getMinimumDollars(zchfAmount);
        if (required < collateralAmount) revert InsufficientDollarsInRange(required, collateralAmount);
        USD.transferFrom(owner, address(UNISWAP_POOL), collateralAmount); // obtain the dollars and deposit them into the pool
        ZCHF.mint(address(UNISWAP_POOL), zchfAmount); // mint directly to the uniswap pool, will be credited to the right position
        totalBorrowed += zchfAmount;
        if (totalBorrowed > LIMIT) revert LimitExceeded(totalBorrowed, LIMIT);
    }

    function identifyAmounts(uint256 token0Amount, uint256 token1Amount) internal view returns (uint256 zchf, uint256 usd) {
        return address(ZCHF) == TOKEN0 ? (token0Amount, token1Amount) : (token1Amount, token0Amount);
    }

    function repay(address owner, uint256 borrowed, uint128 returnedPart, uint128 total) external onlyPosition returns (uint256) {
        uint256 zchfToReturn = Math.mulDiv(borrowed, returnedPart, total);
        ZCHF.burnFrom(owner, zchfToReturn);
        totalBorrowed -= zchfToReturn;
        return zchfToReturn;
    }

    /** 
     * Creates a new amplified position with the msg.sender as owner.
    */
    function createAmplifiedPosition() public returns (address){
        AmplifiedPosition amplifier = new AmplifiedPosition(this, msg.sender);
        ZCHF.registerPosition(address(amplifier));
        emit AmplifiedPositionCreated(address(amplifier));
        return address(amplifier);
    }

    modifier onlyPosition() {
        if (ZCHF.getPositionParent(msg.sender) != address(this)) revert AccessDenied();
        _;
    }

}

/**
 * An amplified position belonging to a specific owner.
 */
contract AmplifiedPosition is Ownable, IUniswapV3MintCallback {

    Amplifier immutable AMP;

    uint256 public borrowed;
    uint128 public totalLiquidity;

    error AccessDenied(address sender);
    error NotExpired();

    event Mint(int24 tickLow, int24 tickHigh, uint128 liquidityAdded, uint256 newlyBorrowedFrankencoin);
    event Burn(int24 tickLow, int24 tickHigh, uint128 liquidityRemoved, uint256 returnedFrankencoins);

    constructor(Amplifier parent, address owner){
        AMP = parent;
        _setOwner(owner);
    }

    /**
     * Mints the provided amount of liquidity for the uniswap position specified by the given range between the low and the high tick.
     * 
     * This function only succeeds if the caller has sufficient dollars on his address and if there is an allowance in place 
     */
    function mint(int24 tickLow, int24 tickHigh, uint128 amount) external onlyOwner {
        AMP.checkTicks(tickLow, tickHigh);
        uint256 currentlyBorrowed = borrowed;
        AMP.UNISWAP_POOL().mint(address(this), tickLow, tickHigh, amount, "");
        totalLiquidity += amount;
        emit Mint(tickLow, tickHigh, amount, borrowed - currentlyBorrowed);
    }

    /**
     * Callback from pool to provide the indicated token amounts.
     */
    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata) external {
        if (msg.sender != address(AMP.UNISWAP_POOL())) revert AccessDenied(msg.sender); // we can take this shortcut as we know the pool
        AMP.borrowIntoPool(owner, amount0Owed, amount1Owed); // obtain the tokens and deposit them into the pool
        borrowed += amount0Owed;
    }

    /**
     * Return the provided amount of liquidity.
     * 
     * The tokens will be returned to the owner. In case additional ZCHF are required to repay the borrowed amounts, the missing
     * ZCHF are taken from the owner's address. When burning X% of the position liquidity, X% of the borrowed Frankencoins must be returned.
     * At the same time, accrued fees are collected.
     * 
     * TODO: this function implicitely assumes that the liquidity of one position can be compared to that of another position.
     * If these amounts have different orders of magnitude depending on the position, we have a problem.
     */
    function burn(int24 tickLow, int24 tickHigh, uint128 burnedLiquidity) external onlyOwner returns (uint256 amount0, uint256 amount1) {
        return _burn(tickLow, tickHigh, burnedLiquidity);
    }

    /**
     * Once the amplifier has expired, let anyone burn positions and collect the underlying tokens.
     * 
     * As long as the exchange rate has not fallen by more than 50% since the deployment of the amplifier, this can be called profitably at the expense of the position owner.
     */
    function expiredPublicBurn(int24 tickLow, int24 tickHigh, uint128 burnedLiquidity) public returns (uint256 amount0, uint256 amount1) {
        if (block.timestamp <= AMP.EXPIRATION()) revert NotExpired();
        return _burn(tickLow, tickHigh, burnedLiquidity);
    }

    function _burn(int24 tickLow, int24 tickHigh, uint128 burnedLiquidity) internal returns (uint256 amount0, uint256 amount1) {
        IUniswapV3Pool pool = AMP.UNISWAP_POOL();
        (uint256 amount0Received, uint256 amount1Received) = pool.burn(tickLow, tickHigh, burnedLiquidity); // burn does not collect yet
        IERC20(pool.token0()).transfer(msg.sender, amount0Received);
        IERC20(pool.token1()).transfer(msg.sender, amount1Received);
        (uint128 fees0, uint128 fees1) = pool.collect(msg.sender, tickLow, tickHigh, type(uint128).max, type(uint128).max); // collect fees
        uint256 returnedZCHF = AMP.repay(msg.sender, borrowed, burnedLiquidity, totalLiquidity);
        borrowed -= returnedZCHF;
        totalLiquidity -= burnedLiquidity;
        emit Burn(tickLow, tickHigh, burnedLiquidity, returnedZCHF);
        return (amount0Received + fees0, amount1Received + fees1);
    }

}