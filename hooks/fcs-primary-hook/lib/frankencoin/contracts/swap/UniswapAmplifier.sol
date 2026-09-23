// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../stablecoin/IFrankencoin.sol";
import "./utils/IUniswapV3Pool.sol";
import "../utils/Ownable.sol";
import "../utils/Math.sol";
import "./utils/IUniswapV3MintCallback.sol";
import "../erc20/SafeERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/**
 * @title UniswapAmplifier
 *
 * Factory contract to create amplified uniswap positions for a hardcoded pool. Amplified positions are positions for which
 * the ZCHF part of the trading pair is borrowed from the Frankencoin protocol and only the other token is provided by the owner.
 *
 * The range of the amplified position must be in a range of roughly 25% around the anchor price when the amplifier was deployed
 * (actually -13.93%/+10.52%). Another important parameter is the minimum amount of dollars that must be provided for a given amount
 * of borrowed ZCHF. This ensures that the owner is usually better off repaying the borrowed ZCHF than walking away, even if the
 * dollar has declined in value.
 * 
 * The parameters must be chosen with care. Exploiting it is easier than one might think. An attacker might manipulate the price
 * of the dollar upwards in the uniswap pool to the upper end of the allowed range, initiate a narrow position and immediately
 * buy the minted ZCHF at the lowest allowed price (i.e. -9.52% or 1000 TICKS below the anchor in dollar terms), then manipulate
 * the pool price back to the market price. Consequently, the amplifier becomes exploitable as soon as the market price falls more
 * than about 41% below the anchor price. See exploitableAt() for the exact threshold at the current parameters.
 *
 **/
