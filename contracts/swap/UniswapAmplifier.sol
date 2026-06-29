// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../stablecoin/IFrankencoin.sol";
import "./utils/IUniswapV3Pool.sol";
import "../utils/Ownable.sol";
import "../utils/Math.sol";
import "./utils/IUniswapV3MintCallback.sol";
import "../erc20/SafeERC20.sol";

/**
 * @title UniswapAmplifier
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
contract UniswapAmplifier {
    using SafeERC20 for IERC20;

    uint256 internal constant Q96 = 0x1000000000000000000000000;

    IUniswapV3Pool public immutable UNISWAP_POOL;

    address public immutable TOKEN0;
    IFrankencoin public immutable ZCHF;
    IERC20 public immutable USD;

    int24 public immutable TICK_ANCHOR;
    uint256 public immutable PRICE_ANCHOR_X96; // usd/zchf

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

        (, int24 tick, , , , , ) = UNISWAP_POOL.slot0();
        uint256 price = getPrice();
        if ((price * 99) / 100 > expectedPriceQ96) revert PriceChangedTooMuch(expectedPriceQ96, price);
        if ((price * 101) / 100 < expectedPriceQ96) revert PriceChangedTooMuch(expectedPriceQ96, price);
        TICK_ANCHOR = tick;
        PRICE_ANCHOR_X96 = TOKEN0 == zchf_ ? expectedPriceQ96 : Math.mulDiv(Q96, Q96, expectedPriceQ96);
    }

    /// @notice Verifies that the provided ticks are within the valid range, i.e. +/-20% of the initial price.
    /// @dev Reverts if ticks aren't in +/- 20% of TICK_ANCHOR. The pool itself enforces that the ticks are
    ///      aligned to the tick spacing, so no rounding is needed here.
    /// @param ticksLow Lower limit of ticks
    /// @param ticksHigh Higher limit of ticks
    function checkTicks(int24 ticksLow, int24 ticksHigh) public view {
        int24 minimum = TICK_ANCHOR - TWENTY_PERCENT;
        int24 maximum = TICK_ANCHOR + TWENTY_PERCENT;
        if (ticksLow < minimum || ticksLow > maximum) revert InvalidTick(minimum, ticksLow, maximum);
        if (ticksHigh < minimum || ticksHigh > maximum) revert InvalidTick(minimum, ticksHigh, maximum);
    }

    /// @notice Calculates min. dollars required for the given ZCHF amount based on the price anchor
    /// @param zchfAmount Amount of ZCHF
    /// @return Amount of dollars
    function getMinimumDollars(uint256 zchfAmount) public view returns (uint256) {
        return Math.mulDiv(PRICE_ANCHOR_X96, zchfAmount, Q96);
    }

    /// @notice The current pool price, denominated as token1 per token0 in Q96.
    function getPrice() public view returns (uint256) {
        (uint160 sqrtPriceX96, , , , , , ) = UNISWAP_POOL.slot0();
        return Math.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
    }

    /// @notice Slippage guard: reverts unless the live pool price is within 0.1% of the expected price.
    /// @dev With a fixed liquidity amount and range, both token amounts of a mint or burn are a deterministic
    ///      function of the price. Pinning the price to a tight band therefore bounds the amounts on both
    ///      sides at once, protecting mints and burns against sandwiching.
    /// @param expectedPriceX96 Expected pool price (token1 per token0) in Q96, same convention as the constructor.
    function checkPrice(uint256 expectedPriceX96) public view {
        if (expectedPriceX96 > 0) {
            uint256 price = getPrice();
            if ((price * 999) / 1000 > expectedPriceX96 || (price * 1001) / 1000 < expectedPriceX96) {
                revert PriceChangedTooMuch(price, expectedPriceX96);
            }
        }
    }

    /// @notice Borrows ZCHF into the pool against the owner's dollars.
    /// @dev The position's range must require enough dollars that the owner is better off repaying than walking
    ///      away. For example, at an initial price of 0.85 CHF/USD, borrowing 85 CHF needs a range that also
    ///      requires at least 100 USD. Requires the owner to have approved this contract for the pairing token.
    /// @param owner User to take the pairing tokens from
    /// @param token0Amount Amount of token0 to send to the pool
    /// @param token1Amount Amount of token1 to send to the pool
    /// @return Amount borrowed in ZCHF
    function borrowIntoPool(address owner, uint256 token0Amount, uint256 token1Amount) external onlyPosition returns (uint256) {
        if (block.timestamp > EXPIRATION) revert AmplifierExpired();

        (uint256 zchfAmount, uint256 collateralAmount) = address(ZCHF) == TOKEN0 ? (token0Amount, token1Amount) : (token1Amount, token0Amount);
        uint256 required = getMinimumDollars(zchfAmount);
        if (collateralAmount < required) revert InsufficientDollarsInRange(required, collateralAmount);

        USD.safeTransferFrom(owner, address(UNISWAP_POOL), collateralAmount); // obtain the dollars and deposit them into the pool
        ZCHF.mint(address(UNISWAP_POOL), zchfAmount); // mint directly to the uniswap pool, will be credited to the right position

        totalBorrowed += zchfAmount;
        if (totalBorrowed > LIMIT) revert LimitExceeded(totalBorrowed, LIMIT);

        emit Borrowed(zchfAmount, totalBorrowed);
        return zchfAmount;
    }

    /// @notice Repays a position by burning borrowed ZCHF from the owner
    /// @param owner ZCHF holder
    /// @param borrowed Total amount of ZCHF borrowed
    /// @param returnedPart Amount of liquidity returned
    /// @param total  Total amount of liquidity held by the position
    /// @return Amount of ZCHF burned from the owner
    function repay(address owner, uint256 borrowed, uint128 returnedPart, uint128 total) external onlyPosition returns (uint256) {
        uint256 zchfToReturn = Math.mulDiv(borrowed, returnedPart, total);
        ZCHF.burnFrom(owner, zchfToReturn);
        totalBorrowed -= zchfToReturn;
        emit Repaid(zchfToReturn, totalBorrowed);
        return zchfToReturn;
    }

    /// @notice Creates a new amplified position with the msg.sender as owner, bound to the given tick range.
    /// @param tickLow Lower limit of ticks, must be within +/- 20% of the initial price
    /// @param tickHigh Upper limit of ticks, must be within +/- 20% of the initial price
    /// @return Address of the newly created Position
    function createAmplifiedPosition(int24 tickLow, int24 tickHigh) public returns (address) {
        checkTicks(tickLow, tickHigh);
        AmplifiedPosition amplifier = new AmplifiedPosition(this, msg.sender, tickLow, tickHigh);
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
    UniswapAmplifier immutable AMP;

    // A position is bound to a single tick range, fixed at construction. Liquidity (L) is only comparable
    // within one range, so aggregating L across different ranges would corrupt the proportional repay accounting.
    int24 public immutable tickLow;
    int24 public immutable tickHigh;

    uint256 public borrowed;
    uint128 public totalLiquidity;

    error AccessDenied(address sender);
    error NotExpired();

    event Mint(uint128 liquidityAdded, uint256 token0, uint256 token1, uint256 borrowed);
    event Burn(uint128 liquidityRemoved, uint256 token0, uint256 token1, uint256 repaid);

    constructor(UniswapAmplifier parent, address owner, int24 tickLow_, int24 tickHigh_) {
        AMP = parent;
        tickLow = tickLow_;
        tickHigh = tickHigh_;
        _setOwner(owner);
    }

    /// @notice Mints the provided amount of liquidity into this position's range.
    /// @dev This function only succeeds if the caller has sufficient dollars on his address and if there is an allowance in place.
    /// @param amount Amount of liquidity to add
    /// @param expectedPriceX96 Expected pool price (token1/token0, Q96); reverts if the live price is off by more than 0.1% (slippage guard)
    function mint(uint128 amount, uint256 expectedPriceX96) external onlyOwner {
        AMP.checkPrice(expectedPriceX96);
        uint256 previouslyBorrowed = borrowed;
        (uint256 amount0, uint256 amount1) = AMP.UNISWAP_POOL().mint(address(this), tickLow, tickHigh, amount, "");
        totalLiquidity += amount;
        emit Mint(amount, amount0, amount1, borrowed - previouslyBorrowed);
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
    /// @param burnedLiquidity Liquidity to burn
    /// @param expectedPriceX96 Expected pool price (token1/token0, Q96); reverts if the live price is off by more than 0.1% (slippage guard)
    /// @return amounts of token0 and token1 returned
    function burn(uint128 burnedLiquidity, uint256 expectedPriceX96) external onlyOwner returns (uint256, uint256) {
        return _burn(burnedLiquidity, expectedPriceX96);
    }

    /// @notice Once the amplifier has expired, let anyone burn positions and collect the underlying tokens.
    /// @dev As long as the exchange rate has not fallen by more than 50% since the deployment of the amplifier,
    ///      this can be called profitably at the expense of the position owner.
    /// @param burnedLiquidity Liquidity to burn
    /// @param expectedPriceX96 Expected pool price (token1/token0, Q96); reverts if the live price is off by more than 0.1% (slippage guard)
    /// @return amounts of token0 and token1 returned
    function expiredPublicBurn(uint128 burnedLiquidity, uint256 expectedPriceX96) external returns (uint256, uint256) {
        if (block.timestamp <= AMP.EXPIRATION()) revert NotExpired();
        return _burn(burnedLiquidity, expectedPriceX96);
    }

    function _burn(uint128 burnedLiquidity, uint256 expectedPriceX96) internal returns (uint256, uint256) {
        AMP.checkPrice(expectedPriceX96);
        IUniswapV3Pool pool = AMP.UNISWAP_POOL();
        pool.burn(tickLow, tickHigh, burnedLiquidity); // burn does not collect yet
        (uint128 amount0, uint128 amount1) = pool.collect(msg.sender, tickLow, tickHigh, type(uint128).max, type(uint128).max); // collect principal + fees
        uint256 returnedZCHF = AMP.repay(msg.sender, borrowed, burnedLiquidity, totalLiquidity);
        borrowed -= returnedZCHF;
        totalLiquidity -= burnedLiquidity;
        emit Burn(burnedLiquidity, amount0, amount1, returnedZCHF);
        return (amount0, amount1);
    }
}
