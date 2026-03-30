// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../stablecoin/IFrankencoin.sol";
import "../minting/IPosition.sol";
import "./utils/IUniswapV3Pool.sol";
import "../utils/Ownable.sol";
import "./utils/IUniswapV3MintCallback.sol";
import "./utils/SafeERC20.sol";

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
    using SafeERC20 for IERC20;

    uint256 internal constant Q96 = 0x1000000000000000000000000;

    IUniswapV3Pool public immutable UNISWAP_POOL;

    address public immutable TOKEN0;
    IFrankencoin public immutable ZCHF;
    IERC20 public immutable USD;

    uint256 public immutable PRICE_ANCHOR_X96; // sqrt(usd/zchf)

    // With tick space we allow to deposit liquidity
    int24 public immutable TICK_LOW_LIMIT;
    int24 public immutable TICK_HIGH_LIMIT;
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
    event Borrowed(uint256 borrowed, uint256 totalBorrowed);
    event Repaid(uint256 amount, uint256 totalBorrowed);

    /**
     * Constructs the amplifier for the given pool.
     */
    constructor(address uniswapPool_, address zchf_, uint160 expectedPriceQ96, uint40 expiration, uint256 borrowingLimit) {
        UNISWAP_POOL = IUniswapV3Pool(uniswapPool_);
        TOKEN0 = UNISWAP_POOL.token0();
        ZCHF = IFrankencoin(zchf_);
        USD = IERC20(TOKEN0 == zchf_ ? UNISWAP_POOL.token1() : UNISWAP_POOL.token0());
        EXPIRATION = expiration;
        LIMIT = borrowingLimit;

        (uint160 sqrtPriceX96, int24 tick, , , , , ) = UNISWAP_POOL.slot0();
        (TICK_LOW_LIMIT, TICK_HIGH_LIMIT) = getTickBounds(tick, UNISWAP_POOL.fee());
        // With 2 stable coins it is nearly impossible to overflow a uint256.
        uint256 price = (sqrtPriceX96 * sqrtPriceX96) >> 96;
        if ((price * 99) / 100 > expectedPriceQ96) revert PriceChangedTooMuch(expectedPriceQ96, price);
        if ((price * 101) / 100 < expectedPriceQ96) revert PriceChangedTooMuch(expectedPriceQ96, price);
        PRICE_ANCHOR_X96 = TOKEN0 == zchf_ ? expectedPriceQ96 : (uint256(1) << 192) / expectedPriceQ96;
    }

    /// @notice Returns the highest highTick and lowest low tick we allow.
    /// @dev Includes tick spacings https://support.uniswap.org/hc/en-us/articles/21069524840589-What-is-a-tick-when-providing-liquidity
    /// @param tick Current tick of the pool
    /// @param fee Fee of the pool. Influences the tick spacing
    /// @return lowerBound, higherBound Tick range we allow
    function getTickBounds(int24 tick, uint24 fee) internal pure returns (int24, int24) {
        int24 tickSpacing = int24(fee / 100);
        if (tickSpacing > 1) {
            // if fee is above 100 bips a multiplier is applied
            tickSpacing = tickSpacing * 2;
        }

        /** Depending on the fee liquidity can only be added at certain ticks, eventho the price can be between.
         *  We have 12 ticks with a fee of 200 = ticks initialized are a multiple of 4.
         *  b = bounds, p = current price
         * | 0  | 1  | 2  | 3  | 4  | 5  | 6  | 7  | 8  | 9  | 10 | 11 | 12 |
         * | -  | -  | -  | -  | -  | -  | -  | -  | -  | -  | -  | -  | -  |
         * | b  | -  | -  | -  | b  | -  | p  | -  | b  | -  | -  | -  | b  |
         *
         * So liquidity can only be added with low or high tick where tick % 4 == 0.
         * We move the current tick by 20% up and down and then take the higher bound or lower bound.
         * With a current tick of 7 and an allowed range of 20% we end up with 4 as low and 12 as high.
         * low = 7 * 0.8 = 5 / 4 * 4 = 4
         * high = 7 * 1.2 = 8 / 4 * 4 + 4 = 12
         */

        // We allow +/- 20% from the current tick
        int24 lowerTick = tick - 2000;
        int24 higherTick = tick + 2000;

        int24 lowerBound = (lowerTick / tickSpacing) * tickSpacing;
        int24 higherBound = (higherTick / tickSpacing) * tickSpacing + tickSpacing;
        return (lowerBound, higherBound);
    }

    /// @notice Verifies that the provided ticks are within the valid range, i.e. +/-20% of the initial price.
    /// @dev Reverts if ticks aren't in +/- 20% of TICK_ANCHOR
    /// @param ticksLow Lower limit of ticks
    /// @param ticksHigh Higher limit of ticks
    function checkTicks(int24 ticksLow, int24 ticksHigh) external view {
        if (ticksLow < TICK_LOW_LIMIT || ticksLow > TICK_HIGH_LIMIT) revert InvalidTick(TICK_LOW_LIMIT, ticksLow, TICK_HIGH_LIMIT);
        if (ticksHigh < TICK_LOW_LIMIT || ticksHigh > TICK_HIGH_LIMIT) revert InvalidTick(TICK_LOW_LIMIT, ticksHigh, TICK_HIGH_LIMIT);
    }

    /// @notice Calculates min. dollars required for the given ZCHF amount based on the price anchor
    /// @param zchfAmount Amount of ZCHF
    /// @return Amount of dollars
    function getMinimumDollars(uint256 zchfAmount) public view returns (uint256) {
        return (PRICE_ANCHOR_X96 * zchfAmount) >> 96;
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
    /// @notice Borrows the given amount of zchf into the pool.
    /// @dev Required approval of pairing token for transfer amount
    /// @param owner User to take the paring tokens from
    /// @param token0Amount Amount of token0 to send to the pool
    /// @param token1Amount Amount of token1 to send to the pool
    /// @return Amount borrowed in ZCHF
    function borrowIntoPool(address owner, uint256 token0Amount, uint256 token1Amount) external onlyPosition returns (uint256) {
        if (block.timestamp > EXPIRATION) revert AmplifierExpired();

        (uint256 zchfAmount, uint256 collateralAmount) = identifyAmounts(token0Amount, token1Amount);
        uint256 required = getMinimumDollars(zchfAmount);
        if (collateralAmount < required) revert InsufficientDollarsInRange(required, collateralAmount);

        USD.safeTransferFrom(owner, address(UNISWAP_POOL), collateralAmount); // obtain the dollars and deposit them into the pool
        ZCHF.mint(address(UNISWAP_POOL), zchfAmount); // mint directly to the uniswap pool, will be credited to the right position

        totalBorrowed += zchfAmount;
        if (totalBorrowed > LIMIT) revert LimitExceeded(totalBorrowed, LIMIT);

        emit Borrowed(zchfAmount, totalBorrowed);
        return zchfAmount;
    }

    /// @notice Identifies which amounts belong to which token
    /// @param token0Amount Amount of token0
    /// @param token1Amount Amount of token1
    /// @return zchf and usd amounts sorted
    function identifyAmounts(uint256 token0Amount, uint256 token1Amount) internal view returns (uint256 zchf, uint256 usd) {
        return address(ZCHF) == TOKEN0 ? (token0Amount, token1Amount) : (token1Amount, token0Amount);
    }

    /// @notice Repays a position by burning borrowed ZCHF from the owner
    /// @param owner ZCHF holder
    /// @param borrowed Total amount of ZCHF borrowed
    /// @param returnedPart Amount of liquidity returned
    /// @param total  Total amount of liquidity hold by the position
    /// @return Amount of ZCHF burned from the owner
    function repay(address owner, uint256 borrowed, uint128 returnedPart, uint128 total) external onlyPosition returns (uint256) {
        uint256 zchfToReturn = (borrowed * returnedPart) / total;
        ZCHF.burnFrom(owner, zchfToReturn);
        totalBorrowed -= zchfToReturn;
        emit Repaid(zchfToReturn, totalBorrowed);
        return zchfToReturn;
    }

    /// @notice Creates a new amplified position with the msg.sender as owner.
    /// @return Address of the newly created Position
    function createAmplifiedPosition() public returns (address) {
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

    event Mint(int24 tickLow, int24 tickHigh, uint128 liquidityAdded, uint256 newlyBorrowedFrankencoin);
    event Burn(int24 tickLow, int24 tickHigh, uint128 liquidityRemoved, uint256 returnedFrankencoins);

    constructor(Amplifier parent, address owner) {
        AMP = parent;
        _setOwner(owner);
    }

    /// @notice Mints the provided amount of liquidity for the uniswap position specified by the given range between the low and the high tick.
    /// @dev This function only succeeds if the caller has sufficient dollars on his address and if there is an allowance in place
    /// @param tickLow Lower limit of ticks
    /// @param tickHigh Upper limit of ticks
    /// @param amount Amount of liquidity to add
    function mint(int24 tickLow, int24 tickHigh, uint128 amount) external onlyOwner {
        AMP.checkTicks(tickLow, tickHigh);
        uint256 currentlyBorrowed = borrowed;
        AMP.UNISWAP_POOL().mint(address(this), tickLow, tickHigh, amount, "");
        totalLiquidity += amount;
        emit Mint(tickLow, tickHigh, amount, borrowed - currentlyBorrowed);
    }

    /// @notice Callback from pool to provide the indicated token amounts.
    /// @param amount0Owed Amount of token0 owed to the pool
    /// @param amount1Owed Amount of token1 owed to the pool
    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata) external {
        if (msg.sender != address(AMP.UNISWAP_POOL())) revert AccessDenied(msg.sender); // we can take this shortcut as we know the pool
        borrowed += AMP.borrowIntoPool(owner, amount0Owed, amount1Owed); // obtain the tokens and deposit them into the pool
    }

    /// @notice Return the provided amount of liquidity.
    /// @dev The tokens will be returned to the owner. In case additional ZCHF are required to repay the borrowed amounts, the missing
    ///      ZCHF are taken from the owner's address. When burning X% of the position liquidity, X% of the borrowed Frankencoins must be returned.
    ///      At the same time, accrued fees are collected.
    /// @param tickLow Lower limit of ticks
    /// @param tickHigh Upper limit of ticks
    /// @param burnedLiquidity Liquidity to burn
    /// @return amounts of token0 and token1 returned
    function burn(int24 tickLow, int24 tickHigh, uint128 burnedLiquidity) external onlyOwner returns (uint256, uint256) {
        IUniswapV3Pool pool = AMP.UNISWAP_POOL();
        pool.burn(tickLow, tickHigh, burnedLiquidity); // burn does not collect yet

        (uint128 amount0, uint128 amount1) = pool.collect(msg.sender, tickLow, tickHigh, type(uint128).max, type(uint128).max); // collect fees

        uint256 returnedZCHF = AMP.repay(msg.sender, borrowed, burnedLiquidity, totalLiquidity);
        borrowed -= returnedZCHF;
        totalLiquidity -= burnedLiquidity;

        emit Burn(tickLow, tickHigh, amount0, amount1);
        return (amount0, amount1);
    }
}