contract UniswapAmplifier {

    using SafeERC20 for IERC20;

    uint256 internal constant Q96 = 0x1000000000000000000000000;

    IUniswapV3Pool public immutable UNISWAP_POOL;
    bool public immutable ZCHF_IS_TOKEN0;

    IERC20 public immutable USD;
    IERC20 public immutable ZCHF;
    IFrankencoinMinter public immutable ZCHF_MINTER;

    // Price anchor USD/ZCHF. Must be verified before proposing as minter!
    // A front-runner could have manipulated the pool during the deployment of the contract.
    uint256 public immutable PRICE_ANCHOR_X96; 
    int24 public immutable MAX_DOLLAR_APPRECIATION_TICKS = 1000; // about 10% stronger dollar
    int24 public immutable MAX_DOLLAR_DEPRECIATION_TICKS = 1500; // about 14% weaker dollar

    int24 public immutable MINIMUM_TICK;
    int24 public immutable MAXIMUM_TICK;

    uint40 public immutable EXPIRATION;
    uint256 public immutable LIMIT;

    /// @notice The AmplifiedPosition template that all positions are cloned from (EIP-1167 minimal proxies).
    address public immutable positionImplementation;

    uint256 public totalBorrowed;

    mapping(address => uint256) public positionCreationDate;

    error InvalidUniswapPool();
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
    constructor(address uniswapPool_, address zchf_, address zchfMinter_, uint40 expiration, uint256 borrowingLimit) {
        UNISWAP_POOL = IUniswapV3Pool(uniswapPool_);
        ZCHF = IERC20(zchf_);
        ZCHF_MINTER = IFrankencoinMinter(zchfMinter_);
        EXPIRATION = expiration;
        LIMIT = borrowingLimit;

        (, int24 tick, , , , , ) = UNISWAP_POOL.slot0();
        uint256 price = getPrice();

        // Slightly asymmetric range in expectation of ZCHF being the stronger currency: allow the dollar to
        // weaken about 14% but only strengthen about 10%. Which tick direction corresponds to a weaker dollar
        // depends on the ordering: if ZCHF is token0 the pool price is USD/ZCHF and a weaker dollar means a
        // higher tick; if ZCHF is token1 the pool price is ZCHF/USD and a weaker dollar means a lower tick.
        ZCHF_IS_TOKEN0 = UNISWAP_POOL.token0() == zchf_;
        if (ZCHF_IS_TOKEN0) {
            USD = IERC20(UNISWAP_POOL.token1());
            PRICE_ANCHOR_X96 = price;
            MINIMUM_TICK = tick - MAX_DOLLAR_APPRECIATION_TICKS;
            MAXIMUM_TICK = tick + MAX_DOLLAR_DEPRECIATION_TICKS;
        } else {
            if (UNISWAP_POOL.token1() != zchf_) revert InvalidUniswapPool();
            USD = IERC20(UNISWAP_POOL.token0());
            PRICE_ANCHOR_X96 = Math.mulDiv(Q96, Q96, price);
            MINIMUM_TICK = tick - MAX_DOLLAR_DEPRECIATION_TICKS;
            MAXIMUM_TICK = tick + MAX_DOLLAR_APPRECIATION_TICKS;
        }

        // Deploy the position template once. Its immutable AMP is this amplifier, so all clones read the
        // correct amplifier from the template's code while carrying their own owner/ticks in storage.
        positionImplementation = address(new AmplifiedPosition(this));
    }

    /// @notice Verifies that the provided ticks are within the amplifier's allowed band [MINIMUM_TICK, MAXIMUM_TICK].
    /// @dev The band is asymmetric around the anchor tick (see the constructor), allowing the dollar to weaken about
    ///      14% but only strengthen about 10%. The pool itself enforces that the ticks are aligned to the tick
    ///      spacing, so no rounding is needed here.
    /// @param ticksLow Lower limit of ticks
    /// @param ticksHigh Higher limit of ticks
    function checkTicks(int24 ticksLow, int24 ticksHigh) public view {
        if (ticksLow < MINIMUM_TICK || ticksLow > MAXIMUM_TICK) revert InvalidTick(MINIMUM_TICK, ticksLow, MAXIMUM_TICK);
        if (ticksHigh < MINIMUM_TICK || ticksHigh > MAXIMUM_TICK) revert InvalidTick(MINIMUM_TICK, ticksHigh, MAXIMUM_TICK);
    }

    /**
     * @notice The dollar price (CHF per USD, 18 decimals) below which the amplifier becomes exploitable.
     * @dev Once the dollar falls below the exploitable price, an attacker can profitably exploit the contract by manipulating
     * the uniswap price to the upper end of the allowed range, create a narrow position, buy the minted ZCHF at a low price in
     * dollar terms, and then manipulate the price back to the market price. For example, if the LIMIT is 10,000,000 ZCHF and 
     * the attacker launches the attack slightly below the exploitable price, they might make a profit of 100'000 ZCHF with the
     * amplifier ending up with 9,900,000 CHF worth of USD. Should this ever happen, the Frankencoin community can either hope
     * for the dollar price to recover, at which point it becomes profitable for the attacker to repay the borrowed ZCHF and get
     * the USD back, or they could create a custom new minter that performs an expiredPublicBurn after the expiration
     * with the missing ZCHF coming out of the equity pool.
     */
    function exploitableAt() public view returns (uint256) {
        // Worst case (narrow position at the strong-dollar floor): P* = P_floor + collateral, in USD per ZCHF, where
        // P_floor = anchor / 1.0001^MAX_DOLLAR_APPRECIATION_TICKS and collateral = getMinimumDollars(one ZCHF). Both
        // are derived from the live parameters, so this needs no adjustment if the band or collateral factor change.
        uint256 floorX96 = Math.mulDiv(PRICE_ANCHOR_X96, Q96, pow1_0001(MAX_DOLLAR_APPRECIATION_TICKS)); // anchor / 1.0001^ticks
        uint256 pStarX96 = floorX96 + getMinimumDollars(Q96); // getMinimumDollars(Q96) == collateral factor * anchor, in Q96
        uint256 chfPerUsdX96 = Math.mulDiv(Q96, Q96, pStarX96); // reciprocal: USD priced in ZCHF, base units, Q96
        return Math.mulDiv(chfPerUsdX96, 10 ** USD.decimals(), Q96); // scale to an 18-decimal CHF/USD price
    }

    /// @notice Computes 1.0001^ticks in Q96 via exponentiation by squaring, for a non-negative tick count.
    function pow1_0001(int24 ticks) internal pure returns (uint256 result) {
        uint256 base = Math.mulDiv(10001, Q96, 10000); // 1.0001 in Q96
        uint256 exponent = uint256(int256(ticks));
        result = Q96; // 1.0 in Q96
        while (exponent > 0) {
            if (exponent & 1 == 1) result = Math.mulDiv(result, base, Q96);
            base = Math.mulDiv(base, base, Q96);
            exponent >>= 1;
        }
    }

    /// @notice Calculates min. dollars required for the given ZCHF amount based on the price anchor
    /// @param zchfAmount Amount of ZCHF
    /// @return Amount of dollars
    function getMinimumDollars(uint256 zchfAmount) public view returns (uint256) {
        // Multiplying by 4/5 to allow up to 1.25:1 leverage based on the original price. As a result the system only
        // takes a loss if the dollar declines more than about 41% below the anchor (worst case, for a position at the
        // strong-dollar floor of the band) or about 44% for a position minted at the anchor. See exploitableAt().
        return Math.mulDiv(PRICE_ANCHOR_X96, zchfAmount, Q96) * 4 / 5;
    }

    /// @notice The current pool price, denominated as token1 per token0 in Q96.
    function getPrice() public view returns (uint256) {
        (uint160 sqrtPriceX96, , , , , , ) = UNISWAP_POOL.slot0();
        return Math.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
    }

    /// @notice Slippage guard: reverts unless the expected price is within 0.1% of the live pool price.
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
    /// @dev The position's range must require enough dollars that the owner is usually better off repaying than
    ///      walking away. Check getMinimumDollars for the amount of dollars needed.
    ///      Requires the owner to have approved this contract for the pairing token.
    /// @param owner User to take the pairing tokens from
    /// @param token0Amount Amount of token0 to send to the pool
    /// @param token1Amount Amount of token1 to send to the pool
    /// @return Amount borrowed in ZCHF
    function borrowIntoPool(address owner, uint256 token0Amount, uint256 token1Amount) external onlyPosition returns (uint256) {
        if (block.timestamp > EXPIRATION) revert AmplifierExpired();

        (uint256 zchfAmount, uint256 collateralAmount) = ZCHF_IS_TOKEN0 ? (token0Amount, token1Amount) : (token1Amount, token0Amount);
        uint256 required = getMinimumDollars(zchfAmount);
        if (collateralAmount < required) revert InsufficientDollarsInRange(required, collateralAmount);

        USD.safeTransferFrom(owner, address(UNISWAP_POOL), collateralAmount); // obtain the dollars and deposit them into the pool
        ZCHF_MINTER.mint(owner, zchfAmount); // mint to the owner first for better traceability
        ZCHF.transferFrom(owner, address(UNISWAP_POOL), zchfAmount); // transfer to the uniswap pool

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
        if (returnedPart > 0) {
            uint256 zchfToReturn = Math.mulDiv(borrowed, returnedPart, total);
            ZCHF_MINTER.burnFrom(owner, zchfToReturn);
            totalBorrowed -= zchfToReturn;
            emit Repaid(zchfToReturn, totalBorrowed);
            return zchfToReturn;
        } else {
            return 0;
        }
    }

    /// @notice Creates a new amplified position with the msg.sender as owner, bound to the given tick range.
    /// @param tickLow Must be within what checkTicks() allows.
    /// @param tickHigh Must be within what checkTicks() allows.
    /// @return Address of the newly created Position
    function createAmplifiedPosition(int24 tickLow, int24 tickHigh) public returns (address) {
        checkTicks(tickLow, tickHigh);
        address position = Clones.clone(positionImplementation);
        AmplifiedPosition(position).initialize(msg.sender, tickLow, tickHigh);
        positionCreationDate[position] = block.timestamp;
        emit AmplifiedPositionCreated(position);
        return position;
    }

    modifier onlyPosition() {
        if (positionCreationDate[msg.sender] == 0) revert AccessDenied();
        _;
    }
}

interface IFrankencoinMinter {
    function mint(address to, uint256 amount) external;
    function burnFrom(address from, uint256 amount) external;
}

/**
 * An amplified position belonging to a specific owner.
 */
contract AmplifiedPosition is Ownable, IUniswapV3MintCallback {
    // The amplifier is baked into the template's code, so every clone reads the correct amplifier even
    // though it is a minimal proxy delegatecalling into this template.
    UniswapAmplifier immutable AMP;

    // A position is bound to a single tick range, set once at initialization. Liquidity (L) is only comparable
    // within one range, so aggregating L across different ranges would corrupt the proportional repay accounting.
    // These cannot be immutable because clones carry their own values in storage.
    int24 public tickLow;
    int24 public tickHigh;

    uint256 public borrowed;

    error AccessDenied(address sender);
    error NotExpired();

    event Mint(uint128 liquidityAdded, uint256 token0, uint256 token1, uint256 borrowed);
    event Burn(uint128 liquidityRemoved, uint256 token0, uint256 token1, uint256 repaid);

    /// @notice Only runs on the template. Clones are created via Clones.clone and configured through initialize.
    constructor(UniswapAmplifier parent) {
        AMP = parent;
    }

    /// @notice Configures a freshly cloned position. Callable exactly once, and only by the amplifier.
    /// @dev The owner == address(0) check doubles as the re-initialization guard: a fresh clone has no owner yet,
    ///      and _setOwner rejects the zero address, so it can never be initialized twice.
    function initialize(address owner_, int24 tickLow_, int24 tickHigh_) external {
        // `owner` is the Ownable state variable: nonzero means already initialized.
        if (owner != address(0) || msg.sender != address(AMP)) revert AccessDenied(msg.sender);
        tickLow = tickLow_;
        tickHigh = tickHigh_;
        _setOwner(owner_);
    }

    /// @notice The total liquidity of this position as recorded by the pool.
    /// @dev Read from the pool instead of tracked locally so that liquidity donated to this position
    ///      (minted directly on the pool with this position as recipient) is included and can be burned
    ///      like any other liquidity, repaying a proportional share of the debt.
    function totalLiquidity() public view returns (uint128 liquidity) {
        (liquidity, , , , ) = AMP.UNISWAP_POOL().positions(keccak256(abi.encodePacked(address(this), tickLow, tickHigh)));
    }

    /// @notice Mints the provided amount of liquidity into this position's range.
    /// @dev This function only succeeds if the caller has sufficient dollars on his address and if there is an allowance in place.
    /// @param amount Amount of liquidity to add
    /// @param expectedPriceX96 Expected pool price (token1/token0, Q96); reverts if the expected price is not within 0.1% (slippage guard) of the pool price.
    /// Set expectedPriceX96 to 0 to skip the slippage guard.
    function mint(uint128 amount, uint256 expectedPriceX96) external onlyOwner {
        AMP.checkPrice(expectedPriceX96);
        uint256 previouslyBorrowed = borrowed;
        (uint256 amount0, uint256 amount1) = AMP.UNISWAP_POOL().mint(address(this), tickLow, tickHigh, amount, "");
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
    /// @param expectedPriceX96 Expected pool price (token1/token0, Q96); reverts if the expected price is not within 0.1% (slippage guard) of the pool price.
    /// @return amounts of token0 and token1 returned
    function burn(uint128 burnedLiquidity, uint256 expectedPriceX96) external onlyOwner returns (uint256, uint256) {
        return _burn(burnedLiquidity, expectedPriceX96);
    }

    /// @notice Once the amplifier has expired, let anyone burn positions and collect the underlying tokens.
    /// @dev As long as the market price of the dollar has not declined too much below the anchor price (depending
    ///      on where the position's range sits within the allowed band), this can be called profitably at the
    ///      expense of the position owner. Beyond that threshold, winding down is unprofitable and the debt
    ///      may remain unpaid.
    ///      For the test amplifier, we intentionally let a position expire. It took nine days for a bot to pick up the
    ///      free money in transaction 0x9b188d16802794f83370c30f2705b7d5de2e9226f8117519060403239465584d.
    /// @param burnedLiquidity Liquidity to burn
    /// @param expectedPriceX96 Expected pool price (token1/token0, Q96); reverts if the expected price is not within 0.1% (slippage guard) of the pool price.
    /// @return amounts of token0 and token1 returned
    function expiredPublicBurn(uint128 burnedLiquidity, uint256 expectedPriceX96) external returns (uint256, uint256) {
        if (block.timestamp <= AMP.EXPIRATION()) revert NotExpired();
        return _burn(burnedLiquidity, expectedPriceX96);
    }

    function _burn(uint128 burnedLiquidity, uint256 expectedPriceX96) internal returns (uint256, uint256) {
        AMP.checkPrice(expectedPriceX96);
        uint128 total = totalLiquidity(); // must be read before pool.burn reduces it
        IUniswapV3Pool pool = AMP.UNISWAP_POOL();
        pool.burn(tickLow, tickHigh, burnedLiquidity); // burn does not collect yet, also ensures burnedLiquidity <= total
        (uint128 amount0, uint128 amount1) = pool.collect(msg.sender, tickLow, tickHigh, type(uint128).max, type(uint128).max); // collect principal + fees
        uint256 returnedZCHF = AMP.repay(msg.sender, borrowed, burnedLiquidity, total);
        borrowed -= returnedZCHF;
        emit Burn(burnedLiquidity, amount0, amount1, returnedZCHF);
        return (amount0, amount1);
    }
}
